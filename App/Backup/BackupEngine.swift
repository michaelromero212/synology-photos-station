#if os(iOS)
import CryptoKit
import FrameStationAPI
import FrameStationKit
import Foundation
import Observation
import Photos
import SwiftData

/// Drives photos from the system library onto the NAS.
///
/// Deliberately a state machine over a persisted queue rather than an in-memory
/// pipeline: iOS terminates background work routinely and a first backup of
/// this library runs for days. Every step is resumable, and the content hash —
/// not `PHAsset.localIdentifier` — is the identity, because local identifiers
/// do not survive a device restore.
@Observable
@MainActor
final class BackupEngine {
    private(set) var progress = BackupProgress()
    private(set) var isRunning = false
    private(set) var statusText = "Idle"
    private(set) var lastError: String?

    private let container: ModelContainer
    private var session: AppSession
    private var settings: BackupSettings
    private var cancelled = false

    init(container: ModelContainer, session: AppSession, settings: BackupSettings) {
        self.container = container
        self.session = session
        self.settings = settings
    }

    func update(settings: BackupSettings) { self.settings = settings }

    // MARK: - Scanning

    /// Adds anything not already queued. Safe to call repeatedly — the unique
    /// constraint on `localIdentifier` makes re-scanning idempotent.
    func scanLibrary() async {
        guard PhotoLibraryScanner.access == .authorized else {
            lastError = "FrameStation needs access to all your photos to back them up."
            return
        }

        statusText = "Scanning library…"
        let candidates = PhotoLibraryScanner.scan(includeVideos: settings.includeVideos)
        let context = ModelContext(container)

        let existing = Set(
            (try? context.fetch(FetchDescriptor<BackupItem>()))?.map(\.localIdentifier) ?? []
        )

        var added = 0
        for candidate in candidates where !existing.contains(candidate.asset.localIdentifier) {
            let asset = candidate.asset
            let item = BackupItem(
                localIdentifier: asset.localIdentifier,
                filename: candidate.filename,
                byteSize: candidate.byteSize,
                mediaType: candidate.mediaType.rawValue,
                mime: candidate.mime,
                width: asset.pixelWidth,
                height: asset.pixelHeight,
                durationMs: asset.duration > 0 ? Int(asset.duration * 1000) : nil,
                // PHAsset is authoritative for capture time: EXIF is frequently
                // absent or timezone-naive, creationDate is not.
                capturedAt: asset.creationDate,
                // Left to the server. PHAsset records the capture *instant*,
                // not the offset the photographer's clock was on, so the phone's
                // current offset is not evidence about a photo from 2009 — it
                // travels as a labelled fallback below and only applies when the
                // file records no offset of its own.
                capturedTZOffset: nil,
                capturedTZOffsetFallback: asset.creationDate.map {
                    TimeZone.current.secondsFromGMT(for: $0)
                },
                latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude,
                isRaw: candidate.isRaw,
                burstID: asset.burstIdentifier,
                burstPick: asset.burstSelectionTypes.contains(.userPick)
                    || asset.burstSelectionTypes.contains(.autoPick)
            )
            context.insert(item)
            added += 1
        }

        try? context.save()
        refreshProgress(context)
        statusText = added > 0 ? "Queued \(added) new item\(added == 1 ? "" : "s")" : "Up to date"
    }

    // MARK: - Uploading

    func start() async {
        guard !isRunning else { return }
        guard let client = session.client, let space = settings.targetSpace(in: session.spaces) else {
            lastError = "Not signed in."
            return
        }
        isRunning = true
        cancelled = false
        defer { isRunning = false }

        let context = ModelContext(container)
        refreshProgress(context)

        while !cancelled {
            guard let item = nextItem(context) else { break }
            await upload(item, client: client, spaceID: space.id, context: context)
            refreshProgress(context)
        }

        statusText = progress.summary
    }

    func stop() { cancelled = true }

    /// Oldest-first among retryable work. Items that failed three times are
    /// left alone so one bad asset can't stall everything behind it.
    private func nextItem(_ context: ModelContext) -> BackupItem? {
        var descriptor = FetchDescriptor<BackupItem>(
            sortBy: [SortDescriptor(\.queuedAt)]
        )
        descriptor.fetchLimit = 200
        let batch = (try? context.fetch(descriptor)) ?? []
        return batch.first {
            $0.state == .pending || ($0.state == .failed && $0.attempts < 3)
        }
    }

