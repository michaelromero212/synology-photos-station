#if os(iOS)
import CryptoKit
import FrameStationAPI
import FrameStationKit
import Foundation
import Photos

/// Everything the server needs to record one library asset.
///
/// Built either from a queued `BackupItem` (automatic backup) or straight from a
/// `PHAsset` (the share picker), so both paths commit identical metadata.
struct UploadDescriptor {
    var filename: String
    var mime: String
    var mediaType: MediaType
    /// Nil when the uploader genuinely doesn't know — a Live Photo's motion
    /// half, whose size only the file itself records. The server fills what
    /// arrives missing and leaves alone what arrives set, so a guess here is
    /// permanent and a nil is corrected.
    var width: Int?
    var height: Int?
    var durationMs: Int?
    var capturedAt: Date?
    var capturedTZOffset: Int?
    var capturedTZOffsetFallback: Int?
    var latitude: Double?
    var longitude: Double?
    var isRaw: Bool
    var liveGroupID: UUID?
    var burstID: String?
    var burstPick: Bool
    var sourceLocalID: String?

    func commitRequest(spaceID: UUID) -> CommitUploadRequest {
        CommitUploadRequest(
            spaceID: spaceID,
            mediaType: mediaType,
            mime: mime,
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
            sourceLocalID: sourceLocalID
        )
    }
}

extension UploadDescriptor {
    /// Reads a `PHAsset` directly. The timezone rule is the one documented in
    /// ARCHITECTURE.md §4: never claim to know the photographer's offset, only
    /// offer this device's as a fallback the server may use if the file records
    /// none of its own.
    init(asset: PHAsset, candidate: PhotoLibraryScanner.Candidate) {
        filename = candidate.filename
        mime = candidate.mime
        mediaType = candidate.mediaType
        width = asset.pixelWidth
        height = asset.pixelHeight
        durationMs = asset.duration > 0 ? Int(asset.duration * 1000) : nil
        capturedAt = asset.creationDate
        capturedTZOffset = nil
        capturedTZOffsetFallback = asset.creationDate.map {
            TimeZone.current.secondsFromGMT(for: $0)
        }
        latitude = asset.location?.coordinate.latitude
        longitude = asset.location?.coordinate.longitude
        isRaw = candidate.isRaw
        liveGroupID = nil
        burstID = asset.burstIdentifier
        burstPick = asset.burstSelectionTypes.contains(.userPick)
            || asset.burstSelectionTypes.contains(.autoPick)
        sourceLocalID = asset.localIdentifier
    }
}

/// The one path bytes take from the photo library to the NAS.
///
/// Shared deliberately: automatic backup and the share picker differ only in
/// what triggers them, and two copies of a resumable chunked upload would drift.
enum AssetUploader {

    struct Result {
        let assetID: UUID?
        /// The server already had these bytes, so only a placement was created.
        let deduplicated: Bool
        let byteSize: Int64
        let sha256: String
    }

    /// What the uploader is doing right now, so the queue can say so.
    enum Phase {
        /// Pulling the original out of the photo library and hashing it. For a
        /// 4 GB video off iCloud this is not a brief moment.
        case preparing
        /// `sent` of `total` bytes on the wire.
        case sending(sent: Int64, total: Int64)
    }

