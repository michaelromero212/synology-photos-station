import AVKit
import FrameStationAPI
import FrameStationKit
import Foundation
import Observation
import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

/// Fetches a signed URL and plays it.
///
/// Direct play: the stored file is streamed as-is over HTTP Range, so a 4K clip
/// costs nothing to "prepare" and scrubbing fetches only the part being watched.
/// The NAS is a J4125 — transcoding 4K on it is not on the table, and on a home
/// network it isn't needed.
///
/// The transport lives here rather than in the view because seeking has state
/// that must not be thrown away when a body re-evaluates: there is at most one
/// seek in flight at a time, and the newest requested position is remembered
/// while it completes.
@Observable
@MainActor
final class VideoPlaybackModel {
    private(set) var player: AVPlayer?
    private(set) var lastError: String?
    private(set) var isLoading = false

    private(set) var duration: Double = 0
    private(set) var position: Double = 0
    private(set) var isPlaying = false
    private(set) var hasFinished = false
    /// Read off the video track. Used for stepping, and it is why odd rates —
    /// 23.976, 59.94, a slow-motion 240 — all behave.
    private(set) var nominalFrameRate: Float = 30

    /// True while a finger owns the scrubber. Time observations are ignored,
    /// otherwise the thumb fights the playhead it is trying to move.
    private(set) var isScrubbing = false

    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    /// The newest position asked for while a seek is already running.
    @ObservationIgnored private var pendingSeek: CMTime = .invalid
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var resumeAfterScrub = false

    func load(assetID: UUID, client: FrameStationClient?) async {
        guard let client, player == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let playback = try await client.playbackURL(assetID: assetID)
            let item = AVPlayerItem(url: playback.url)
            let player = AVPlayer(playerItem: item)
            self.player = player
            configureAudioSession()
            player.play()
            isPlaying = true
            lastError = nil

            track(player)
            await describe(item)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Playback belongs in the "playback" category, otherwise a video plays
    /// silently whenever the ringer switch is off — which looks like broken
    /// audio, not a deliberate mute.
    private func configureAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    /// Duration and frame rate, loaded rather than read.
    ///
    /// `currentItem.duration` is `indefinite` until enough of a streamed file
    /// has arrived, so reading it synchronously at load gives zero for exactly
    /// the formats that take longest to open — and a zero duration is a scrubber
    /// that can't be dragged.
    private func describe(_ item: AVPlayerItem) async {
        if let seconds = try? await item.asset.load(.duration).seconds, seconds.isFinite {
            duration = max(0, seconds)
        }
        if let track = try? await item.asset.loadTracks(withMediaType: .video).first,
           let rate = try? await track.load(.nominalFrameRate) {
            nominalFrameRate = rate
        }
    }

    private func track(_ player: AVPlayer) {
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                // Some containers only surface a usable duration once playback
                // has actually started.
                if self.duration == 0,
                   let known = player.currentItem?.duration.seconds, known.isFinite {
                    self.duration = known
                }
                if self.position > 0 { self.hasFinished = false }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.hasFinished = true
            }
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            // Pressing play on a finished clip starts it again rather than
            // sitting on the last frame doing nothing.
            if hasFinished { seek(to: 0, exact: true) }
            player.play()
            isPlaying = true
            hasFinished = false
        }
    }

    /// Jumps by `delta` seconds. The one people press over and over.
    func skip(by delta: Double) {
        let target = VideoTiming.skipTarget(from: position, by: delta, duration: duration)
        position = target
        hasFinished = false
        // Exact, because a skip is a considered move to a specific moment — and
        // one seek can afford the decode a hundred scrub updates cannot.
        seek(to: target, exact: true)
    }

    /// One frame, for finding the exact moment something happens.
    func step(frames: Int) {
        guard let item = player?.currentItem else { return }
        player?.pause()
        isPlaying = false
        item.step(byCount: frames)
        position = item.currentTime().seconds
    }

    func beginScrub() {
        isScrubbing = true
        resumeAfterScrub = isPlaying
        // Paused while dragging: letting it run means the picture is chasing
        // both the finger and the clock, and lands somewhere neither asked for.
        player?.pause()
        isPlaying = false
    }

    /// Called continuously while dragging.
    func scrub(to seconds: Double) {
        position = min(max(0, seconds), duration > 0 ? duration : seconds)
        seek(to: position, exact: false)
    }

    func endScrub() {
        isScrubbing = false
        seek(to: position, exact: true)
        if resumeAfterScrub {
            player?.play()
            isPlaying = true
        }
        resumeAfterScrub = false
    }

    /// Seeks, with at most one request in flight.
    ///
    /// `AVPlayer.seek` does not queue: firing one per drag update leaves a long
    /// tail of stale seeks to work through, and the picture arrives somewhere
    /// the finger left several seconds ago. Holding the newest target and
    /// chasing it when the current seek completes keeps the frame with the thumb.
    private func seek(to seconds: Double, exact: Bool) {
        guard let player else { return }
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        pendingSeek = target
        guard !isSeeking else { return }
        dispatchSeek(exact: exact, on: player)
    }

    private func dispatchSeek(exact: Bool, on player: AVPlayer) {
        guard pendingSeek.isValid else {
            isSeeking = false
            return
        }
        let target = pendingSeek
        pendingSeek = .invalid
        isSeeking = true

        let tolerance = exact
            ? CMTime.zero
            : CMTime(
                seconds: VideoTiming.scrubTolerance(duration: duration),
                preferredTimescale: 600
              )

        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.pendingSeek.isValid {
                    self.dispatchSeek(exact: exact, on: player)
                } else {
                    self.isSeeking = false
                }
            }
        }
    }

    func stop() {
        if let observer { player?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        observer = nil
        endObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
    }
}

