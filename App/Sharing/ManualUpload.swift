#if os(iOS)
import Foundation
import SwiftData

/// One photo a person asked to put somewhere, waiting its turn.
///
/// The same durability the backup queue has always had, for the path that
/// never had it. Sharing two hundred photos into a family album used to live in
/// an array: leave the app, let iOS reclaim it under memory pressure, and the
/// rest of the batch was simply gone — no record, no resume, and nothing to
/// tell you which ones made it. Automatic backup survived exactly that, because
/// it was written for a first run that takes days. There is no reason the two
/// should differ in how well they keep a promise.
///
/// A separate table from `BackupItem` rather than a column on it, for one
/// concrete reason: that model is `@Attribute(.unique)` on `localIdentifier`,
/// so a photograph can appear in it once. Backing a photo up to your own
/// library *and* sharing it into an album are two jobs for the same
/// photograph, and merging them would have meant changing which attribute is
/// unique on a store that is live on a phone with a real queue in it — the one
/// SwiftData change that is not lightweight, and whose failure mode is an app
/// that will not launch.
///
/// The transport underneath is shared and unchanged: both go through
/// `AssetUploader` to `FileUpload` to `BackgroundTransfers`, and both hand a
/// thumbnail over on commit.
@Model
final class ManualUpload {
    /// `PHAsset.localIdentifier` and the destination, joined.
    ///
    /// Composite because the same photograph can legitimately be on its way to
    /// two different albums at once, and a bare local identifier would make the
    /// second request collide with the first.
    @Attribute(.unique) var key: String

    var localIdentifier: String
    var spaceID: UUID
    /// What the grid sorts the pending tile by, so it appears where it will
    /// stay rather than at the head of its day.
    var capturedAt: Date
    var stateRaw: String
    var attempts: Int
    var queuedAt: Date
    var lastError: String?

    var state: State {
        get { State(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }

    enum State: String {
        case pending
        case uploading
        case failed
    }

    static func key(localIdentifier: String, spaceID: UUID) -> String {
        "\(localIdentifier)|\(spaceID.uuidString)"
    }

    init(localIdentifier: String, spaceID: UUID, capturedAt: Date) {
        self.key = Self.key(localIdentifier: localIdentifier, spaceID: spaceID)
        self.localIdentifier = localIdentifier
        self.spaceID = spaceID
        self.capturedAt = capturedAt
        self.stateRaw = State.pending.rawValue
        self.attempts = 0
        self.queuedAt = Date()
    }
}
#endif
