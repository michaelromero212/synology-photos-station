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

    @State private var model = VideoPlaybackModel()

    var body: some View {
        ZStack {
            if let poster, model.player == nil {
                Image(platformImage: poster).resizable().scaledToFit()
            }
            if let player = model.player {
                VideoPlayer(player: player)
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
