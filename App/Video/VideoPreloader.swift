import FrameStationKit
import Foundation
import Observation

/// Keeps a few playback models alive so a video that is about to be watched has
/// already fetched its URL and started buffering.
///
/// The pager builds the pages either side of the current one as soon as it
/// settles, which is the whole reason it replaced `TabView` — that build is the
/// moment a neighbouring video can start preparing. Without this the model
/// lives in the player view's own `@State`, so it is born when the page becomes
/// visible and every arrival pays for a signed URL, an `AVPlayerItem`, and a
/// first buffer while the viewer shows a poster frame.
///
/// Bounded on purpose. Each live model owns an `AVPlayer`, and a library where
/// you can swipe for an hour would otherwise accumulate one per video watched.
@Observable
@MainActor
final class VideoPreloader {
    /// Current, plus one either side. Anything further is a guess that costs a
    /// player to hold.
    static let capacity = 3

    private var models: [UUID: VideoPlaybackModel] = [:]
    /// Most recently asked for last.
    private var recency: [UUID] = []

    func model(for assetID: UUID) -> VideoPlaybackModel {
        touch(assetID)
        if let existing = models[assetID] { return existing }
        let created = VideoPlaybackModel()
        models[assetID] = created
        evictIfNeeded()
        return created
    }

    /// Fetches the URL and starts buffering, without playing.
    ///
    /// Safe to call repeatedly — `prepare` returns immediately once a model has
    /// its player, so the pager rebuilding a neighbour costs nothing.
    func warm(assetID: UUID, client: FrameStationClient?) {
        let model = model(for: assetID)
        Task { await model.prepare(assetID: assetID, client: client) }
    }

    /// Exactly one video plays at a time, and it is the one on screen.
    ///
    /// Relying on the player view disappearing is not enough: the pages are
    /// hosted in view controllers that are built once and kept, so a page
    /// scrolling away does not reliably tear its player down. A clip left
    /// running off-screen keeps its audio going and, worse, quietly plays
    /// itself to the end — so arriving back at it, or auto-advancing into it,
    /// lands on a black frame at `-0:00`.
    ///
    /// Pass nil when the current item is a photo.
    func playOnly(_ assetID: UUID?) {
        for (id, model) in models where id != assetID {
            model.pause()
        }
    }

    private func touch(_ assetID: UUID) {
        recency.removeAll { $0 == assetID }
        recency.append(assetID)
    }

    private func evictIfNeeded() {
        while recency.count > Self.capacity {
            let oldest = recency.removeFirst()
            // Tearing the player down rather than dropping the reference: an
            // AVPlayer left holding a buffered item keeps memory and, on a
            // stream, a connection.
            models.removeValue(forKey: oldest)?.stop()
        }
    }
}
