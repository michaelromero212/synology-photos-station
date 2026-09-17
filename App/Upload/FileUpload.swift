// Not built for tvOS at all.
//
// An Apple TV has no camera, no photo library, no Files app and no way to put a
// photograph anywhere — it is a screen for looking at a library somebody else
// filled. Nothing here would ever be called there, and compiling an upload
// engine into a binary that must never upload is the kind of dead weight that
// eventually grows a caller.
#if !os(tvOS)
import CryptoKit
import FrameStationAPI
import FrameStationKit
import Foundation

/// Everything the server needs to record one library asset.
///
/// Built either from a queued `BackupItem`, straight from a `PHAsset` (the
/// share picker), or from a file a Mac user chose — so every path commits
/// identical metadata.
///
/// Most fields are optional on purpose. The server's derivation pass fills what
/// arrives missing with what exiftool reads out of the file itself, and leaves
/// alone what arrives set, so a client that genuinely does not know a photo's
/// dimensions or capture date should send nothing rather than a guess: a guess
/// is permanent, a nil is corrected. That is what lets the Mac send a file
/// without reimplementing EXIF parsing.
struct UploadDescriptor {
    var filename: String
    var mime: String
    var mediaType: MediaType
    /// Nil when the uploader genuinely doesn't know — a Live Photo's motion
    /// half, whose size only the file itself records, or any file the Mac has
    /// not opened.
    var width: Int?
    var height: Int?
    var durationMs: Int?
    var capturedAt: Date?
    var capturedTZOffset: Int?
    var capturedTZOffsetFallback: Int?
    /// The file's creation date, for a source with no authoritative capture
    /// time. The server uses it only when EXIF has none.
    var capturedAtFallback: Date?
    var latitude: Double?
    var longitude: Double?
    var isRaw: Bool = false
    var liveGroupID: UUID?
    var burstID: String?
    var burstPick: Bool = false
    /// What the device says this is — screenshot, panorama, slo-mo. Empty for
    /// anything not read off a `PHAsset`: a Live Photo's motion half, and every
    /// file uploaded from a Mac, which has no PhotoKit to ask. Those fall back
    /// to the server's heuristics — see migration 0020.
    var subtypes: [MediaSubtype] = []
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
            capturedAtFallback: capturedAtFallback,
            latitude: latitude,
            longitude: longitude,
            isRaw: isRaw,
            liveGroupID: liveGroupID,
            burstID: burstID,
            burstPick: burstPick,
            mediaSubtypes: subtypes,
            sourceLocalID: sourceLocalID
        )
    }
}

/// The resumable upload, from a file on disk to a committed asset.
///
/// Deliberately platform-neutral and deliberately the only copy. Everything
/// after "get the bytes into a file" is identical on every platform — hash,
/// probe, send what's missing, commit — and the one part that genuinely differs
/// is how a chunk goes out: iOS needs its background session so a transfer in
/// flight survives suspension, a Mac just sends it.
///
/// Splitting it this way rather than writing a second uploader for the Mac is
/// the point. Resumable chunked transfer with dedup and a removal check is
/// exactly the kind of code where two copies drift, and the second copy is
/// always the one that stops handling a case the first one learned about.
enum FileUpload {

    struct Result {
        let assetID: UUID?
        /// The server already had these bytes, so only a placement was created.
        let deduplicated: Bool
        let byteSize: Int64
        let sha256: String
    }

    /// What the uploader is doing right now, so a queue can say so.
    enum Phase {
        /// Reading the file and hashing it. For a 4 GB video this is not a
        /// brief moment.
        case preparing
        /// `sent` of `total` bytes on the wire.
        case sending(sent: Int64, total: Int64)
    }

    /// Hashes, probes, sends only what's missing, and commits.
    ///
    /// `shouldContinue`, when given, is asked before every chunk and aborts with
    /// `UploadError.pausedByCaller` the moment it says no. Backup uses it to
    /// stop a file mid-flight when Wi-Fi drops to cellular — see
    /// `BackupEngine.allowedOnCurrentNetwork`. Nothing is lost by stopping: the
    /// chunks already accepted stay on the server and the next run's probe
    /// resumes from exactly there. Defaults to nil, so the Mac drop and the
    /// share sheet — both of which are someone standing there watching — behave
    /// exactly as before.
    static func send(
        file: URL,
        descriptor: UploadDescriptor,
        to spaceID: UUID,
        client: FrameStationClient,
        isAutomaticBackup: Bool = false,
        shouldContinue: (@Sendable () async -> Bool)? = nil,
        onPhase: (@Sendable (Phase) -> Void)? = nil
    ) async throws -> Result {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw UploadError.emptyExport }

