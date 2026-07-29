import Foundation

// Upload wire types. See ARCHITECTURE.md §6 "Upload protocol".
//
// The flow is hash-first:
//   1. Client hashes the original, calls `probe`.
//   2. `have`    → the blob is already on the NAS. Skip transfer entirely and
//                  link it into the space. This makes duplicate family photos
//                  and retries nearly free.
//      `need`    → upload every chunk.
//      `partial` → upload only the chunks listed as missing.
//   3. `commit`  → server re-verifies the hash and creates the asset.

public enum MediaType: String, Codable, Sendable {
    case photo, video
}

public enum UploadProbeStatus: String, Codable, Sendable {
    case have, need, partial
}

public struct UploadProbeRequest: Codable, Sendable {
    public let spaceID: UUID
    /// Lowercase hex SHA-256 of the original bytes, exactly as they will be stored.
    public let sha256: String
    public let byteSize: Int64
    public let filename: String

    public init(spaceID: UUID, sha256: String, byteSize: Int64, filename: String) {
        self.spaceID = spaceID
        self.sha256 = sha256
        self.byteSize = byteSize
        self.filename = filename
    }
}

public struct UploadProbeResponse: Codable, Sendable, Hashable {
    public let status: UploadProbeStatus
    /// Set when `status == .have` — link this asset instead of uploading.
    public let assetID: UUID?
    /// Set when `status == .need` or `.partial`.
    public let uploadID: UUID?
    public let chunkSize: Int
    public let chunkCount: Int
    /// Chunk indices still outstanding. Empty when `status == .have`.
    public let missingChunks: [Int]

    public init(
        status: UploadProbeStatus,
        assetID: UUID?,
        uploadID: UUID?,
        chunkSize: Int,
        chunkCount: Int,
        missingChunks: [Int]
    ) {
        self.status = status
        self.assetID = assetID
        self.uploadID = uploadID
        self.chunkSize = chunkSize
        self.chunkCount = chunkCount
        self.missingChunks = missingChunks
    }
}

public struct ChunkAcceptedResponse: Codable, Sendable, Hashable {
    public let receivedChunks: Int
    public let chunkCount: Int
    public let missingChunks: [Int]

    public init(receivedChunks: Int, chunkCount: Int, missingChunks: [Int]) {
        self.receivedChunks = receivedChunks
        self.chunkCount = chunkCount
        self.missingChunks = missingChunks
    }
}

/// Metadata the *client* knows from `PHAsset` at commit time.
///
/// The server enriches this with its own EXIF/ffprobe extraction in M1b, but
/// the device is authoritative for capture time and timezone — EXIF is often
/// missing or wrong, and `PHAsset.creationDate` is not.
public struct CommitUploadRequest: Codable, Sendable {
    public let spaceID: UUID
    public let mediaType: MediaType
    public let mime: String
    public let width: Int?
    public let height: Int?
    public let durationMs: Int?
    public let capturedAt: Date?
    public let capturedTZOffset: Int?
    public let latitude: Double?
    public let longitude: Double?
    public let isRaw: Bool
    /// Shared by a Live Photo's still and its paired video.
    public let liveGroupID: UUID?
    /// `PHAsset.burstIdentifier`, drives grid stacks.
    public let burstID: String?
    public let burstPick: Bool
    /// `PHAsset.localIdentifier` — a device-local hint only. Not stable across
    /// restores or migrations, so it is never used as identity.
    public let sourceLocalID: String?

    public init(
        spaceID: UUID,
        mediaType: MediaType,
        mime: String,
        width: Int? = nil,
        height: Int? = nil,
        durationMs: Int? = nil,
        capturedAt: Date? = nil,
        capturedTZOffset: Int? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        isRaw: Bool = false,
        liveGroupID: UUID? = nil,
        burstID: String? = nil,
        burstPick: Bool = false,
        sourceLocalID: String? = nil
    ) {
        self.spaceID = spaceID
        self.mediaType = mediaType
        self.mime = mime
        self.width = width
        self.height = height
        self.durationMs = durationMs
        self.capturedAt = capturedAt
        self.capturedTZOffset = capturedTZOffset
        self.latitude = latitude
        self.longitude = longitude
        self.isRaw = isRaw
        self.liveGroupID = liveGroupID
        self.burstID = burstID
        self.burstPick = burstPick
        self.sourceLocalID = sourceLocalID
    }
}

public struct CommitUploadResponse: Codable, Sendable, Hashable {
    public let assetID: UUID
    public let spaceAssetID: UUID
    /// True when the bytes were already on the NAS and no storage was consumed.
    public let deduplicated: Bool
    /// `change_log.seq` of this placement, so a client can advance its cursor
    /// without waiting for the next delta poll.
    public let changeSeq: Int64

    public init(assetID: UUID, spaceAssetID: UUID, deduplicated: Bool, changeSeq: Int64) {
        self.assetID = assetID
        self.spaceAssetID = spaceAssetID
        self.deduplicated = deduplicated
        self.changeSeq = changeSeq
    }
}

/// Links an already-stored blob into a space — the `.have` path, and how a
/// photo moves from Personal to Family Shared without copying bytes.
public struct LinkAssetRequest: Codable, Sendable {
    public let sourceLocalID: String?

    public init(sourceLocalID: String? = nil) {
        self.sourceLocalID = sourceLocalID
    }
}
