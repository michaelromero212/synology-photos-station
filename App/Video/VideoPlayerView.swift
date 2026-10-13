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

/// A clip the NAS still turns away with a fresh link: removed, or no longer
/// shared with this person. Said as that, not as a connection problem.
struct PlaybackRefused: LocalizedError {
    let status: Int
    var errorDescription: String? { "This video isn't available right now." }
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
    /// The failure itself, not a sentence about it. The view decides the
    /// wording, because only the view knows whether the network is down.
    private(set) var lastError: (any Error)?
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
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var stallObserver: (any NSObjectProtocol)?
    /// Restarts playback after a stall — see `track`. Required because
    /// `automaticallyWaitsToMinimizeStalling` is off.
    @ObservationIgnored private var recoveryObserver: NSKeyValueObservation?
    /// Records each stutter for the exported report.
    @ObservationIgnored private var stalledObserver: (any NSObjectProtocol)?
    /// The link the player holds, so a stall can be asked about. See
    /// `checkLinkWhileStalled`.
    @ObservationIgnored private var linkURL: URL?
    @ObservationIgnored private var linkCheck: Task<Void, Never>?
    /// Looks in on a clip a few seconds after it was told to play. See `start`.
    @ObservationIgnored private var startWatch: Task<Void, Never>?
    #if DEBUG
    // Streaming diagnostics, console-only — see `diagnose`.
    @ObservationIgnored private var diagBufferEmpty: NSKeyValueObservation?
    @ObservationIgnored private var diagKeepUp: NSKeyValueObservation?
    @ObservationIgnored private var diagTimeControl: NSKeyValueObservation?
    @ObservationIgnored private var diagStalled: (any NSObjectProtocol)?
    #endif
    /// The newest position asked for while a seek is already running.
    @ObservationIgnored private var pendingSeek: CMTime = .invalid
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var resumeAfterScrub = false
    /// Set while `prepare` is in flight, so two pages asking at once don't both
    /// build a player.
    @ObservationIgnored private var isPreparing = false
    /// Whether this video should be playing once it is ready. A page can become
    /// current before its buffer exists.
    @ObservationIgnored private var wantsPlayback = false

    /// Tell the viewer's preloader that this clip needs the connection, and
    /// when it no longer does, so the pages either side wait their turn on a
    /// weak link. See `VideoPreloader.isLinkBusy`. Nil wherever there is no
    /// preloader to tell.
    @ObservationIgnored var onNeedsLink: (() -> Void)?
    @ObservationIgnored var onLinkFree: (() -> Void)?
    /// Whether this watch has already reported itself far enough ahead.
    @ObservationIgnored private var isAhead = false

    // MARK: Staying connected

    /// True while a fresh link is being fetched for a clip that lost its own.
    /// The view shows a spinner for it, not an error. See `reconnect`.
    private(set) var isReconnecting = false
    /// What `prepare` was asked for, kept so a fresh link can be fetched
    /// without the page having to ask again.
    @ObservationIgnored private var source: (
        assetID: UUID, client: FrameStationClient, quality: PlaybackQuality
    )?
    /// When the link the player holds stops working, and how long the NAS
    /// made it last. The NAS signs each one for minutes, not for the session
    /// (`PlaybackToken.lifetime`), and the player keeps fetching more of the
    /// clip as it plays — so a link can run out partway through a long clip,
    /// across a long pause, or before a neighbor got ready early is watched.
    @ObservationIgnored private var linkExpiresAt: Date?
    @ObservationIgnored private var linkLifetime: TimeInterval = 300
    @ObservationIgnored private var recovery: Task<Void, Never>?
    /// Failures since the clip last played properly. Reset by progress, so
    /// a clip that keeps failing stops trying and says so, and one that fails
    /// once an hour never runs out of tries.
    @ObservationIgnored private var failuresWithoutProgress = 0
    @ObservationIgnored private var positionAtInstall: Double = 0
    /// So one link running out mid-play is renewed once, not every tick.
    @ObservationIgnored private var renewingLink = false

    /// How long to wait before each attempt to reconnect: at once, then
    /// backing off. About half a minute in all — long enough to ride out a
    /// NAS restarting for an update or a phone moving between networks.
    private static let reconnectDelays: [Double] = [0, 1, 2, 4, 8, 15]
    /// Failed clips in a row, with no playing in between, before giving up.
    private static let maxFailuresWithoutProgress = 3
    /// Played this far on one link, the clip counts as working again.
    private static let progressThatCounts: Double = 3
    /// Seconds of a link's life kept in hand before it is relied on.
    private static let linkMargin: TimeInterval = 30

    /// How far past the playhead the buffer has to reach before this clip
    /// stops needing the connection to itself — or the end of the clip, if
    /// that comes first. Fifteen seconds of a 1080p rendition is a few seconds'
    /// download on a good link, so neighbors barely wait there; on a link that
    /// can't keep ahead of the stream at all it is never reached, which is
    /// exactly when they shouldn't be competing.
    private static let comfortablyAhead: Double = 15

    /// How far ahead a *preloaded* (not-yet-watched) video buffers. Small on
    /// purpose: enough for an instant start when you reach it, not so much that
    /// the two neighbours the pager warms starve the video actually on screen.
    /// `start` lifts it to `playingForwardBuffer` once a page becomes current.
    private static let preloadForwardBuffer: TimeInterval = 2

