#if os(iOS)
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

    /// Local items still to go, newest first, grouped for the grid.
    private(set) var queued: [(localIdentifier: String, capturedAt: Date, state: UploadState)] = []
    /// Assets this device uploaded since the badges were last cleared. Shown as
    /// a cloud on the tile until the user pulls to refresh, at which point the
    /// upload stops being news and becomes just another photo.
    private(set) var recentlyUploaded: Set<UUID> = []

    func clearUploadBadges() { recentlyUploaded.removeAll() }

    /// Bumped when a run finishes, so the timeline knows to re-read itself.
    /// The photos it just sent are on the NAS now but not yet in the manifest
    /// the grid is drawing from.
    private(set) var completedRuns = 0

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

    /// How the background task reaches whichever engine the app built.
    ///
    /// A closure rather than a shared instance: the engine needs the session and
    /// model container that only the view tree has, and iOS may launch us
    /// straight into a background task before any of that exists — in which case
    /// this is nil and the wake-up is a no-op rather than a crash.
    nonisolated(unsafe) static var backgroundRunner: (() -> Void)?

    /// Installs `backgroundRunner` and asks for the first window.
    func enableBackgroundRuns() {
        Self.backgroundRunner = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.scanLibrary()
                await self.start()
                // Chain the next window from the end of this one; iOS only ever
                // honours one pending request at a time.
                BackupScheduler.schedule(requiresPower: self.settings.chargingOnly)
            }
        }
        BackupScheduler.schedule(requiresPower: settings.chargingOnly)
    }

    func disableBackgroundRuns() {
        Self.backgroundRunner = nil
        BackupScheduler.cancel()
    }

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
        completedRuns += 1
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

        do {
            let result = try await AssetUploader.send(
                asset, descriptor: item.descriptor, to: spaceID, client: client
            )
            item.sha256 = result.sha256
            item.byteSize = result.byteSize
            item.assetID = result.assetID
            if let assetID = result.assetID { recentlyUploaded.insert(assetID) }
            item.state = .done
            item.completedAt = Date()
            item.lastError = nil
            try? context.save()
        } catch UploadError.noExportableResource {
            item.state = .skipped
            item.lastError = "No exportable resource"
            try? context.save()
        } catch {
            item.state = .failed
            item.lastError = error.localizedDescription
            lastError = error.localizedDescription
            try? context.save()
        }
    }

    // MARK: - Helpers

    private func refreshProgress(_ context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<BackupItem>())) ?? []
        queued = all
            .filter { $0.state == .pending || $0.state == .uploading }
            .sorted { ($0.capturedAt ?? .distantPast) > ($1.capturedAt ?? .distantPast) }
            .map {
                ($0.localIdentifier, $0.capturedAt ?? Date(),
                 $0.state == .uploading ? .uploading : .pending)
            }
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
#endif