struct VideoPlayerView: View {
    let assetID: UUID
    let client: FrameStationClient?
    /// Shown behind the player while the signed URL is fetched, so the frame
    /// doesn't flash black between tapping and playing. Platform image rather
    /// than `Image` because that's what the thumbnail cache already holds.
    let poster: PlatformImage?
    /// Whether playback controls are showing. On iOS this is the viewer's
    /// chrome flag: AVKit's own controls would swallow the tap that hides
    /// them, so the video draws bare and the controls below are ours.
    var showsControls: Bool = true
    /// A single tap anywhere that isn't a control. Handled in here rather than
    /// by the caller because the double-tap skip zones have to win the
    /// disambiguation, and two gestures can only be ordered within one view.
    var onSingleTap: () -> Void = {}

    @State private var model = VideoPlaybackModel()

    var body: some View {
        ZStack {
            if let poster, model.player == nil {
                Image(platformImage: poster).resizable().scaledToFit()
            }
            if let player = model.player {
                #if os(iOS)
                // A bare layer, so a tap anywhere reaches the viewer and
                // toggles chrome instead of being eaten by AVKit.
                PlayerLayerView(player: player)
                    .overlay { skipZones }
                    .overlay {
                        if showsControls {
                            VideoControls(model: model).transition(.opacity)
                        }
                    }
                #else
                // macOS and tvOS get AVKit's own transport, which is the right
                // answer there: it is the control surface people already know,
                // it takes the Apple TV remote's swipe-to-scrub and the Mac's
                // media keys for free, and neither platform has a chrome-hiding
                // tap for it to interfere with.
                VideoPlayer(player: player)
                #endif
            }
            if model.isLoading {
                // `controlSize` doesn't exist on tvOS, where the system sizes
                // controls for the 10-foot layout itself.
                #if os(tvOS)
                ProgressView()
                #else
                ProgressView().controlSize(.large)
                #endif
            }
            if let error = model.lastError {
                ContentUnavailableView(
                    "Can't play this video",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            }
        }
        .task { await model.load(assetID: assetID, client: client) }
        .onDisappear { model.stop() }
    }

    #if os(iOS)
    /// Double-tap either half to jump ten seconds, the way every video app now
    /// works. This is the "watch that bit again" gesture: no aiming at a small
    /// button, and it repeats as fast as you can tap.
    ///
    /// The single tap is declared alongside so SwiftUI disambiguates them here
    /// rather than letting a chrome toggle fire on the way to a skip.
    private var skipZones: some View {
        HStack(spacing: 0) {
            skipZone(by: -VideoTiming.skipInterval)
            skipZone(by: VideoTiming.skipInterval)
        }
    }

    private func skipZone(by delta: Double) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                model.skip(by: delta)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            .onTapGesture(count: 1, perform: onSingleTap)
    }
    #endif
}