        let digest = try hashFile(at: file)

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
                probe: probe, uploadID: uploadID, file: file, client: client,
                total: size, shouldContinue: shouldContinue, onPhase: onPhase
            )
            let committed = try await client.commitUpload(
                uploadID: uploadID, descriptor.commitRequest(spaceID: spaceID)
            )
            #if os(macOS)
            // The Mac's half of the thumbnail handover. iOS does this in
            // `AssetUploader`, where PhotoKit gives a better rendering than
            // anything read back off disk; a Mac has only the file, so it
            // renders from that. Without this, everything dropped on the Mac is
            // a grey tile on every phone until the NAS derives it.
            await sendThumbnail(
                file: file, mediaType: descriptor.mediaType,
                assetID: committed.assetID, client: client
            )
            #endif
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
        shouldContinue: (@Sendable () async -> Bool)?,
        onPhase: (@Sendable (Phase) -> Void)?
    ) async throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        for index in probe.missingChunks {
            // Between chunks and not merely between files. A 3 GB video is one
            // item to the queue but hundreds of chunks on the wire, so a gate
            // checked only at the top of a file lets the whole of that video go
            // out over cellular after the network has already changed underneath
            // it. This is the point where stopping is free.
            if let shouldContinue, await !shouldContinue() {
                throw UploadError.pausedByCaller
            }
            try handle.seek(toOffset: UInt64(index) * UInt64(probe.chunkSize))
            let data = try handle.read(upToCount: probe.chunkSize) ?? Data()
            guard !data.isEmpty else { continue }

            // Chunks already on the server count as sent, or a resumed upload
            // would appear to start from zero.
            let baseline = Int64(index) * Int64(probe.chunkSize)

            // Both transports send from a file rather than memory, so the part
            // is written once here and the platforms differ only in who carries
            // it. It has to outlive the call, which it does — the defer runs
            // after the await.
            //
            // Into the temporary directory, *not* beside the source. This used
            // to write `IMG_4021.jpg.0` next to the original, which was merely
            // untidy on iOS — the source there is always a scratch export this
            // code made itself — and broken on a Mac, where the source is the
            // user's own file wherever they picked it. The sandbox grants
            // access to the *file* the user chose, not to the folder holding
            // it, so creating a sibling threw; the throw was caught upstream,
            // the queue drained, and the upload appeared to do nothing at all.
            let part = FileManager.default.temporaryDirectory
                .appendingPathComponent("fs-chunk-\(uploadID)-\(index)")
            try data.write(to: part, options: .atomic)
            defer { try? FileManager.default.removeItem(at: part) }

            #if os(iOS)
            // Through the background session, so a chunk in flight when iOS
            // suspends us still lands.
            let request = try await client.chunkUploadRequest(uploadID: uploadID, index: index)
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
            #else
            // No background session to need: a Mac is not suspended out from
            // under an upload, so the chunk goes out on the ordinary client and
            // progress ticks once per chunk rather than continuously.
            _ = try await client.uploadChunk(uploadID: uploadID, index: index, fileURL: part)
            onPhase?(.sending(sent: min(baseline + Int64(data.count), total), total: total))
            #endif
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

    #if os(macOS)
    /// Hands the rendered thumbnail over, and never lets that failure matter.
    ///
    /// The upload has already succeeded by the time this runs. Turning a stored
    /// photograph into a thrown error — and therefore into a retry that sends
    /// the whole file again — would be a poor trade for a picture the NAS will
    /// produce on its own a minute later.
    private static func sendThumbnail(
        file: URL, mediaType: MediaType, assetID: UUID?, client: FrameStationClient
    ) async {
        guard let assetID,
              let rendered = FileThumbnail.render(file: file, mediaType: mediaType)
        else { return }
        let request = UploadThumbnailRequest(
            jpeg: rendered.jpeg,
            thumbHash: rendered.thumbHash,
            size: PhotoGridMetrics.thumbnailPixels
        )
        for attempt in 0..<2 {
            do {
                try await client.sendThumbnail(assetID: assetID, request)
                return
            } catch {
                guard attempt == 0, !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }
    #endif
}

enum UploadError: LocalizedError {
    case noExportableResource
    case emptyExport
    case noUploadSession
    case chunkRejected(Int, Int)
    case removedByUser
    case unreadableFile(String)
    /// The caller withdrew permission to keep sending part-way through — for
    /// backup, Wi-Fi dropped to cellular mid-file. Not a failure: the chunks
    /// already on the server stand, and the next run resumes from them.
    case pausedByCaller

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
        case .unreadableFile(let name):
            return "\(name) couldn't be read."
        case .pausedByCaller:
            return "Paused part-way — it will resume where it stopped."
        }
    }


}

#endif