    /// Exports, hashes, probes, sends only what's missing, and commits.
    /// `resource` names which half of the asset to send. Defaults to the one
    /// holding the photo or video itself; the Live Photo path passes the paired
    /// video instead, which is the same asset and different bytes.
    static func send(
        _ asset: PHAsset,
        descriptor: UploadDescriptor,
        to spaceID: UUID,
        client: FrameStationClient,
        resource: PHAssetResource? = nil,
        isAutomaticBackup: Bool = false,
        onPhase: (@Sendable (Phase) -> Void)? = nil
    ) async throws -> Result {
        guard let resource = resource ?? PhotoLibraryScanner.primaryResource(for: asset) else {
            throw UploadError.noExportableResource
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        onPhase?(.preparing)
        try await PhotoLibraryScanner.export(resource, to: scratch)

        let attributes = try FileManager.default.attributesOfItem(atPath: scratch.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw UploadError.emptyExport }

        let digest = try hashFile(at: scratch)

        let probe = try await client.probeUpload(
            UploadProbeRequest(
                spaceID: spaceID, sha256: digest, byteSize: size,
                filename: descriptor.filename, isAutomaticBackup: isAutomaticBackup
            )
        )

        switch probe.status {
        case .removed:
            // Deleted from this library on purpose. Not an error, and not
            // something to retry.
            throw UploadError.removedByUser

        case .have:
            // Already on the NAS — another family member's copy, or an earlier
            // run. Link it rather than sending the bytes again.
            if let assetID = probe.assetID {
                _ = try await client.linkAsset(
                    spaceID: spaceID, assetID: assetID,
                    LinkAssetRequest(sourceLocalID: descriptor.sourceLocalID)
                )
            }
            return Result(
                assetID: probe.assetID, deduplicated: true, byteSize: size, sha256: digest
            )

        case .need, .partial:
            guard let uploadID = probe.uploadID else { throw UploadError.noUploadSession }
            try await sendChunks(
                probe: probe, uploadID: uploadID, file: scratch, client: client,
                total: size, onPhase: onPhase
            )
            let committed = try await client.commitUpload(
                uploadID: uploadID, descriptor.commitRequest(spaceID: spaceID)
            )
            return Result(
                assetID: committed.assetID, deduplicated: false, byteSize: size, sha256: digest
            )
        }
    }

    /// Sends only the chunks the server says are missing, so a resumed upload
    /// continues instead of restarting a large video from zero.
    private static func sendChunks(
        probe: UploadProbeResponse,
        uploadID: UUID,
        file: URL,
        client: FrameStationClient,
        total: Int64,
        onPhase: (@Sendable (Phase) -> Void)?
    ) async throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        for index in probe.missingChunks {
            try handle.seek(toOffset: UInt64(index) * UInt64(probe.chunkSize))
            let data = try handle.read(upToCount: probe.chunkSize) ?? Data()
            guard !data.isEmpty else { continue }

            let part = file.deletingLastPathComponent()
                .appendingPathComponent("\(file.lastPathComponent).\(index)")
            try data.write(to: part, options: .atomic)
            defer { try? FileManager.default.removeItem(at: part) }

            // Through the background session, so a chunk in flight when iOS
            // suspends us still lands. The file has to outlive the call, which
            // it does — the defer runs after the await.
            let request = try await client.chunkUploadRequest(uploadID: uploadID, index: index)
            // Chunks already on the server count as sent, or a resumed upload
            // would appear to start from zero.
            let baseline = Int64(index) * Int64(probe.chunkSize)
            let (_, response) = try await BackgroundTransfers.shared.upload(
                request, fromFile: part
            ) { sentInChunk in
                onPhase?(.sending(sent: min(baseline + sentInChunk, total), total: total))
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                throw UploadError.chunkRejected(
                    (response as? HTTPURLResponse)?.statusCode ?? -1, index
                )
            }
        }
    }

    /// Streamed — a 4 GB video must not be read into memory to be hashed.
    static func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum UploadError: LocalizedError {
    case noExportableResource
    case emptyExport
    case noUploadSession
    case chunkRejected(Int, Int)
    case removedByUser

    var errorDescription: String? {
        switch self {
        case .noExportableResource:
            return "This item has no file that can be exported."
        case .emptyExport:
            return "The photo exported as an empty file — it may still be downloading from iCloud."
        case .noUploadSession:
            return "The server didn't return an upload session."
        case .removedByUser:
            return "You removed this photo from this library."
        case .chunkRejected(let status, let index):
            return "The server rejected part \(index + 1) of this file (HTTP \(status))."
        }
    }
}
#endif
