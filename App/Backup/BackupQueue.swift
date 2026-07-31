#if os(iOS)
import FrameStationAPI
import Foundation
import SwiftData

/// One asset awaiting backup.
///
/// Persisted rather than held in memory because the engine must survive being
/// killed at any point — iOS terminates background work routinely, and an
/// 800 GB first backup runs for days. Restarting from an empty in-memory list
/// would mean re-hashing everything.
@Model
final class BackupItem {
    /// `PHAsset.localIdentifier`. Device-local and **not** stable across
    /// restores or migrations, so it identifies the row, never the content.
    @Attribute(.unique) var localIdentifier: String

    /// Lowercase hex SHA-256 of the original bytes. Nil until hashed. This is
    /// the real identity — it survives device migration and is what the server
    /// dedupes on.
    var sha256: String?

    var filename: String
    var byteSize: Int64
    var mediaTypeRaw: String
    var mime: String
    var width: Int
    var height: Int
    var durationMs: Int?
    var capturedAt: Date?
    /// Only set when the file itself records an offset. Left nil otherwise.
    var capturedTZOffset: Int?
    /// This device's offset at scan time — the last-resort hint the server uses
    /// when the file records none. See migration 0007.
    var capturedTZOffsetFallback: Int?
    var latitude: Double?
    var longitude: Double?
    var isRaw: Bool
    var burstID: String?
    var burstPick: Bool
    /// Shared by a Live Photo's still and its paired video.
    var liveGroupID: UUID?

    var stateRaw: String
    var attempts: Int
    var lastError: String?
    /// Server-side upload session, so a resumed item continues rather than
    /// restarting a 350 MB video from zero.
    var uploadID: UUID?
    var chunkCount: Int
    var queuedAt: Date
    var completedAt: Date?

    init(
        localIdentifier: String,
        filename: String,
        byteSize: Int64,
        mediaType: String,
        mime: String,
        width: Int,
        height: Int,
        durationMs: Int? = nil,
        capturedAt: Date? = nil,
        capturedTZOffset: Int? = nil,
        capturedTZOffsetFallback: Int? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        isRaw: Bool = false,
        burstID: String? = nil,
        burstPick: Bool = false,
        liveGroupID: UUID? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.filename = filename
        self.byteSize = byteSize
        self.mediaTypeRaw = mediaType
        self.mime = mime
        self.width = width
        self.height = height
        self.durationMs = durationMs
        self.capturedAt = capturedAt
        self.capturedTZOffset = capturedTZOffset
        self.capturedTZOffsetFallback = capturedTZOffsetFallback
        self.latitude = latitude
        self.longitude = longitude
        self.isRaw = isRaw
        self.burstID = burstID
        self.burstPick = burstPick
        self.liveGroupID = liveGroupID
        self.stateRaw = State.pending.rawValue
        self.attempts = 0
        self.chunkCount = 0
        self.queuedAt = Date()
    }

    enum State: String {
        case pending
        case uploading
        case done
        /// Retryable — network blips, server restarts.
        case failed
        /// Not retryable. An asset that cannot be exported at all (corrupt, or
        /// an iCloud original that no longer exists) would otherwise be retried
        /// forever, blocking the queue behind it.
        case skipped
    }

    var state: State {
        get { State(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }
}

/// Progress for the status banner.
struct BackupProgress: Equatable {
    var pending: Int = 0
    var done: Int = 0
    var failed: Int = 0
    var skipped: Int = 0
    var bytesRemaining: Int64 = 0

    var total: Int { pending + done + failed + skipped }
    var isComplete: Bool { pending == 0 && failed == 0 && total > 0 }

    var summary: String {
        if total == 0 { return "Nothing to back up yet" }
        if isComplete { return "Backup complete" }
        if pending > 0 { return "Backing up \(done + 1) of \(total)" }
        if failed > 0 { return "\(failed) item\(failed == 1 ? "" : "s") need retrying" }
        return "Backup complete"
    }
}
#endif

#if os(iOS)
extension BackupItem {
    /// What the queue row commits. Metadata is taken from the row rather than
    /// re-read from the asset, so an item uploads with the values it was
    /// scanned with even if the library changed underneath.
    var descriptor: UploadDescriptor {
        UploadDescriptor(
            filename: filename,
            mime: mime,
            mediaType: MediaType(rawValue: mediaTypeRaw) ?? .photo,
            width: width,
            height: height,
            durationMs: durationMs,
            capturedAt: capturedAt,
            capturedTZOffset: capturedTZOffset,
            capturedTZOffsetFallback: capturedTZOffsetFallback,
            latitude: latitude,
            longitude: longitude,
            isRaw: isRaw,
            liveGroupID: liveGroupID,
            burstID: burstID,
            burstPick: burstPick,
            sourceLocalID: localIdentifier
        )
    }
}
#endif
