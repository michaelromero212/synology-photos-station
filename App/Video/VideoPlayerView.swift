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
@Observable
@MainActor
final class VideoPlaybackModel {
    private(set) var player: AVPlayer?
    private(set) var lastError: String?
    private(set) var isLoading = false

    func load(assetID: UUID, client: FrameStationClient?) async {
        guard let client, player == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let playback = try await client.playbackURL(assetID: assetID)
            let item = AVPlayerItem(url: playback.url)
            let player = AVPlayer(playerItem: item)
            self.player = player
            // Opening a video in Photos plays it; requiring a second tap here
            // would read as the video having failed to load.
            configureAudioSession()
            player.play()
            lastError = nil
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

    func stop() {
        player?.pause()
        player = nil
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
                    .overlay(alignment: .bottom) {
                        if showsControls {
                            VideoControls(player: player)
                                .transition(.opacity)
                        }
                    }
                #else
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

/// Play/pause and a scrubber, shown and hidden with the rest of the chrome.
struct VideoControls: View {
    let player: AVPlayer

    @State private var isPlaying = true
    @State private var position: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var observer: Any?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if isPlaying { player.pause() } else { player.play() }
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 30)
            }
            .buttonStyle(.plain)

            Text(Self.timecode(position))
                .font(.caption.monospacedDigit())

            Slider(
                value: $position,
                in: 0...max(duration, 0.1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        player.seek(
                            to: CMTime(seconds: position, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero
                        )
                    }
                }
            )

            Text("-" + Self.timecode(max(duration - position, 0)))
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.45), in: Capsule())
        .padding(.horizontal, 16)
        // Clear of the action bar, which floats at the very bottom.
        .padding(.bottom, 96)
        .task {
            duration = player.currentItem?.duration.seconds ?? 0
            if !duration.isFinite { duration = 0 }
            // Tracks the clip without fighting a drag in progress.
            observer = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                queue: .main
            ) { time in
                guard !isScrubbing else { return }
                position = time.seconds
                if duration == 0, let known = player.currentItem?.duration.seconds,
                   known.isFinite {
                    duration = known
                }
            }
        }
        .onDisappear {
            if let observer { player.removeTimeObserver(observer) }
            observer = nil
        }
    }

    private static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
#endif
