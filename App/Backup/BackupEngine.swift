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
    /// The item on the wire right now, with byte progress. Only one at a time —
    /// the engine uploads serially so a slow photo can't be lapped by a fast
    /// one and confuse the queue.
    private(set) var active: ActiveUpload?
    /// Assets this device uploaded since the badges were last cleared. Shown as
    /// a cloud on the tile until the user pulls to refresh, at which point the
    /// upload stops being news and becomes just another photo.
    private(set) var recentlyUploaded: Set<UUID> = []

    func clearUploadBadges() { recentlyUploaded.removeAll() }

    /// What the Task Queue draws a progress bar from.
    struct ActiveUpload: Equatable {
        var localIdentifier: String
        var filename: String
        var byteSize: Int64
        var sentBytes: Int64
        /// Exporting from the photo library, before any bytes are on the wire.
        var isPreparing: Bool

        /// 0…1, or nil while preparing — a bar that sits at zero for a minute
        /// reads as stuck, so the queue shows indeterminate progress instead.
        var fraction: Double? {
            guard !isPreparing, byteSize > 0 else { return nil }
            return min(Double(sentBytes) / Double(byteSize), 1)
        }
    }

    /// Bumped when a run finishes, so the timeline knows to re-read itself.
    /// The photos it just sent are on the NAS now but not yet in the manifest
    /// the grid is drawing from.
    private(set) var completedRuns = 0

    private let container: ModelContainer
    private var session: AppSession
    private var settings: BackupSettings
    private var cancelled = false
    private let connection: ConnectionMonitor

    /// The item an outage stopped on, and how many runs in a row it has done
    /// that. A transport error costs an item nothing, which would let one
    /// genuinely broken item bounce the queue forever if it always failed that
    /// way — this is the backstop that eventually blames the item instead.
    private var stalled: (localIdentifier: String, runs: Int)?

    init(
        container: ModelContainer,
        session: AppSession,
        settings: BackupSettings,
        connection: ConnectionMonitor
    ) {
        self.container = container
        self.session = session
        self.settings = settings
        self.connection = connection
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
        var candidates = PhotoLibraryScanner.scan(includeVideos: settings.includeVideos)
        let context = ModelContext(container)

        let known = (try? context.fetch(FetchDescriptor<BackupItem>())) ?? []

        // What each rule actually means for a scan.
        switch settings.rule {
        case .resume:
            break

        case .scanAll:
            // Sweep the library: anything that didn't make it stands again.
            // Items already uploaded stay skipped — the server would dedupe
            // them by hash anyway, so re-sending is pure cost. A failure or a
            // permanent skip, though, is exactly what this rule is chosen to
            // clear, and an item renamed or moved since is a different file to
            // the server even where the bytes match.
            if settings.rule.retriesPreviousFailures {
                for item in known where item.state == .failed || item.state == .skipped {
                    item.state = .pending
                    item.attempts = 0
                    item.lastError = nil
                }
            }

        case .futureOnly:
            // Only what was taken after the user drew the line. Without a
            // cutoff there's no line to draw, so nothing is excluded.
            candidates = candidates.filter {
                settings.rule.queues(
                    takenAt: $0.asset.creationDate, cutoff: settings.futureCutoff
                )
            }
        }

        // Already-uploaded items are never re-queued by identifier, whichever
        // rule is in force.
        let existing = Set(known.map(\.localIdentifier))

        var added = 0
        for candidate in candidates where !existing.contains(candidate.asset.localIdentifier) {
            let asset = candidate.asset

            // A Live Photo is one asset and two files, and only the pair is the
            // Live Photo — the still alone arrives on the NAS as an ordinary
            // photo with the motion silently gone. Both halves carry the same
            // group id, which is how the server knows they belong together.
            //
            // Not under "Photos Only": that toggle is a deliberate choice to
            // leave video on the phone, and three seconds of motion per photo is
            // still video. The still goes up regardless, just without its pair.
            let pairedVideo = settings.includeVideos
                ? PhotoLibraryScanner.pairedVideoCandidate(for: asset)
                : nil
            let liveGroupID = pairedVideo.map { _ in UUID() }

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
                    || asset.burstSelectionTypes.contains(.autoPick),
                liveGroupID: liveGroupID
            )
            context.insert(item)
            added += 1

            if let pairedVideo, let liveGroupID {
                // Width, height and duration are left at zero on purpose: the
                // motion is a different size to the still, and `descriptor`
                // reads zero as "ask the server" rather than as a measurement.
                let video = BackupItem(
                    localIdentifier: asset.localIdentifier
                        + PhotoLibraryScanner.pairedVideoSuffix,
                    filename: pairedVideo.filename,
                    byteSize: pairedVideo.byteSize,
                    mediaType: MediaType.video.rawValue,
                    mime: pairedVideo.mime,
                    width: 0,
                    height: 0,
                    // The same instant as the still, so the pair never lands in
                    // two different days of the timeline.
                    capturedAt: asset.creationDate,
                    capturedTZOffset: nil,
                    capturedTZOffsetFallback: asset.creationDate.map {
                        TimeZone.current.secondsFromGMT(for: $0)
                    },
                    latitude: asset.location?.coordinate.latitude,
                    longitude: asset.location?.coordinate.longitude,
                    isRaw: false,
                    liveGroupID: liveGroupID
                )
                context.insert(video)
                added += 1
            }
        }

        added += backfillLivePhotos(candidates, known: known, context: context)

        try? context.save()
        refreshProgress(context)
        statusText = added > 0 ? "Queued \(added) new item\(added == 1 ? "" : "s")" : "Up to date"
    }

    /// Gives the motion back to Live Photos queued before pairing existed.
    ///
    /// The scan skips assets it has already seen, so without this a library
    /// backed up before this change would keep every Live Photo's motion on the
    /// phone forever — the still is known, so the asset is never looked at
    /// again.
    ///
    /// Only where the still has not gone up yet. Once it has, its server row
    /// carries no group id, and sending the video now would put a stray
    /// three-second clip in the timeline next to the photo rather than inside
    /// it — worse than the motion staying on the phone. Repairing those needs
    /// a way to stamp an already-committed asset, which does not exist yet.
    private func backfillLivePhotos(
        _ candidates: [PhotoLibraryScanner.Candidate],
        known: [BackupItem],
        context: ModelContext
    ) -> Int {
        guard settings.includeVideos else { return 0 }

        let rows = Dictionary(known.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        var added = 0

        for candidate in candidates {
            let asset = candidate.asset
            let videoID = asset.localIdentifier + PhotoLibraryScanner.pairedVideoSuffix
            guard let still = rows[asset.localIdentifier],
                  still.state != .done,
                  still.liveGroupID == nil,
                  rows[videoID] == nil,
                  let pairedVideo = PhotoLibraryScanner.pairedVideoCandidate(for: asset)
            else { continue }

            let liveGroupID = UUID()
            still.liveGroupID = liveGroupID

            let video = BackupItem(
                localIdentifier: videoID,
                filename: pairedVideo.filename,
                byteSize: pairedVideo.byteSize,
                mediaType: MediaType.video.rawValue,
                mime: pairedVideo.mime,
                width: 0,
                height: 0,
                capturedAt: asset.creationDate,
                capturedTZOffset: nil,
                capturedTZOffsetFallback: asset.creationDate.map {
                    TimeZone.current.secondsFromGMT(for: $0)
                },
                latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude,
                isRaw: false,
                liveGroupID: liveGroupID
            )
            context.insert(video)
            added += 1
        }
        return added
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
            let failure = await upload(
                item, client: client, spaceID: space.id, context: context
            )
            refreshProgress(context)

            // Stop the run rather than marching the rest of the queue into the
            // same wall. Without this the banner would appear while the engine
            // carried on failing three hundred more items against a server
            // that is not there.
            if failure == .unreachable || failure == .authentication { break }
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

    /// Returns why the item failed, or nil if it went up or was skipped.
    /// `start` uses that to decide whether the rest of the queue is worth
    /// attempting.
    @discardableResult
    private func upload(
        _ item: BackupItem,
        client: FrameStationClient,
        spaceID: UUID,
        context: ModelContext
    ) async -> TransferFailure? {
        item.state = .uploading
        item.attempts += 1
        try? context.save()
        statusText = "Backing up \(item.filename)"
        active = ActiveUpload(
            localIdentifier: item.localIdentifier, filename: item.filename,
            byteSize: item.byteSize, sentBytes: 0, isPreparing: true
        )
        defer { active = nil }

        // A Live Photo's video half is queued under a suffixed id, because the
        // queue keys on a unique identifier and one asset holds both halves.
        // Photos only knows the asset by its real id.
        let isPairedVideo = PhotoLibraryScanner.isPairedVideo(item.localIdentifier)
        let assetIdentifier = PhotoLibraryScanner.baseIdentifier(item.localIdentifier)

        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetIdentifier], options: nil
        ).firstObject else {
            // Deleted from the library since the scan. Not an error, and not
            // retryable.
            item.state = .skipped
            item.lastError = "No longer in the photo library"
            try? context.save()
            return nil
        }

        do {
            let localIdentifier = item.localIdentifier
            // Resolved now rather than at scan time: a `PHAssetResource` is a
            // handle into the library, not something a queue row can hold
            // across a relaunch.
            var resource: PHAssetResource?
            if isPairedVideo {
                guard let paired = PhotoLibraryScanner.livePhotoResource(for: asset) else {
                    // The Live Photo lost its motion since the scan — usually
                    // "Convert to Still" in Photos. Nothing to send, and never
                    // will be.
                    item.state = .skipped
                    item.lastError = "No longer a Live Photo"
                    try? context.save()
                    return nil
                }
                resource = paired
            }

            let result = try await AssetUploader.send(
                asset, descriptor: item.descriptor, to: spaceID, client: client,
                resource: resource, isAutomaticBackup: true
            ) { [weak self] phase in
                Task { @MainActor in
                    guard let self, self.active?.localIdentifier == localIdentifier else { return }
                    switch phase {
                    case .preparing:
                        self.active?.isPreparing = true
                    case .sending(let sent, let total):
                        self.active?.isPreparing = false
                        self.active?.sentBytes = sent
                        // The exported size is authoritative; the scan's
                        // estimate can be stale or zero.
                        self.active?.byteSize = total
                    }
                }
            }
            item.sha256 = result.sha256
            item.byteSize = result.byteSize
            item.assetID = result.assetID
            if let assetID = result.assetID { recentlyUploaded.insert(assetID) }
            item.state = .done
            item.completedAt = Date()
            item.lastError = nil
            try? context.save()
            stalled = nil
            connection.noteSuccess()
            return nil
        } catch UploadError.removedByUser {
            // Deliberately deleted from the library. Skipped, not failed, so it
            // never retries and never reappears.
            item.state = .skipped
            item.lastError = "Removed from this library"
            try? context.save()
            // The server answered, which is what this is evidence of.
            connection.noteSuccess()
            return nil
        } catch UploadError.noExportableResource {
            item.state = .skipped
            item.lastError = "No exportable resource"
            try? context.save()
            return nil
        } catch UploadError.chunkRejected(let status, let index) {
            // The only error carrying a bare status rather than a wrapped one.
            return record(
                TransferFailure.classify(httpStatus: status), on: item,
                detail: "The server rejected part \(index + 1) of this file (HTTP \(status)).",
                context: context
            )
        } catch {
            // Reflecting rather than localizing: a URLError or a bare Swift
            // error localizes to "unknown error", which names nothing and
            // sends you looking in the wrong place.
            return record(
                TransferFailure.classify(error), on: item,
                detail: String(reflecting: error), context: context
            )
        }
    }

    /// Applies a failure to the queue row.
    ///
    /// The whole point of the classification: only `.itemFailed` spends one of
    /// the item's three attempts. An outage puts the row back exactly as it
    /// was found, so a phone that spent an afternoon out of signal comes home
    /// with its queue intact rather than three hundred items parked behind a
    /// Retry button nobody knows to press.
    private func record(
        _ failure: TransferFailure,
        on item: BackupItem,
        detail: String,
        context: ModelContext
    ) -> TransferFailure {
        switch failure {
        case .itemFailed:
            item.state = .failed
            item.lastError = detail
            lastError = detail
            stalled = nil

        case .authentication:
            item.attempts -= 1
            item.state = .pending
            lastError = "Sign in again to keep backing up."

        case .unreachable:
            // Three runs in a row stopped by the same item, each of which had
            // to get past a healthy `/health` to start, is no longer credible
            // as an outage. Blame the item so the rest of the queue can move.
            let runs = stalled?.localIdentifier == item.localIdentifier
                ? (stalled?.runs ?? 0) + 1 : 1
            stalled = (item.localIdentifier, runs)
            guard runs < 3 else {
                stalled = nil
                return record(.itemFailed, on: item, detail: detail, context: context)
            }
            item.attempts -= 1
            item.state = .pending
            connection.noteFailure(.unreachable)
        }

        try? context.save()
        return failure
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