    private func upload(
        _ item: BackupItem,
        client: FrameStationClient,
        spaceID: UUID,
        context: ModelContext
    ) async {
        item.state = .uploading
        item.attempts += 1
        try? context.save()
        statusText = "Backing up \(item.filename)"

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        do {
            guard let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [item.localIdentifier], options: nil
            ).firstObject else {
                // Deleted from the library since the scan. Not an error, and not
                // retryable.
                item.state = .skipped
                item.lastError = "No longer in the photo library"
                try? context.save()
                return
            }
            guard let resource = PhotoLibraryScanner.primaryResource(for: asset) else {
                item.state = .skipped
                item.lastError = "No exportable resource"
                try? context.save()
                return
            }

            try await PhotoLibraryScanner.export(resource, to: scratch)

            let attributes = try FileManager.default.attributesOfItem(atPath: scratch.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else { throw BackupError.emptyExport }
            item.byteSize = size

            let digest = try Self.hashFile(at: scratch)
            item.sha256 = digest

            let probe = try await client.probeUpload(
                UploadProbeRequest(
                    spaceID: spaceID, sha256: digest, byteSize: size, filename: item.filename
                )
            )

            switch probe.status {
            case .have:
                // Already on the NAS — someone else's copy, or a previous run.
                // Link it rather than sending the bytes again.
                if let assetID = probe.assetID {
                    _ = try await client.linkAsset(
                        spaceID: spaceID, assetID: assetID,
                        LinkAssetRequest(sourceLocalID: item.localIdentifier)
                    )
                }
                item.state = .done
                item.completedAt = Date()

            case .need, .partial:
                guard let uploadID = probe.uploadID else { throw BackupError.noUploadSession }
                item.uploadID = uploadID
                item.chunkCount = probe.chunkCount
                try? context.save()

                try await sendChunks(
                    probe: probe, uploadID: uploadID, file: scratch, client: client
                )

                _ = try await client.commitUpload(
                    uploadID: uploadID,
                    CommitUploadRequest(
                        spaceID: spaceID,
                        mediaType: MediaType(rawValue: item.mediaTypeRaw) ?? .photo,
                        mime: item.mime,
                        width: item.width,
                        height: item.height,
                        durationMs: item.durationMs,
                        capturedAt: item.capturedAt,
                        capturedTZOffset: item.capturedTZOffset,
                        capturedTZOffsetFallback: item.capturedTZOffsetFallback,
                        latitude: item.latitude,
                        longitude: item.longitude,
                        isRaw: item.isRaw,
                        liveGroupID: item.liveGroupID,
                        burstID: item.burstID,
                        burstPick: item.burstPick,
                        sourceLocalID: item.localIdentifier
                    )
                )
                item.state = .done
                item.completedAt = Date()
            }

            item.lastError = nil
            try? context.save()
        } catch {
            item.state = .failed
            item.lastError = error.localizedDescription
            lastError = error.localizedDescription
            try? context.save()
        }
    }

    /// Sends only the chunks the server says are missing, so a resumed upload
    /// continues instead of restarting a large video from zero.
    private func sendChunks(
        probe: UploadProbeResponse,
        uploadID: UUID,
        file: URL,
        client: FrameStationClient
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

            _ = try await client.uploadChunk(uploadID: uploadID, index: index, fileURL: part)
        }
    }

    // MARK: - Helpers

    /// Streamed — a 4 GB video must not be read into memory to be hashed.
    nonisolated static func hashFile(at url: URL) throws -> String {
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

    private func refreshProgress(_ context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<BackupItem>())) ?? []
        var next = BackupProgress()
        for item in all {
            switch item.state {
            case .pending, .uploading:
                next.pending += 1
                next.bytesRemaining += item.byteSize
            case .done: next.done += 1
            case .failed: next.failed += 1
            case .skipped: next.skipped += 1
            }
        }
        progress = next
    }

    func retryFailed() async {
        let context = ModelContext(container)
        for item in (try? context.fetch(FetchDescriptor<BackupItem>())) ?? []
        where item.state == .failed {
            item.attempts = 0
            item.state = .pending
        }
        try? context.save()
        refreshProgress(context)
    }
}

enum BackupError: LocalizedError {
    case emptyExport
    case noUploadSession

    var errorDescription: String? {
        switch self {
        case .emptyExport:
            return "The photo exported as an empty file — it may still be downloading from iCloud."
        case .noUploadSession:
            return "The server didn't return an upload session."
        }
    }
}
#endif