    /// How far ahead the clip *being watched* buffers.
    ///
    /// Zero means automatic — AVPlayer sizes it.
    ///
    /// This was twenty seconds, set when the buffer appeared unable to grow past
    /// four. That reading came from a link that was being hairpinned through the
    /// router; once that was fixed the same setting became actively harmful,
    /// because twenty seconds of a 51 Mbps clip is 127 MB, demanded up front and
    /// demanded again after every skip.
    private static let playingForwardBuffer: TimeInterval = 0

    /// Fetches the signed URL and starts buffering, without playing.
    ///
    /// Split from `start` so a video can be got ready before anyone is looking
    /// at it — see `VideoPreloader`. An `AVPlayer` holding an item buffers on
    /// its own, so by the time this page becomes current the first frames are
    /// usually already in hand and playback begins immediately rather than
    /// after a round trip.
    ///
    /// Idempotent: the pager rebuilds neighbours freely, and re-preparing a
    /// video that is already prepared would throw away its buffer.
    func prepare(
        assetID: UUID, client: FrameStationClient?, quality: PlaybackQuality = .default
    ) async {
        guard let client, player == nil, !isPreparing, recovery == nil else { return }
        source = (assetID, client, quality)
        isPreparing = true
        isLoading = true
        defer {
            isPreparing = false
            isLoading = false
        }
        do {
            let playback = try await client.playbackURL(assetID: assetID, quality: quality)
            // The signed URL is deliberately not recorded — it carries a
            // signature, and this log gets shared. What matters is which
            // representation came back, not how to fetch it.
            Diagnostics.shared.log(
                .quality,
                "Asked for \(quality.rawValue); server served \(playback.kind)"
            )
            noteLink(playback)
            let item = AVPlayerItem(url: playback.url)
            // Preloaded, so buffer only a little ahead. Both pages either side
            // are warmed the moment the pager settles; left uncapped, each
            // greedily downloads its forward buffer and three streams fight over
            // one home link — which is what stutters the video on screen every
            // few seconds. `start` lifts the cap when this page becomes current.
            item.preferredForwardBufferDuration = Self.preloadForwardBuffer
            let player = AVPlayer(playerItem: item)
            self.player = player
            lastError = nil
            positionAtInstall = 0

            track(player)
            await describe(item)
            // A page that became current while this was in flight asked to
            // play before there was anything to play.
            if wantsPlayback { start() }
        } catch {
            Diagnostics.shared.log(
                .playback, "Couldn't get a link to play: \(Self.describe(error))"
            )
            // On screen, try again rather than give up on one failed request.
            // A neighbor just waits: it tries again when it's shown.
            if wantsPlayback {
                reconnect(because: "the link request failed", at: 0)
            } else {
                lastError = error
                // A clip that can't play doesn't need the connection.
                onLinkFree?()
            }
        }
    }

    private func noteLink(_ playback: PlaybackURLResponse) {
        linkURL = playback.url
        linkExpiresAt = playback.expiresAt
        linkLifetime = max(60, playback.expiresAt.timeIntervalSinceNow)
        renewingLink = false
    }

    /// Whether the link in hand won't see this clip out but a fresh one would
    /// see it further — a neighbor got ready minutes ago, or a long pause.
    /// Replaced before playing, it never fails a few seconds in.
    private var linkNeedsRenewing: Bool {
        guard let linkExpiresAt else { return false }
        let left = linkExpiresAt.timeIntervalSinceNow
        let remaining = duration > 0 ? max(0, duration - position) : linkLifetime
        // What a fresh link could promise: the rest of the clip if it fits,
        // otherwise nearly all of the link's life.
        let wanted = min(remaining + Self.linkMargin, linkLifetime - Self.linkMargin)
        return left < wanted
    }

    /// Picks the clip up again with a fresh link, from where it was.
    ///
    /// For any way the connection to the clip can be lost. The link ran out —
    /// the NAS signs them for minutes. The NAS restarted for an update, which
    /// throws every link it signed away. The phone moved between networks
    /// under a stream. The link request itself failed. Each used to leave
    /// "Can't Play This Video" on screen with nothing to press; now it gets a
    /// spinner, and the clip carries on from the same moment.
    ///
    /// Backs off over about half a minute, and gives up — showing the error,
    /// with Try Again — only when nothing in that time worked.
    private func reconnect(because reason: String, at seconds: Double? = nil) {
        guard let source, recovery == nil else { return }
        let resumeAt = seconds ?? position
        Diagnostics.shared.log(
            .playback, "Reconnecting at \(Self.mmss(resumeAt)): \(reason)"
        )
        isReconnecting = true
        lastError = nil
        isPlaying = false
        recovery = Task { [weak self] in
            var lastFailure: (any Error)?
            for (attempt, delay) in Self.reconnectDelays.enumerated() {
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled, let self else { return }
                do {
                    let playback = try await source.client.playbackURL(
                        assetID: source.assetID, quality: source.quality
                    )
                    guard !Task.isCancelled else { return }
                    Diagnostics.shared.log(
                        .playback, "Reconnected on attempt \(attempt + 1)"
                    )
                    // Done before installing: `start`, which installing calls,
                    // stands back while a reconnect is under way, and would
                    // leave the clip running with the controls saying paused.
                    self.recovery = nil
                    self.isReconnecting = false
                    self.install(playback, at: resumeAt)
                    return
                } catch {
                    lastFailure = error
                    Diagnostics.shared.log(
                        .playback,
                        "Reconnect attempt \(attempt + 1) failed: \(Self.describe(error))"
                    )
                }
            }
            guard let self else { return }
            Diagnostics.shared.log(.playback, "Gave up reconnecting")
            self.recovery = nil
            self.isReconnecting = false
            self.lastError = lastFailure ?? URLError(.cannotConnectToHost)
            self.onLinkFree?()
        }
    }

