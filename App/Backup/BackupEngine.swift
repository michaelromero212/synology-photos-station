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
    /// The items on the wire right now, with byte progress — up to
    /// `maxConcurrent` at once, keyed by local identifier. Concurrency is the
    /// whole point: a 2 GB video takes one lane while the photos behind it drain
    /// through the others, so a backup's speed no longer depends on the mix.
    private(set) var activeUploads: [ActiveUpload] = []

    /// The first in-flight upload, for the few readers that still want a single
    /// one (the focused-backup progress line). The Task Queue lists them all.
    var active: ActiveUpload? { activeUploads.first }

    /// How many transfers run at once. Small on purpose: enough that photos
    /// flow past a big video, not so many that a home uplink or the NAS is
    /// saturated and every one crawls. Shared with the manual upload paths via
    /// `UploadConcurrency` so backup and uploads move at the same cadence.
    static let maxConcurrent = UploadConcurrency.maxLanes
    /// Assets this device uploaded since the badges were last cleared. Shown as
    /// a cloud on the tile until the user pulls to refresh, at which point the
    /// upload stops being news and becomes just another photo.
    private(set) var recentlyUploaded: Set<UUID> = []

    func clearUploadBadges() { recentlyUploaded.removeAll() }

    /// Adds or replaces the in-flight entry for one item.
    private func setActive(_ upload: ActiveUpload) {
        if let i = activeUploads.firstIndex(where: { $0.localIdentifier == upload.localIdentifier }) {
            activeUploads[i] = upload
        } else {
            activeUploads.append(upload)
        }
    }

    /// Removes an item's in-flight entry once its lane is done with it.
    private func clearActive(_ localIdentifier: String) {
        activeUploads.removeAll { $0.localIdentifier == localIdentifier }
    }

    /// Mutates one in-flight entry in place — how the transfer's byte-progress
    /// callback reaches the right lane's row without disturbing the others.
    private func updateActive(_ localIdentifier: String, _ mutate: (inout ActiveUpload) -> Void) {
        guard let i = activeUploads.firstIndex(where: { $0.localIdentifier == localIdentifier }) else { return }
        mutate(&activeUploads[i])
    }

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

    /// Watches the photo library for new assets while the app runs, and the
    /// task draining its stream into the queue. Both nil unless backup is on.
    private var changeMonitor: PhotoLibraryChangeMonitor?
    private var observationTask: Task<Void, Never>?

    /// The one context a run's lanes share. They all run on the main actor, so
    /// the claim step below is atomic and the shared context is never touched
    /// from two threads — only interleaved cooperatively between `await`s.
    private var runContext: ModelContext?

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

    /// How a wake-up — a scheduled window, or a silent push — reaches whichever
    /// engine the app built. Answers whether anything actually moved.
    ///
    /// A closure rather than a shared instance: the engine needs the session and
    /// model container that only the view tree has, and iOS may launch us
    /// straight into a background task before any of that exists — in which case
    /// this is nil and the wake-up is a no-op rather than a crash.
    ///
    /// `async` and not `() -> Void`, which is what it was and which quietly
    /// wasted every window it was given. The old closure started a detached
    /// `Task` and returned immediately, so `BackupScheduler` called
    /// `setTaskCompleted` before a single photograph had been sent — telling iOS
    /// the work was finished while it was still being started, and inviting
    /// suspension mid-upload. Both callers now wait for the run.
    nonisolated(unsafe) static var backgroundRunner: (@Sendable () async -> Bool)?

    /// Installs `backgroundRunner` and asks for the first window.
    func enableBackgroundRuns() {
        Self.backgroundRunner = { [weak self] in
            guard let self else { return false }
            return await self.runInBackground()
        }
        BackupScheduler.schedule(requiresPower: settings.chargingOnly)
        startObservingLibrary()
        // So the NAS knows from the start whether this device is one worth
        // waking — see `reportBackupState`.
        reportBackupState(force: true)
    }

    /// One wake-up's worth of work: catch up on what the library gained, drain
    /// what is queued, and book the next window.
    ///
    /// The return value is what iOS is told, and telling it honestly is the
    /// point: `.newData` for a window that moved photographs earns more windows,
    /// and claiming it for a window that did nothing is how an app ends up
    /// getting none.
    private func runInBackground() async -> Bool {
        let before = progress.done
        await scanLibrary()
        await start()
        // Chain the next window from the end of this one; iOS only ever honors
        // one pending request at a time.
        BackupScheduler.schedule(requiresPower: settings.chargingOnly)
        return progress.done > before
    }

    func disableBackgroundRuns() {
        Self.backgroundRunner = nil
        BackupScheduler.cancel()
        stopObservingLibrary()
        // Nothing to wake this device for any more. Said plainly rather than
        // left to expire, or the NAS spends its push budget on a phone that has
        // switched backup off.
        reportBackupState(force: true)
    }

    /// Stops everything this engine does for the account that is signing out.
    ///
    /// Called before the session lets go of its connection, because the last
    /// thing it does needs it: telling the NAS this phone no longer has a
    /// backlog, so the silent pushes that nudge a stalled backup stop coming to a
    /// phone that isn't backing anything up for anyone. Without it the engine
    /// outlived the sign-out in every way that mattered — its background window
    /// still booked with iOS, its library observer still registered.
    ///
    /// A transfer already on the wire finishes into the library it was going to;
    /// nothing new is claimed.
    func retire() {
        stop()
        disableBackgroundRuns()
    }

    /// Starts watching the photo library so a photo taken with the app open is
    /// discovered and queued the moment it lands — no waiting for a background
    /// window or a manual "Back Up Now". Idempotent; safe to call again.
    ///
    /// The observer only covers changes while we're registered, which is the
    /// live case. A cold launch's catch-up is still the full `scanLibrary` on
    /// the existing triggers (background window, focused/manual backup) — this
    /// adds live discovery on top rather than replacing that.
    func startObservingLibrary() {
        guard changeMonitor == nil, PhotoLibraryScanner.access == .authorized else { return }
        let monitor = PhotoLibraryChangeMonitor(options: PhotoLibraryScanner.fetchOptions())
        changeMonitor = monitor
        PHPhotoLibrary.shared().register(monitor)

        // Capture the stream, not the monitor: the stream is `Sendable`, so the
        // task carries nothing that must not cross actors, and `enqueueNewAssets`
        // hops back to the main actor on its own.
        let inserted = monitor.inserted
        observationTask = Task { @MainActor [weak self] in
            for await ids in inserted {
                await self?.enqueueNewAssets(withIdentifiers: ids)
            }
        }
    }

    func stopObservingLibrary() {
        if let changeMonitor {
            PHPhotoLibrary.shared().unregisterChangeObserver(changeMonitor)
            changeMonitor.finish()
        }
        changeMonitor = nil
        observationTask?.cancel()
        observationTask = nil
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
            added += insertRows(for: candidate, into: context)
        }

        added += backfillLivePhotos(candidates, known: known, context: context)

        try? context.save()
        refreshProgress(context)
        statusText = added > 0 ? "Queued \(added) new item\(added == 1 ? "" : "s")" : "Up to date"
    }

    /// Turns one library asset into its queue rows — the still, and a paired
    /// row for a Live Photo's motion half — and inserts them. The single place
    /// an asset becomes queue rows, shared by the full scan and the incremental
    /// change observer. Returns how many rows were added.
    private func insertRows(
        for candidate: PhotoLibraryScanner.Candidate,
        into context: ModelContext
    ) -> Int {
        let asset = candidate.asset
        var added = 0

        // A Live Photo is one asset and two files, and only the pair is the
        // Live Photo — the still alone arrives on the NAS as an ordinary photo
        // with the motion silently gone. Both halves carry the same group id,
        // which is how the server knows they belong together.
        //
        // Not under "Photos Only": that toggle is a deliberate choice to leave
        // video on the phone, and three seconds of motion per photo is still
        // video. The still goes up regardless, just without its pair.
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
            // Left to the server. PHAsset records the capture *instant*, not the
            // offset the photographer's clock was on, so the phone's current
            // offset is not evidence about a photo from 2009 — it travels as a
            // labeled fallback below and only applies when the file records no
            // offset of its own.
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
            subtypes: candidate.subtypes,
            liveGroupID: liveGroupID
        )
        context.insert(item)
        added += 1

        if let pairedVideo, let liveGroupID {
            // Width, height and duration are left at zero on purpose: the motion
            // is a different size to the still, and `descriptor` reads zero as
            // "ask the server" rather than as a measurement.
            let video = BackupItem(
                localIdentifier: asset.localIdentifier
                    + PhotoLibraryScanner.pairedVideoSuffix,
                filename: pairedVideo.filename,
                byteSize: pairedVideo.byteSize,
                mediaType: MediaType.video.rawValue,
                mime: pairedVideo.mime,
                width: 0,
                height: 0,
                // The same instant as the still, so the pair never lands in two
                // different days of the timeline.
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

    /// Queues assets the change observer just reported — the live path that
    /// makes a photo you just took start backing up while the app is still
    /// open, without re-enumerating the whole library.
    ///
    /// The identifiers cross from the observer as plain strings; the assets are
    /// re-fetched here on the main actor. `start()` is re-entrant, so kicking it
    /// is safe whether or not a run is already draining the queue.
    func enqueueNewAssets(withIdentifiers ids: [String]) async {
        guard PhotoLibraryScanner.access == .authorized, !ids.isEmpty else { return }

        let includeVideos = settings.includeVideos
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var candidates: [PhotoLibraryScanner.Candidate] = []
        fetched.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || (asset.mediaType == .video && includeVideos) else {
                return
            }
            if let candidate = PhotoLibraryScanner.describe(asset) { candidates.append(candidate) }
        }
        guard !candidates.isEmpty else { return }

        let context = ModelContext(container)
        let known = (try? context.fetch(FetchDescriptor<BackupItem>())) ?? []
        let existing = Set(known.map(\.localIdentifier))

        var added = 0
        for candidate in candidates where !existing.contains(candidate.asset.localIdentifier) {
            added += insertRows(for: candidate, into: context)
        }
        guard added > 0 else { return }

        try? context.save()
        refreshProgress(context)
        statusText = "Queued \(added) new item\(added == 1 ? "" : "s")"
        // Before the run rather than after it, and throttled rather than forced.
        // A photograph taken with the app open moves this device from "nothing
        // to wake for" to "something to wake for", and that transition is worth
        // telling the NAS *now* — the run about to start may well be cut short
        // by the app being put away, and then nothing else would say so.
        reportBackupState()
        await start()
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

    /// False when "Wi-Fi Only" is on and the only path is metered (cellular or a
    /// personal hotspot). The whole point of the setting is that an unattended
    /// backup never spends the user's cellular data.
    ///
    /// Reads `isMetered` and not `isExpensive`. The two are not synonyms here:
    /// `isExpensive` was caught reporting unmetered on a cellular-only path, and
    /// because this gate is the only thing standing between an unattended backup
    /// and someone's data allowance, it failed open — quietly, in the direction
    /// that costs money. `isMetered` takes the radio's word as well as the flag's.
    private var allowedOnCurrentNetwork: Bool {
        !settings.wifiOnly || !connection.isMetered
    }

    /// Re-links this phone's photos to the assets they became on the NAS.
    ///
    /// `LocalOriginals` is memory-only and the queue is not, which is the whole
    /// reason this exists: back up two thousand photos, get force-quit or simply
    /// come back tomorrow, and the NAS may still be deriving thumbnails for
    /// them. Without this the grid would forget it has the originals sitting
    /// right here and go back to drawing gray squares.
    ///
    /// Newest first and bounded, because those are the ones whose derivations
    /// are plausibly still outstanding. Failure is silent: every entry is an
    /// optimisation, and not having it costs a wait, not a photograph.
    func seedLocalOriginals() {
        var descriptor = FetchDescriptor<BackupItem>(
            predicate: #Predicate { $0.assetID != nil },
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 2000
        guard let rows = try? ModelContext(container).fetch(descriptor) else { return }
        LocalOriginals.shared.adopt(
            rows.compactMap { row in
                row.assetID.map { (assetID: $0, localIdentifier: row.localIdentifier) }
            }
        )
    }

    func start() async {
        guard !isRunning else { return }
        guard session.client != nil, settings.targetSpace(in: session.spaces) != nil else {
            lastError = "Not signed in."
            return
        }
        isRunning = true
        cancelled = false

        let context = ModelContext(container)
        runContext = context
        defer {
            isRunning = false
            runContext = nil
            activeUploads.removeAll()
        }
        refreshProgress(context)

        // A small pool of lanes rather than one serial loop. Each lane claims
        // the next row atomically and uploads it; the slow part is the awaited
        // network transfer, so while one lane holds a big video the others keep
        // photos moving. State still mutates only on the main actor between
        // those awaits, so nothing races.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<Self.maxConcurrent {
                group.addTask { @MainActor [weak self] in await self?.drainLane() }
            }
        }

        statusText = progress.summary
        completedRuns += 1
        // The end of a run is the one moment this device knows something the
        // NAS cannot work out for itself: whether there is more to come.
        reportBackupState(force: true)
    }

    /// The last backlog reported to the NAS, and when — so a quiet phone is not
    /// re-sending the same number every time a run ends.
    private var reportedPending: Int?
    private var reportedAt: Date?
    private static let reportInterval: TimeInterval = 5 * 60

    /// Tells the NAS how much is left, so it can wake this device to finish it.
    ///
    /// Fire-and-forget, and deliberately so: this is an optimisation on top of a
    /// backup that completes without it, and a phone on a bad connection must
    /// not have a run held up by a status ping. A failed report costs one
    /// nudge's worth of promptness and nothing else.
    ///
    /// `force` is for the moments that genuinely change the answer — a run
    /// ending, backup being switched on or off. Everything else is throttled,
    /// because the interesting transition is between "some" and "none" rather
    /// than between four thousand and three thousand nine hundred.
    func reportBackupState(force: Bool = false) {
        let pending = Self.backgroundRunner == nil ? 0 : progress.pending
        if !force, let reportedPending, let reportedAt,
           (reportedPending > 0) == (pending > 0),
           Date().timeIntervalSince(reportedAt) < Self.reportInterval {
            return
        }
        guard let client = session.client else { return }
        reportedPending = pending
        reportedAt = Date()
        Task { try? await client.reportBackupState(ReportBackupStateRequest(pending: pending)) }
    }

    /// One upload lane: claim, send, repeat until the queue is empty, the Wi-Fi
    /// gate closes, or a run-ending failure trips `cancelled`.
    private func drainLane() async {
        guard let context = runContext,
              let client = session.client,
              let space = settings.targetSpace(in: session.spaces) else { return }

        while !cancelled {
            // Re-checked each claim so a lane also stops if Wi-Fi drops to
            // cellular mid-backup. The next background window, or reopening the
            // app on Wi-Fi, resumes from exactly here.
            guard allowedOnCurrentNetwork else {
                statusText = "Waiting for Wi‑Fi"
                break
            }
            guard let item = claimNext(context) else { break }
            let failure = await upload(
                item, client: client, spaceID: space.id, context: context
            )
            refreshProgress(context)

            // Stop the whole run rather than marching the other lanes into the
            // same wall — a server that isn't there fails every item the same
            // way. Lanes already mid-transfer finish their item, then stop.
            if failure == .unreachable || failure == .authentication {
                cancelled = true
            }
        }
    }

    func stop() { cancelled = true }

    /// Takes the next retryable row and marks it in-flight, atomically.
    ///
    /// Synchronous and on the main actor, so the pool's lanes are serialized
    /// through it and can never claim the same row: the `.uploading` mark lands
    /// before any other lane's `nextItem` runs, and `nextItem` skips anything
    /// already uploading.
    private func claimNext(_ context: ModelContext) -> BackupItem? {
        guard let item = nextItem(context) else { return nil }
        item.state = .uploading
        item.attempts += 1
        try? context.save()
        return item
    }

    /// The next retryable row, **newest capture first** — so the photo you just
    /// took jumps ahead of a months-old backlog, and a first backup surfaces
    /// recent memories before it works back through the years. `queuedAt` breaks
    /// ties, which burst frames and a Live Photo's two halves share (one capture
    /// instant). Items that failed three times are left alone so one bad asset
    /// can't stall everything behind it.
    ///
    /// A predicate rather than fetch-N-then-filter: `done` rows are never removed
    /// (they are what keeps an asset from being re-queued), so a plain top-N
    /// window fills with them and returns nil once the first N are up — which
    /// stalled any backup of more than N items at exactly N. Selecting the next
    /// *retryable* row directly finds it however much of the queue is already
    /// done, so a library of thousands drains to the end.
    private func nextItem(_ context: ModelContext) -> BackupItem? {
        let pending = BackupItem.State.pending.rawValue
        let failed = BackupItem.State.failed.rawValue
        var descriptor = FetchDescriptor<BackupItem>(
            predicate: #Predicate {
                $0.stateRaw == pending || ($0.stateRaw == failed && $0.attempts < 3)
            },
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse), SortDescriptor(\.queuedAt)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
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
        // The row is already `.uploading` — `claimNext` marked it so no other
        // lane could take it. Here we only show it and send it.
        statusText = "Backing up \(item.filename)"
        setActive(ActiveUpload(
            localIdentifier: item.localIdentifier, filename: item.filename,
            byteSize: item.byteSize, sentBytes: 0, isPreparing: true
        ))
        defer { clearActive(item.localIdentifier) }

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
                resource: resource, isAutomaticBackup: true,
                // Asked before every chunk, so a file that is part-way up when
                // the phone leaves the house stops there rather than finishing
                // over cellular. `drainLane` re-checks the same gate between
                // items; this is the same question asked often enough to matter
                // on a video.
                //
                // Unwrapped before the hop, not optional-chained across it.
                // `self?.x` inside the `MainActor.run` closure reads the
                // captured weak *variable* from concurrently-executing code,
                // which Swift 6 rejects — the same thing `ConnectionMonitor`
                // and the phase handler below both had to be written around.
                shouldContinue: { [weak self] in
                    guard let self else { return false }
                    return await MainActor.run { self.allowedOnCurrentNetwork }
                }
            ) { [weak self] phase in
                Task { @MainActor in
                    guard let self else { return }
                    switch phase {
                    case .preparing:
                        self.updateActive(localIdentifier) { $0.isPreparing = true }
                    case .sending(let sent, let total):
                        self.updateActive(localIdentifier) {
                            $0.isPreparing = false
                            $0.sentBytes = sent
                            // The exported size is authoritative; the scan's
                            // estimate can be stale or zero.
                            $0.byteSize = total
                        }
                    }
                }
            }
            item.sha256 = result.sha256
            item.byteSize = result.byteSize
            item.assetID = result.assetID
            if let assetID = result.assetID {
                recentlyUploaded.insert(assetID)
                // The NAS has the file but not yet a thumbnail of it, and this
                // phone has had one all along. See `LocalOriginals`.
                LocalOriginals.shared.record(
                    assetID: assetID, localIdentifier: item.localIdentifier
                )
            }
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
        } catch UploadError.pausedByCaller {
            // Wi-Fi went away mid-file. Put the row back exactly as it was
            // found — including the attempt `claimNext` spent on it, because
            // the network changing is not the item's fault and three of these
            // would otherwise retire a perfectly good photo. `drainLane`'s own
            // check stops the lane on the next turn of the loop.
            item.state = .pending
            item.attempts = max(item.attempts - 1, 0)
            item.lastError = nil
            try? context.save()
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
        // Counts come from `fetchCount`, which never builds objects — the old
        // full-table fetch materialized every row after *every* upload, and the
        // `done` pile grows without bound over a large backup, so that was
        // O(n) work per item and O(n²) per run: the thing that would jank the
        // UI at thousands. Only the outstanding rows are loaded, and only to sum
        // their bytes and show the head of the queue.
        func count(_ state: BackupItem.State) -> Int {
            let raw = state.rawValue
            return (try? context.fetchCount(
                FetchDescriptor<BackupItem>(predicate: #Predicate { $0.stateRaw == raw })
            )) ?? 0
        }

        var next = BackupProgress()
        next.done = count(.done)
        next.failed = count(.failed)
        next.skipped = count(.skipped)

        let pending = BackupItem.State.pending.rawValue
        let uploading = BackupItem.State.uploading.rawValue
        let outstanding = FetchDescriptor<BackupItem>(
            predicate: #Predicate { $0.stateRaw == pending || $0.stateRaw == uploading },
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        let rows = (try? context.fetch(outstanding)) ?? []
        next.pending = rows.count
        next.bytesRemaining = rows.reduce(0) { $0 + $1.byteSize }
        // The grid only shows the head of the queue; a thousand-item backlog
        // doesn't need a thousand tiles laid out at once.
        queued = rows.prefix(500).map {
            ($0.localIdentifier, $0.capturedAt ?? Date(),
             $0.state == .uploading ? .uploading : .pending)
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