#if os(iOS)
/// `AVPlayerLayer` with nothing on top of it.
///
/// `VideoPlayer` is AVKit's whole player, controls included, and those
/// controls consume every touch in the frame — which is why tapping a video
/// scrubbed or paused instead of hiding the chrome the way tapping a photo
/// does.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: PlayerHostView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerHostView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Playback controls, laid out the way Synology lays them out: a transport row
/// centred on the video itself, and a single row underneath carrying elapsed
/// time, the scrubber, time remaining, and mute.
struct VideoControls: View {
    let model: VideoPlaybackModel

    @State private var isMuted = false

    var body: some View {
        ZStack {
            transportRow
            VStack {
                Spacer()
                scrubBar
            }
        }
        .foregroundStyle(.white)
    }

    /// Skip back, play/pause, skip forward. The skips flank the ring rather
    /// than hiding in a menu because rewatching a moment is the single most
    /// common thing anyone does with a home video.
    private var transportRow: some View {
        HStack(spacing: 34) {
            skipButton(by: -VideoTiming.skipInterval, symbol: "gobackward.10")
            playPauseRing
            skipButton(by: VideoTiming.skipInterval, symbol: "goforward.10")
        }
        .shadow(radius: 8)
    }

    private func skipButton(by delta: Double, symbol: String) -> some View {
        Button {
            model.skip(by: delta)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(delta < 0 ? "Back 10 seconds" : "Forward 10 seconds")
    }

    private var playPauseRing: some View {
        Button {
            model.togglePlayPause()
        } label: {
            Image(systemName: playSymbol)
                .font(.system(size: 30, weight: .medium))
                .frame(width: 78, height: 78)
                .background(Circle().stroke(.white, lineWidth: 3))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
    }

    private var playSymbol: String {
        if model.hasFinished { return "arrow.clockwise" }
        return model.isPlaying ? "pause.fill" : "play.fill"
    }

    private var scrubBar: some View {
        HStack(spacing: 12) {
            Text(VideoTiming.timecode(model.position, duration: model.duration))
                .font(.footnote.monospacedDigit())

            Scrubber(model: model)

            Text("-" + VideoTiming.timecode(
                max(model.duration - model.position, 0), duration: model.duration
            ))
            .font(.footnote.monospacedDigit())

            Button {
                isMuted.toggle()
                model.player?.isMuted = isMuted
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.footnote)
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isMuted ? "Unmute" : "Mute")
        }
        .padding(.horizontal, 20)
        // Clear of the viewer's action bar, which floats at the very bottom.
        .padding(.bottom, 104)
        .onAppear { isMuted = model.player?.isMuted ?? false }
    }
}

/// The scrubber.
///
/// Not a `Slider`. A slider reports its value on release, which meant dragging
/// it was blind — you guessed where the funny bit was, let go, and looked. This
/// seeks continuously as the finger moves, so the picture tracks the thumb and
/// you can actually find the moment you're after.
private struct Scrubber: View {
    let model: VideoPlaybackModel

    @State private var isDragging = false
    private let trackHeight: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = VideoTiming.fraction(
                forTime: model.position, duration: model.duration
            )

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3)).frame(height: trackHeight)
                Capsule().fill(.white).frame(width: width * fraction, height: trackHeight)
                Circle()
                    .fill(.white)
                    .frame(width: isDragging ? 18 : 12, height: isDragging ? 18 : 12)
                    .offset(x: width * fraction - (isDragging ? 9 : 6))
                    .shadow(radius: 2)
            }
            .frame(maxHeight: .infinity)
            // A tall, invisible target: the track itself is four points and
            // nobody can hit that.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            model.beginScrub()
                        }
                        let fraction = min(max(value.location.x / max(width, 1), 0), 1)
                        model.scrub(
                            to: VideoTiming.time(
                                forFraction: fraction, duration: model.duration
                            )
                        )
                    }
                    .onEnded { _ in
                        isDragging = false
                        model.endScrub()
                    }
            )
            .animation(.easeOut(duration: 0.15), value: isDragging)
        }
        .frame(height: 28)
    }
}
#endif