    /// Puts a fresh link in the player, at `seconds`, playing if the clip is
    /// wanted. The same player, so the layer on screen never changes hands.
    private func install(_ playback: PlaybackURLResponse, at seconds: Double) {
        noteLink(playback)
        let item = AVPlayerItem(url: playback.url)
        item.preferredForwardBufferDuration = wantsPlayback
            ? Self.playingForwardBuffer : Self.preloadForwardBuffer
        positionAtInstall = seconds
        if let player {
            untrackItem()
            player.replaceCurrentItem(with: item)
            trackItem(item, on: player)
        } else {
            let player = AVPlayer(playerItem: item)
            self.player = player
            track(player)
            Task { await describe(item) }
        }
        if seconds > 0 {
            position = seconds
            player?.seek(
                to: CMTime(seconds: seconds, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero
            )
        }
        if wantsPlayback { start() }
    }

    /// Try Again, and the NAS coming back: a clip that gave up starts over
    /// from where it stopped, with all its attempts back.
    func retry() {
        guard lastError != nil || player == nil else { return }
        failuresWithoutProgress = 0
        wantsPlayback = true
        reconnect(because: "trying again", at: position)
    }

    /// The player gave up on the link it had: refused, or cut off.
    private func itemFailed(_ item: AVPlayerItem, _ error: (any Error)?, while stage: String) {
        // A failure from an item already replaced is history.
        guard item === player?.currentItem else { return }
        var details = Self.describe(error)
        // AVFoundation's own record says what the server answered, which the
        // error alone often doesn't: a refused link is a 404 here. The address
        // is left out — it carries the link's signature.
        if let event = item.errorLog()?.events.last {
            details += " — log: \(event.errorDomain) \(event.errorStatusCode)"
            if let comment = event.errorComment, !comment.isEmpty {
                details += " \(comment)"
            }
        }
        Diagnostics.shared.log(
            .playback, "Playback failed \(stage) at \(Self.mmss(position)): \(details)"
        )
        isPlaying = false
        failuresWithoutProgress += 1
        guard failuresWithoutProgress <= Self.maxFailuresWithoutProgress else {
            Diagnostics.shared.log(.playback, "Failed too often without playing; stopping")
            lastError = error ?? URLError(.networkConnectionLost)
            onLinkFree?()
            return
        }
        reconnect(because: "the player lost its link \(stage)")
    }

    /// An error as the log should show it: where it came from and its code,
    /// and the same for what caused it. Codes rather than sentences — the
    /// sentence for a refused link and for a dead network can be the same.
    static func describe(_ error: (any Error)?) -> String {
        guard let error else { return "no error given" }
        let ns = error as NSError
        var text = "\(ns.domain) \(ns.code)"
        if let client = error as? FrameStationClientError, case .http(let status, _) = client {
            text += " (HTTP \(status))"
        }
        var cause = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        var depth = 0
        while let underlying = cause, depth < 3 {
            text += " ← \(underlying.domain) \(underlying.code)"
            cause = underlying.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return text
    }

    /// Claims the connection for this clip ahead of its first byte — see
    /// `onNeedsLink`. Called by the page it is on screen in, before the signed
    /// URL is even fetched, so the pages either side don't start first.
    func needsLink() {
        isAhead = false
        onNeedsLink?()
    }

    /// Begins, or resumes, playback of an already-prepared video.
    func start() {
        wantsPlayback = true
        needsLink()
        guard let player else {
            // Shown with nothing to play: the link request failed while this
            // was a neighbor. Ask again now that it's wanted.
            if !isPreparing, recovery == nil, source != nil {
                reconnect(because: "it was shown without a link", at: position)
            }
            return
        }
        guard recovery == nil else { return }
        if linkNeedsRenewing {
            reconnect(
                because: "its link was about to run out", at: hasFinished ? 0 : position
            )
            return
        }
        configureAudioSession()
        // On screen now: ask for a real cushion so the playing clip can get
        // ahead — the neighbours stay capped low, so it isn't fighting them for
        // the link — and let AVPlayer hold off starting until it has enough to
        // play through without an immediate stall.
        bufferFreely(true)
        // AVPlayer decides when there is enough to play. It is better at this
        // than we are, and the evidence is unambiguous.
        //
        // This was false, to make play and the skips answer instantly. The
        // measurements show what that actually bought: the player started with
        // almost nothing buffered, ran dry within a fraction of a second, and
        // the recovery below put it straight back — stall, resume, stall, twenty
        // times over, while it pulled 411 MB to advance the playhead two
        // seconds. Not starvation. Thrashing.
        //
        // The premise was that the link could barely carry the stream. It was
        // wrong: the diagnostics measured 117–675 Mbps against a 51 Mbps stream.
        // With that much headroom, waiting for a cushion costs almost nothing and
        // buys back the stability the override destroyed.
        player.automaticallyWaitsToMinimizeStalling = true
        player.play()
        isPlaying = true
        // A clip that never gets going reports no stall — it was never playing
        // to stall — so one still waiting a few seconds on is asked about the
        // same way. A link the NAS stopped accepting while this sat ready as a
        // neighbor is the case: it waits forever otherwise.
        startWatch?.cancel()
        startWatch = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, self.wantsPlayback,
                  let item = self.player?.currentItem,
                  self.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
            else { return }
            self.checkLinkWhileStalled(item)
        }
    }

    /// How far ahead this clip may read.
    ///
    /// The clip on screen gets `playingForwardBuffer`; a neighbour is held to
    /// `preloadForwardBuffer` so warmed pages don't fight the clip being watched
    /// over one home link.
    ///
    /// This has to be re-applied on *every* resume, not just in `start`. `pause`
    /// caps the item, and a clip resumed without lifting the cap again streams
    /// the rest of the video on a two-second buffer — which is the repeated
    /// `buffer EMPTY` / `PLAYBACK STALLED` the diagnostics caught.
    private func bufferFreely(_ freely: Bool) {
        let target = freely ? Self.playingForwardBuffer : Self.preloadForwardBuffer
        player?.currentItem?.preferredForwardBufferDuration = target
        #if DEBUG
        // Says plainly which clip got which policy, so "the cap is still on" is
        // a thing we can read rather than infer from the buffer's shape.
        if Self.verboseDiagnostics {
            print("🎬 forwardBuffer → \(Int(target))s (\(freely ? "playing" : "preload"))")
        }
        #endif
    }

    /// Leaves the buffer intact — this is a page scrolling out of view, not a
    /// video being closed.
    func pause() {
        wantsPlayback = false
        player?.pause()
        // Re-cap: a clip scrolled off (or advanced past) must stop reading
        // ahead, or it keeps pulling bytes in the background and starves the one
        // now on screen. The buffer it already holds stays, so returning to it
        // is still instant.
        bufferFreely(false)
        isPlaying = false
        // Capped at a couple of seconds now, so it has stopped reading.
        onLinkFree?()
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
                // Ignored while a seek is in flight, as well as while a finger
                // owns the scrubber. `skip` moves `position` to where it is
                // going immediately, and this fires every 100ms with where the
                // player still *is* — so without the second guard it stomps that
                // value back a tenth of a second later. Tap +10 twice quickly
                // and the second tap computed from the stale position, landing
                // you 10s on instead of 20, with the bar lurching both ways.
                guard let self, !self.isScrubbing, !self.isSeeking else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                // Some containers only surface a usable duration once playback
                // has actually started.
                if self.duration == 0,
                   let known = player.currentItem?.duration.seconds, known.isFinite {
                    self.duration = known
                }
                if self.position > 0 { self.hasFinished = false }
                if !self.isAhead, let item = player.currentItem {
                    self.noteIfAhead(item, at: time)
                }
                self.noteProgress()
            }
        }
        if let item = player.currentItem { trackItem(item, on: player) }
    }

    /// Everything watched on the item itself, so a fresh link — a new item in
    /// the same player — is watched the same way. See `install`.
    private func trackItem(_ item: AVPlayerItem, on player: AVPlayer) {
        untrackItem()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.hasFinished = true
                self?.onLinkFree?()
            }
        }

        // The signed URL resolving is not the same as the video playing. If the
        // NAS goes away mid-stream — or was already gone when AVPlayer went for
        // the bytes — the fetch above has long since succeeded, and without
        // these the viewer sits on a frozen frame with no spinner and nothing
        // to explain itself. AVPlayer streams outside our URLSession, so this
        // is the only place that failure is visible.
        statusObserver = item.observe(\.status, options: [.new]) {
            [weak self] item, _ in
            guard item.status == .failed else { return }
            MainActor.assumeIsolated {
                self?.itemFailed(item, item.error, while: "loading")
            }
        }

        // Restart after a stall.
        //
        // `automaticallyWaitsToMinimizeStalling` is false so that play and the
        // ±10s skips answer immediately, and the price of that is this: AVPlayer
        // no longer manages buffering on our behalf, so when the buffer runs dry
        // it stops and stays stopped. Left alone that is a video which plays,
        // halts, and never comes back — worse than the hesitation the flag was
        // costing us.
        //
        // Watching `isPlaybackLikelyToKeepUp` rather than the stall
        // notification: the stall says it has gone wrong, this says it is safe
        // to carry on. Guarded by `isPlaying`, which is intent, so a clip the
        // viewer paused is never started again behind their back.
        recoveryObserver = item.observe(
            \.isPlaybackLikelyToKeepUp, options: [.new]
        ) { [weak self] item, _ in
            MainActor.assumeIsolated {
                guard let self, item.isPlaybackLikelyToKeepUp, self.isPlaying,
                      let player = self.player, player.timeControlStatus != .playing
                else { return }
                // Recorded, not acted on. Forcing `play()` here the instant
                // `isPlaybackLikelyToKeepUp` went true — which it does on a very
                // thin buffer — is what turned a single stall into a loop of
                // them. With `automaticallyWaitsToMinimizeStalling` back on,
                // AVPlayer resumes on its own once it genuinely has enough.
                _ = player
                Diagnostics.shared.log(
                    .playback, "Buffer refilled at \(Self.mmss(self.position))"
                )
                // What the connection was managing, on every refill and not
                // only on a stall. A log from a slow restaurant connection had
                // two long waits and not one number to say why, because neither
                // was a stall.
                self.measure("refilled")
            }
        }

        // Logged for the report, not the console. A stutter on cellular is the
        // thing still to be fixed and it happens where Xcode cannot watch, so
        // each one is recorded with what the connection was managing at the
        // time — `measure` reads AVFoundation's own accounting.
        stalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Diagnostics.shared.log(.stall, "Stalled at \(Self.mmss(self.position))")
                self.measure("at stall")
                self.checkLinkWhileStalled(item)
            }
        }

        #if DEBUG
        diagnose(player)
        #endif

        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] note in
            let failure = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? (any Error)
            MainActor.assumeIsolated {
                self?.itemFailed(item, failure, while: "playing")
            }
        }

    }

    /// Asks the NAS, while the clip is stalled, whether it still accepts the
    /// link — and fetches a fresh one the moment it doesn't.
    ///
    /// A link that has run out, or one the NAS no longer knows because it
    /// restarted for an update, is refused with a 404, and the player does not
    /// fail over that. It asks again with the same dead link, a dozen times a
    /// second, and stalls for good: no error, no end, a frozen frame with a
    /// play button. Nothing it reports says why — not its status, not its
    /// error log. Measured on the dev server restarted mid-clip.
    ///
    /// So a stall is asked about directly: one byte of the clip, by the same
    /// link. Refused means renew. Answered means the network is merely slow,
    /// and the player rides that out itself. No answer means the NAS is still
    /// on its way back, and it is asked again a few seconds later, for as long
    /// as the clip stays stalled.
    private func checkLinkWhileStalled(_ item: AVPlayerItem) {
        guard linkCheck == nil, recovery == nil, let url = linkURL else { return }
        linkCheck = Task { [weak self] in
            defer { self?.linkCheck = nil }
            for attempt in 0..<20 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(3)) }
                guard !Task.isCancelled, let self, item === self.player?.currentItem,
                      self.recovery == nil,
                      self.player?.timeControlStatus != .playing
                else { return }
                var request = URLRequest(url: url, timeoutInterval: 10)
                request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                let status = (try? await URLSession.shared.data(for: request))
                    .flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
                guard !Task.isCancelled else { return }
                Diagnostics.shared.log(
                    .playback,
                    "Link check while stalled at \(Self.mmss(self.position)): "
                        + (status.map { "HTTP \($0)" } ?? "no answer")
                )
                switch status {
                case .some(400..<500):
                    self.linkRefused(status: status ?? 404)
                    return
                case .some(200..<300):
                    return
                default:
                    continue
                }
            }
            // A minute without an answer. Rather than a frozen frame with no
            // explanation, stop asking and say so — with Try Again, and the NAS
            // answering again starts it by itself. See `connectionReturned`.
            guard let self, !Task.isCancelled, item === self.player?.currentItem,
                  self.player?.timeControlStatus != .playing
            else { return }
            Diagnostics.shared.log(.playback, "No answer from the NAS for a minute; stopping")
            self.player?.pause()
            self.isPlaying = false
            self.lastError = URLError(.cannotConnectToHost)
            self.onLinkFree?()
        }
    }

    /// The NAS answering again, as the connection monitor sees it. A clip that
    /// gave up starts again from where it stopped; one still stalled has its
    /// link asked about at once, rather than at its next three-second check.
    func connectionReturned() {
        if lastError != nil {
            retry()
        } else if wantsPlayback, let item = player?.currentItem,
                  player?.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            linkCheck?.cancel()
            linkCheck = nil
            checkLinkWhileStalled(item)
        }
    }

    /// The NAS turned the link down: renew it, unless it has been turned down
    /// over and over without the clip playing in between — then it isn't the
    /// link, and the clip says so.
    private func linkRefused(status: Int) {
        failuresWithoutProgress += 1
        guard failuresWithoutProgress <= Self.maxFailuresWithoutProgress else {
            Diagnostics.shared.log(.playback, "Refused too often without playing; stopping")
            player?.pause()
            isPlaying = false
            lastError = PlaybackRefused(status: status)
            onLinkFree?()
            return
        }
        reconnect(because: "the NAS refused its link (\(status))")
    }

    private func untrackItem() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        if let stalledObserver { NotificationCenter.default.removeObserver(stalledObserver) }
        statusObserver?.invalidate()
        recoveryObserver?.invalidate()
        linkCheck?.cancel()
        endObserver = nil
        stallObserver = nil
        stalledObserver = nil
        statusObserver = nil
        recoveryObserver = nil
        linkCheck = nil
    }

    /// Called every tick of the clock while there's a player.
    ///
    /// A clip that has played a few seconds on its current link is working
    /// again, and earns back its tries. And a link about to run out in the
    /// middle of a clip with more still to fetch is renewed a little early,
    /// rather than left to fail and stall first.
    private func noteProgress() {
        if failuresWithoutProgress > 0,
           position - positionAtInstall >= Self.progressThatCounts {
            failuresWithoutProgress = 0
        }
        guard isPlaying, !renewingLink, recovery == nil,
              let linkExpiresAt, linkExpiresAt.timeIntervalSinceNow < 15,
              duration - position > 15,
              let item = player?.currentItem, !bufferReachesEnd(item)
        else { return }
        renewingLink = true
        reconnect(because: "its link was running out mid-play")
    }

    /// Whether everything left of the clip is already on the phone, so a link
    /// running out can't matter.
    private func bufferReachesEnd(_ item: AVPlayerItem) -> Bool {
        let now = item.currentTime()
        guard duration > 0,
              let range = item.loadedTimeRanges.map(\.timeRangeValue)
                .first(where: { $0.containsTime(now) })
        else { return false }
        return range.end.seconds >= duration - 0.5
    }

    /// Releases the connection once the buffer is well past the playhead, or
    /// holds everything that is left of the clip.
    ///
    /// Measured on the range the playhead is in: after a skip there can be a
    /// buffered stretch further back that says nothing about what is coming.
    private func noteIfAhead(_ item: AVPlayerItem, at time: CMTime) {
        let now = time.seconds
        guard now.isFinite else { return }
        let ahead = item.loadedTimeRanges
            .map(\.timeRangeValue)
            .first { $0.containsTime(time) }
            .map { $0.end.seconds - now } ?? 0
        let remaining = duration > 0 ? duration - now : .infinity
        guard ahead >= Self.comfortablyAhead || ahead >= remaining - 0.5 else { return }
        isAhead = true
        onLinkFree?()
    }

    // MARK: - Diagnostics

    /// `m:ss`, because a log is read by a person.
    static func mmss(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// AVFoundation's own accounting for this item, written to the log.
    ///
    /// `observedBitrate` is the number that settles arguments: it is what the
    /// connection actually delivered. Set beside the stream's own bitrate it
    /// says whether the link could ever have kept ahead of playback, which is
    /// the difference between a bug and arithmetic. The rest separates the two
    /// failure modes — stalls mean the bytes did not arrive in time, dropped
    /// frames mean they did and the device could not draw them.
    func measure(_ reason: String) {
        guard let event = player?.currentItem?.accessLog()?.events.last else { return }
        var parts: [String] = []
        if event.observedBitrate > 0 {
            parts.append("observed \(Self.mbps(event.observedBitrate))")
        }
        if event.indicatedBitrate > 0 {
            parts.append("stream \(Self.mbps(event.indicatedBitrate))")
        }
        if event.numberOfStalls > 0 { parts.append("stalls \(event.numberOfStalls)") }
        if event.numberOfDroppedVideoFrames > 0 {
            parts.append("dropped \(event.numberOfDroppedVideoFrames)")
        }
        if event.startupTime > 0 {
            parts.append(String(format: "startup %.2fs", event.startupTime))
        }
        if event.numberOfBytesTransferred > 0 {
            parts.append(String(
                format: "%.1f MB", Double(event.numberOfBytesTransferred) / 1_048_576
            ))
        }
        guard !parts.isEmpty else { return }
        Diagnostics.shared.log(.measurement, "\(reason) — " + parts.joined(separator: ", "))
    }

    private static func mbps(_ bitsPerSecond: Double) -> String {
        String(format: "%.1f Mbps", bitsPerSecond / 1_000_000)
    }

    // MARK: - Transport

    func togglePlayPause() {
        guard let player, recovery == nil else { return }
        if isPlaying {
            Diagnostics.shared.log(.action, "Pause at \(Self.mmss(position))")
            measure("paused")
            player.pause()
            isPlaying = false
            // Paused by hand: a reconnect while it sits there mustn't start it.
            wantsPlayback = false
        } else {
            Diagnostics.shared.log(.action, "Play at \(Self.mmss(position))")
            wantsPlayback = true
            // Back after a long pause, the link may have run out. Renewed
            // before playing rather than failing a moment after.
            if linkNeedsRenewing {
                reconnect(
                    because: "resumed after its link ran out",
                    at: hasFinished ? 0 : position
                )
                return
            }
            // Pressing play on a finished clip starts it again rather than
            // sitting on the last frame doing nothing.
            if hasFinished { seek(to: 0, exact: true) }
            // Lift the cap `pause` left on the item. Without this, pausing once
            // meant the rest of the clip streamed on a two-second buffer.
            bufferFreely(true)
            player.play()
            isPlaying = true
            hasFinished = false
        }
    }

    /// Jumps by `delta` seconds. The one people press over and over.
    func skip(by delta: Double) {
        let target = VideoTiming.skipTarget(from: position, by: delta, duration: duration)
        Diagnostics.shared.log(
            .action,
            "Skip \(delta > 0 ? "+" : "")\(Int(delta))s "
                + "(\(Self.mmss(position)) → \(Self.mmss(target)))"
        )
        // Glide the playhead across rather than teleporting it. The bar snapping
        // ten seconds sideways reads as a glitch; traveling there reads as a
        // jump you asked for, which is the difference between our scrubber and
        // Apple's. Short enough not to lag the finger, and it runs on top of
        // repeated taps — hold down the skip and the bar sweeps rather than
        // stuttering, because each tap re-targets an animation already moving.
        withAnimation(.easeOut(duration: 0.22)) { position = target }
        hasFinished = false
        // Tolerant, not exact. `gobackward.10` / `goforward.10` are "roughly
        // here" jumps you tap over and over, and a frame-exact seek has to
        // decode from the nearest keyframe forward to the precise frame — the
        // pause you feel after a skip. Snapping to that keyframe lands within a
        // moment of the target and returns instantly, which is what a skip
        // should feel like.
        seek(to: target, exact: false)
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

    #if DEBUG
    /// Streaming diagnostics, console-only — every line is prefixed 🎬 so you
    /// can filter the Xcode log to it. Prints each stall, each buffer-empty /
    /// likely-to-keep-up flip, and the reason the player is waiting, with how
    /// many seconds are buffered ahead of the playhead. A stutter that logs
    /// "buffer EMPTY" and "WAITING — evaluatingBufferingRate/toMinimizeStalls"
    /// is the network under-running the buffer (contention or plain bandwidth);
    /// a stutter with a healthy bufferedAhead points somewhere else.
    /// Set true to get the full play/pause/buffer trace while working on
    /// playback. Off by default: those fire constantly even when everything is
    /// healthy, and a console that always chatters is a console nobody reads.
    /// The two alarms below stay on regardless — they are silent unless
    /// something is actually wrong.
    private static let verboseDiagnostics = false

    private func diagnose(_ player: AVPlayer) {
        guard let item = player.currentItem else { return }

        // Kept unconditionally. Smooth playback depends on reaching the NAS over
        // the local path, and that rests on a DNS record rather than on any code
        // here — so it can regress from outside the app entirely (the AAAA
        // record going away, a new router, an ISP dropping IPv6). These two say
        // so immediately instead of leaving it to be rediscovered.
        diagBufferEmpty = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { item, _ in
            if item.isPlaybackBufferEmpty { print("🎬 buffer EMPTY (stalling)") }
        }
        diagStalled = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
        ) { _ in print("🎬 PLAYBACK STALLED — buffer ran dry mid-play") }

        guard Self.verboseDiagnostics else { return }

        diagKeepUp = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { item, _ in
            print("🎬 likelyToKeepUp=\(item.isPlaybackLikelyToKeepUp) bufferedAhead=\(String(format: "%.1f", Self.bufferedAhead(item)))s")
        }
        diagTimeControl = player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            let status: String
            switch player.timeControlStatus {
            case .paused: status = "paused"
            case .waitingToPlayAtSpecifiedRate:
                status = "WAITING — \(player.reasonForWaitingToPlay?.rawValue ?? "unknown")"
            case .playing: status = "playing"
            @unknown default: status = "unknown"
            }
            print("🎬 \(status)")
        }
    }

    // `nonisolated`: the KVO callback above runs off the main actor, and this
    // only reads the item handed to it — no main-actor state — so it is safe to
    // call from there.
    private nonisolated static func bufferedAhead(_ item: AVPlayerItem) -> Double {
        let now = item.currentTime()
        // The range *containing* the playhead, not simply the last one. After a
        // seek the loaded ranges are disjoint, and the last can sit entirely
        // behind the playhead — which is why this reported negative seconds.
        guard let range = item.loadedTimeRanges
            .map(\.timeRangeValue)
            .first(where: { $0.containsTime(now) })
        else { return 0 }
        return (range.start + range.duration).seconds - now.seconds
    }
    #endif

    func stop() {
        recovery?.cancel()
        recovery = nil
        startWatch?.cancel()
        startWatch = nil
        isReconnecting = false
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        untrackItem()
        #if DEBUG
        diagBufferEmpty = nil
        diagKeepUp = nil
        diagTimeControl = nil
        if let diagStalled { NotificationCenter.default.removeObserver(diagStalled) }
        diagStalled = nil
        #endif
        player?.pause()
        player = nil
        isPlaying = false
        onLinkFree?()
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
    /// Fired when the clip reaches its end on its own. Not called for a pause,
    /// a swipe away, or a failure — only for "that one is over".
    var onFinished: () -> Void = {}
    /// Whether this is the page being looked at. False for a neighbour the
    /// pager has built ahead — those prepare but stay silent.
    var isActive: Bool = true
    /// The page being looked at, not playing yet: the clip is still growing
    /// out of its tile in the grid. It prepares, and claims the connection,
    /// but starts once it has arrived.
    ///
    /// Starting is main-thread work — the audio session alone is tens of
    /// milliseconds, and the whole of it came to ninety — and the flight out
    /// of the grid is drawn by SwiftUI, on that same thread. Started in the
    /// middle of it, the clip stopped the flight dead for five frames. Photos
    /// starts a clip once it is open, too.
    var holdsPlayback: Bool = false
    /// Supplied by the viewer so it survives this page scrolling out of view
    /// and back, and so a video can be prepared before it is watched.
    let model: VideoPlaybackModel
    /// Nil on macOS and tvOS, which have no monitor wired up yet; the wording
    /// falls back to classifying the error on its own.
    @Environment(\.connectionMonitor) private var connection

    var body: some View {
        ZStack {
            if let poster, model.player == nil {
                Image(platformImage: poster).resizable().scaledToFit()
            }
            if let player = model.player {
                #if os(iOS)
                // A bare layer, so a tap anywhere reaches the viewer and
                // toggles chrome instead of being eaten by AVKit.
                // The transport (`VideoControls`) no longer lives here. The
                // pager builds each page's hosting controller once and keeps it,
                // so controls baked into a page froze on the clip they were built
                // for and vanished when auto-play moved on. They hang off the
                // viewer now (see AssetDetailView), reading the *current* clip so
                // they follow every advance. The player keeps the double-tap skip
                // zones, which are tied to this layer. (`showsControls` is now
                // vestigial — kept only so the page's call sites stay unchanged.)
                // Not rotated here. The whole viewer turns as one — pager,
                // chrome and picture together — so that a page transition and a
                // swipe run along the axis the viewer actually sees. Rotating
                // just this layer left the pager sliding the portrait way
                // underneath a turned picture. See `AssetDetailView`.
                PlayerLayerView(player: player)
                    .overlay { skipZones }
                #else
                // macOS and tvOS get AVKit's own transport, which is the right
                // answer there: it is the control surface people already know,
                // it takes the Apple TV remote's swipe-to-scrub and the Mac's
                // media keys for free, and neither platform has a chrome-hiding
                // tap for it to interfere with.
                VideoPlayer(player: player)
                #endif
            }
            // Reconnecting is loading, as far as anyone watching can tell: a
            // spinner while the clip gets a fresh link, never an error for a
            // connection that is being put back. See `VideoPlaybackModel.reconnect`.
            if model.isLoading || model.isReconnecting {
                // `controlSize` doesn't exist on tvOS, where the system sizes
                // controls for the 10-foot layout itself.
                #if os(tvOS)
                ProgressView()
                #else
                ProgressView().controlSize(.large)
                #endif
            }
            if let error = model.lastError {
                ContentUnavailableView {
                    Label(
                        "Can't Play This Video",
                        systemImage: connection?.state == .online || connection == nil
                            ? "exclamationmark.triangle" : "wifi.slash"
                    )
                } description: {
                    Text(ConnectionMonitor.mediaMessage(for: error, state: connection?.state))
                } actions: {
                    // The message says "try again". There was nothing to press:
                    // trying again meant leaving the photo and coming back.
                    Button("Try Again") { model.retry() }
                }
            }
        }
        .task {
            // On screen: claim the connection before the first request, so the
            // pages either side — built by the pager at the same moment — wait
            // behind this clip rather than racing it. See `VideoPreloader`.
            if isActive { model.needsLink() }
            // Resolved here rather than inside the model: the connection
            // monitor is an environment value, and the model has no view to
            // read it from.
            await model.prepare(
                assetID: assetID, client: client,
                quality: PlaybackSettings.resolvedQuality(
                    isLocal: NetworkLocality.shared.isLocal
                )
            )
            // The values this task began with. A hold that has lifted since
            // started the clip from the `onChange` below, and a clip asked to
            // play before it was prepared starts itself — see `prepare`.
            if isActive, !holdsPlayback { model.start() }
        }
        .onChange(of: isActive) { _, active in
            // Paused rather than stopped: the buffer is what makes coming back
            // — or arriving from the previous clip — instant.
            active ? model.start() : model.pause()
        }
        .onChange(of: holdsPlayback) { _, held in
            if !held, isActive { model.start() }
        }
        // The NAS answering again is the moment to try, not the next tap. The
        // message for an outage has always said "This will play once it's
        // back"; until this, it didn't.
        .onChange(of: connection?.state) { _, state in
            guard state == .online, isActive else { return }
            model.connectionReturned()
        }
        .onDisappear { model.pause() }
        // The model already tracks this for the replay button; the viewer
        // above needs the same edge to decide whether anything follows.
        .onChange(of: model.hasFinished) { _, finished in
            if finished { onFinished() }
        }
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
/// centered on the video itself, and a single row underneath carrying elapsed
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
                .glassCircle(fallback: .ultraThinMaterial)
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
                .glassCircle(fallback: .ultraThinMaterial)
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
        // No glass capsule. Synology draws this row straight onto the picture —
        // elapsed, track, remaining, mute, edge to edge — and boxing it in a
        // pill made ours read as a widget sitting on the video rather than part
        // of the player. A shadow carries legibility over a bright frame
        // instead, which is what the timecodes needed the capsule for.
        .shadow(radius: 6)
        .padding(.horizontal, 20)
        // Held clear of the viewer's action bar, which floats at the very
        // bottom. Sideways there is far less height to spend — the rotated
        // layer is only as tall as the screen is wide — so the portrait figure
        // pushed the scrubber almost into the middle of the picture.
        .padding(.bottom, MediaTilt.shared.isSideways ? 56 : 104)
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

#if os(iOS)
/// Turns the clip — and only the clip — when the phone is held sideways.
///
/// The window is locked portrait so the grid, the chrome and the tab bar never
/// lie on their side. Nothing therefore rotates on its own, which means filling
/// the screen with a landscape video is something we have to do by hand: swap
/// the box's width and height, spin it, then drop it back into the portrait
/// bounds centered, so it pivots on the middle of the screen and lands on the
/// glass rather than being cropped to the portrait box it was drawn into.
private struct VideoTilt: ViewModifier {
    // Shared rather than passed in: the pager keeps each page's controller, so
    // a value handed to a page would freeze at what it was when the page was
    // built. See `MediaTilt`.
    private var tilt: MediaTilt { .shared }

    func body(content: Content) -> some View {
        GeometryReader { geo in
            let sideways = tilt.isSideways
            content
                .frame(
                    width: sideways ? geo.size.height : geo.size.width,
                    height: sideways ? geo.size.width : geo.size.height
                )
                .rotationEffect(.degrees(tilt.angle))
                .frame(width: geo.size.width, height: geo.size.height)
                .animation(.easeInOut(duration: 0.28), value: tilt.angle)
        }
    }
}

extension View {
    /// Turns with the phone. For the player layer and for the chrome drawn over
    /// it — controls that stayed upright while the clip turned read as broken,
    /// so the two travel together.
    func videoTilt() -> some View { modifier(VideoTilt()) }
}
#endif
