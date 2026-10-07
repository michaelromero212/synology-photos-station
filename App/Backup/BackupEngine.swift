#if os(iOS)
import FrameStationAPI
import FrameStationKit
import Foundation
import Observation
import Photos
import SwiftData
import UIKit

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

    /// How fast the running backup is going, and how long the rest should
    /// take. Nil when no run is going, or it has only just started.
    private(set) var throughput: Throughput?

    struct Throughput: Equatable {
        /// Over the last `throughputWindow`, counting the time spent between
        /// transfers — reading a photo out of the library, the NAS filing it —
        /// as well as the time spent sending. It is how fast the *backup* is
        /// going, which is what the time left has to be worked out from.
        var bytesPerSecond: Double
        var secondsRemaining: Double?

        /// "12.4 MB/s".
        var speed: String {
            ByteCountFormatter.string(
                fromByteCount: Int64(bytesPerSecond), countStyle: .file
            ) + "/s"
        }

        /// "About 14 minutes", or with `remaining`, "About 14 minutes
        /// remaining". Nil until there is a rate to divide by.
        func timeLeft(remaining: Bool = false) -> String? {
            guard let secondsRemaining, secondsRemaining.isFinite else { return nil }
            guard secondsRemaining >= 60 else {
                return remaining ? "Less than a minute remaining" : "Less than a minute"
            }
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .full
            formatter.allowedUnits = [.day, .hour, .minute]
            formatter.maximumUnitCount = 2
            formatter.includesApproximationPhrase = true
            formatter.includesTimeRemainingPhrase = remaining
            return formatter.string(from: secondsRemaining)
        }
    }

    /// Long enough that a photo's pause between transfers doesn't read as the
    /// backup stopping, short enough to follow a change of network.
    private static let throughputWindow: Duration = .seconds(20)
    private var throughputSamples: [(at: ContinuousClock.Instant, bytes: Int64)] = []

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

    /// The run in progress. A second `start()` waits for it rather than
    /// returning at once, which is what lets a background wake-up hold iOS's
    /// window open until the work it started is done. See `start()`.
    private var runTask: Task<Void, Never>?

    /// The last scan asked for. Each one waits for the one before, so two
    /// changes made in quick succession scan twice, in order, rather than at
    /// once against the same queue. See `scanLibrary()`.
    private var scanChain: Task<Void, Never>?

    /// Time iOS lends a run that was going when the app was put away. See
    /// `appWentToBackground()`.
    private var backgroundTime: UIBackgroundTaskIdentifier = .invalid

    /// Starts a waiting backup when the phone is plugged in, under "Only While
    /// Charging". See `watchPower()`.
    private var powerObserver: NSObjectProtocol?

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
        watchPower()
    }

    /// Applies a change made on the settings screen, to what is already waiting
    /// as well as to what comes next.
    ///
    /// Switching backup on scans the library, and so does any change to what
    /// backup covers. It used to only start watching for *new* photos, so the
    /// ones already on the phone waited for Back Up Now, or for whenever iOS
    /// next granted a background window. Switching it off stops the run, which
    /// used to carry on through everything already queued.
    func update(settings new: BackupSettings) {
        let old = settings
        settings = new
        watchPower()
        guard new.enabled else {
            if old.enabled { stop() }
            return
        }
        let coverageChanged = !old.enabled || old.rule != new.rule
            || old.futureCutoff != new.futureCutoff || old.includeVideos != new.includeVideos
        Task {
            if coverageChanged {
                reconcileHolds()
                await scanLibrary()
            }
            // Switched off and straight back on: the run told to stop is still
            // finishing the files it had in flight, and `start()` now would only
            // join it on its way out. Let it go first.
            if cancelled, let runTask { await runTask.value }
            // For every change, not only those: turning off "Wi-Fi Only" on
            // cellular, or "Only While Charging" on battery, should start what
            // was waiting on it.
            await start()
        }
    }

    /// Asks iOS for the first window, and starts watching the library.
    func enableBackgroundRuns() {
        BackupScheduler.schedule(requiresPower: settings.chargingOnly)
        startObservingLibrary()
        // So the NAS knows from the start whether this device is one worth
        // waking — see `reportBackupState`.
        reportBackupState(force: true)
    }

    /// One wake-up's worth of work, from iOS or from the NAS: queue what the
    /// library gained since the app last looked, send what is queued, and book
    /// the next window.
    ///
    /// What the library gained comes from Photos' own change history, not a
    /// scan. A scan describes every photo on the phone, and on a large library
    /// that could use a push's whole half-minute before a byte went; the
    /// history costs only the photos that changed. A full scan is only the
    /// fallback for when that history can't be read.
    ///
    /// The return value is what iOS is told, and telling it honestly is the
    /// point: `.newData` for a window that moved photographs earns more windows,
    /// and claiming it for a window that did nothing is how an app ends up
    /// getting none.
    func runInBackground() async -> Bool {
        guard settings.enabled else { return false }
        let before = progress.done
        // As `resume` does: until the path has reported, "Wi-Fi Only" can only
        // guess, and it must not guess in the direction that spends data.
        await waitForPath()
        if await catchUp() == .unavailable { await scanLibrary() }
        await start()
        // Chain the next window from the end of this one; iOS only ever honors
        // one pending request at a time.
        BackupScheduler.schedule(requiresPower: settings.chargingOnly)
        return progress.done > before
    }

    func disableBackgroundRuns() {
        BackupScheduler.cancel()
        stopObservingLibrary()
        // Nothing to wake this device for any more. Said plainly rather than
        // left to expire, or the NAS spends its push budget on a phone that has
        // switched backup off.
        reportBackupState(force: true)
    }

    /// Asks iOS for time to finish when the app is put away mid-run.
    ///
    /// Without it the app was suspended within seconds of leaving it. Whatever
    /// was mid-transfer froze where it was; coming back, the run still looked
    /// like it was going, so nothing started a new one, and when the frozen
    /// transfer failed the run stopped with the app open in front of it. With
    /// it, iOS allows about half a minute: the files in flight finish, and
    /// every chunk started in that time goes through the background session,
    /// which carries on after the app is suspended.
    func appWentToBackground() {
        guard isRunning, backgroundTime == .invalid else { return }
        backgroundTime = UIApplication.shared.beginBackgroundTask(withName: "Backup") { [weak self] in
            // Out of time. What is mid-chunk finishes in the background session
            // or resumes from the chunks the NAS kept.
            self?.endBackgroundTime()
        }
    }

    /// Hands back time borrowed by `appWentToBackground`. Safe to call
    /// whether or not any was borrowed.
    func endBackgroundTime() {
        guard backgroundTime != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTime)
        backgroundTime = .invalid
    }

    /// Under "Only While Charging", starts a backup that was waiting when the
    /// phone is plugged in, rather than leaving it for the next time the app
    /// is opened.
    private func watchPower() {
        let wanted = settings.enabled && settings.chargingOnly
        if wanted, powerObserver == nil {
            UIDevice.current.isBatteryMonitoringEnabled = true
            powerObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.allowedOnCurrentPower else { return }
                    Task { await self.start() }
                }
            }
        } else if !wanted, let powerObserver {
            NotificationCenter.default.removeObserver(powerObserver)
            self.powerObserver = nil
        }
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
        endBackgroundTime()
        if let powerObserver {
            NotificationCenter.default.removeObserver(powerObserver)
            self.powerObserver = nil
        }
    }

    /// Starts watching the photo library so a photo taken with the app open is
    /// discovered and queued the moment it lands — no waiting for a background
    /// window or a manual "Back Up Now". Idempotent; safe to call again.
    ///
    /// The observer only covers changes while we're registered, which is the
    /// live case. What changed while it wasn't — the app closed, or suspended —
    /// is `catchUp`'s, from Photos' change history, when the app comes back or
    /// is woken in the background.
    func startObservingLibrary() {
        guard changeMonitor == nil, PhotoLibraryScanner.access == .authorized else { return }
        let monitor = PhotoLibraryChangeMonitor(options: PhotoLibraryScanner.fetchOptions())
        changeMonitor = monitor
        PHPhotoLibrary.shared().register(monitor)

        // Capture the stream, not the monitor: the stream is `Sendable`, so the
        // task carries nothing that must not cross actors, and `enqueueNewAssets`
        // hops back to the main actor on its own.
        //
        // Neither waits for the upload run it starts, so a burst of changes is
        // queued as fast as PhotoKit reports it.
        let changes = monitor.changes
        observationTask = Task { @MainActor [weak self] in
            for await change in changes {
                if !change.changed.isEmpty {
                    await self?.enqueueEdits(withIdentifiers: change.changed)
                }
                if !change.inserted.isEmpty {
                    await self?.enqueueNewAssets(withIdentifiers: change.inserted)
                }
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
    ///
    /// One at a time, in the order asked for. Switching backup on and changing
    /// a setting a moment later both ask for a scan, and the second has to see
    /// the settings it was asked under, so it runs after the first rather than
    /// beside it or not at all.
    func scanLibrary() async {
        let previous = scanChain
        let scan = Task {
            await previous?.value
            await self.performScan()
        }
        scanChain = scan
        await scan.value
    }

    private func performScan() async {
        guard PhotoLibraryScanner.access == .authorized else {
            lastError = "FrameStation needs access to all your photos to back them up."
            return
        }

        statusText = "Scanning library…"
        // Where the library's change history stands before the scan reads it,
        // saved once the scan is done: everything up to here the scan has seen,
        // so the next catch-up need only read what comes after. See `catchUp`.
        let mark = LibraryChangeHistory.currentMark()
        // Off the main actor, as `catchUp` already reads the change history.
        // This reads every photo on the phone, and run here it held the main
        // thread for as long as that took. The screen froze for it, and iOS
        // ends an app whose main thread stops answering, for one while it's
        // being switched away from. Photos' objects are immutable, so handing
        // them back across is safe.
        let includeVideos = settings.includeVideos
        var candidates = await Task.detached(priority: .userInitiated) {
            PhotoLibraryScanner.scan(includeVideos: includeVideos)
        }.value
        // Edits follow their photo whichever rule is in force: a rule decides
        // which photos backup takes on, and a photo with an edit to send is one
        // it took on already. See `queueEdits`.
        let library = candidates
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
        added += queueEdits(library, known: known, context: context)
        // Whatever "scan and back up all" just stood up again goes through the
        // same settings as everything else.
        reconcileHolds(context)

        try? context.save()
        if let mark { LibraryChangeHistory.save(mark) }
        refreshProgress(context)
        statusText = added > 0 ? "Queued \(added) new item\(added == 1 ? "" : "s")" : "Up to date"
    }

    /// Queues what the library gained, or had edited, while the app wasn't
    /// running.
    ///
    /// Synology Photos starts on a photo taken with the app closed the moment
    /// it is opened. This didn't: the live observer only hears changes while
    /// it is registered, so those photos waited for a full scan — the next
    /// background window, or Back Up Now. Photos keeps its own history of
    /// changes, though, and hands back just the part after a saved mark, so
    /// catching up costs the photos that changed rather than a read of every
    /// photo on the phone.
    ///
    /// With no mark saved yet, or one so old Photos has let its history go,
    /// there is nothing to read — only a place to start from. What came before
    /// it is the full scan's to find, so that is what this answers, and the
    /// caller runs one.
    private func catchUp() async -> CatchUp {
        guard PhotoLibraryScanner.access == .authorized else { return .caughtUp }
        // Taken before reading, so a photo arriving meanwhile is either in what
        // is read or after the new mark — never lost between the two. Reading
        // it twice costs nothing: the queue already knows it.
        let now = LibraryChangeHistory.currentMark()
        // Off the main actor. A long absence can be a long history.
        let changes = await Task.detached(priority: .userInitiated) {
            LibraryChangeHistory.changesSinceMark()
        }.value
        if let changes {
            if !changes.inserted.isEmpty {
                await enqueueNewAssets(withIdentifiers: changes.inserted)
            }
            if !changes.updated.isEmpty {
                await enqueueEdits(withIdentifiers: changes.updated)
            }
        }
        if let now { LibraryChangeHistory.save(now) }
        return changes == nil ? .unavailable : .caughtUp
    }

    private enum CatchUp {
        case caughtUp
        /// Photos couldn't say what changed, so only a full scan can.
        case unavailable
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
        //
        // Read with the photo, off the main thread. See `PairedVideo`.
        let pairedVideo = settings.includeVideos ? candidate.pairedVideo : nil
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
                localIdentifier: BackupKey.pairedVideo(of: asset.localIdentifier),
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

    /// Queues assets the library has just gained — reported live by the change
    /// observer while the app is open, or read from Photos' change history by
    /// `catchUp` for the time it wasn't — without re-enumerating the library.
    ///
    /// The identifiers cross as plain strings; the assets are re-fetched here
    /// on the main actor. `start()` is re-entrant, so kicking it is safe whether
    /// or not a run is already draining the queue.
    func enqueueNewAssets(withIdentifiers ids: [String]) async {
        guard PhotoLibraryScanner.access == .authorized, !ids.isEmpty else { return }

        let context = ModelContext(container)
        // The ones already queued are set aside before anything is described.
        // Describing reads each photo's files from Photos, and the catch-up
        // hands this every photo added since it last looked — most of which the
        // live observer has usually queued already.
        var knownIDs = FetchDescriptor<BackupItem>()
        knownIDs.propertiesToFetch = [\.localIdentifier]
        let existing = Set(((try? context.fetch(knownIDs)) ?? []).map(\.localIdentifier))
        let fresh = ids.filter { !existing.contains($0) }
        guard !fresh.isEmpty else { return }

        let includeVideos = settings.includeVideos
        let rule = settings.rule
        let cutoff = settings.futureCutoff
        // Off the main actor, as `scanLibrary` reads the library. Describing
        // reads each photo's files, and Photos loads their details on demand:
        // on the main thread that was the "Missing prefetched properties …
        // on the main queue" warning once per photo, and a catch-up can hand
        // this thousands.
        let candidates = await Task.detached(priority: .userInitiated) {
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: fresh, options: nil)
            var candidates: [PhotoLibraryScanner.Candidate] = []
            // A pool per photo, as in `PhotoLibraryScanner.scan`: one pass with
            // nothing in it that pauses.
            fetched.enumerateObjects { asset, _, _ in
                autoreleasepool {
                    guard asset.mediaType == .image
                        || (asset.mediaType == .video && includeVideos)
                    else { return }
                    // Fetched by id, so nothing has left out a shared album
                    // or the Hidden album the way the scan's fetch does.
                    guard PhotoLibraryScanner.isBackedUp(asset) else { return }
                    // The line the full scan draws, drawn here too. New to the
                    // library is not the same as newly taken: a photo saved
                    // from a message, or arriving from iCloud, can be years
                    // old, and "only new photos" means new photographs.
                    guard rule.queues(takenAt: asset.creationDate, cutoff: cutoff) else { return }
                    if let candidate = PhotoLibraryScanner.describe(asset) {
                        candidates.append(candidate)
                    }
                }
            }
            return candidates
        }.value
        guard !candidates.isEmpty else { return }

        var added = 0
        for candidate in candidates {
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
        // Started, not waited for. The observer calls this once per library
        // change, and waiting here held the next change — the rest of a burst of
        // photos — until this whole run had finished: three of four new photos
        // didn't even appear in the grid until the first had uploaded. A run
        // already going takes these rows as it claims its next ones.
        Task { await start() }
    }

    // MARK: - Edits

    /// Sends an edit made after a photo went up as a photo of its own, beside
    /// the one already on the NAS.
    ///
    /// The ledger only ever asked "has this photo been sent?", so a photo edited
    /// after its backup was never looked at again: the NAS kept the version it
    /// had, the phone showed another, and nothing said so. The backup rules
    /// promised otherwise — "changes to previous photos will be backed up as new
    /// files" is Synology's wording, copied onto the settings screen, and until
    /// now nothing did it.
    ///
    /// An edit is keyed on when it was made (see `BackupKey`), so editing again
    /// is another new photo and finding the same edit again is nothing. The
    /// photo already on the NAS is never touched, and reverting on the phone
    /// sends nothing and removes nothing.
    ///
    /// Only once the photo itself has gone. Until then its own upload sends
    /// whatever the phone shows at the time, edits and all — which is also why
    /// a photo edited before its backup, a portrait's blur included, arrives
    /// once rather than twice.
    private func queueEdits(
        _ candidates: [PhotoLibraryScanner.Candidate],
        known: [BackupItem],
        context: ModelContext
    ) -> Int {
        let edited = candidates.filter { $0.editedAt != nil }
        guard !edited.isEmpty else { return 0 }
        let rows = Dictionary(
            known.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first }
        )

        var added = 0
        for candidate in edited {
            guard let editedAt = candidate.editedAt else { continue }
            let asset = candidate.asset
            let photo = asset.localIdentifier
            guard let row = rows[photo], row.state == .done else { continue }
            let key = BackupKey.edit(of: photo, editedAt: editedAt)
            guard rows[key] == nil else { continue }
            if let sent = row.sentVersion {
                // The edit the photo's own upload showed.
                guard sent != key else { continue }
            } else if let completedAt = row.completedAt, editedAt <= completedAt {
                // Went up before versions were recorded, and after this edit
                // was made — so it went up showing it.
                continue
            }

            context.insert(BackupItem(
                localIdentifier: key,
                filename: BackupKey.editedFilename(
                    original: candidate.filename,
                    renderExtension: (candidate.filename as NSString).pathExtension
                ),
                byteSize: candidate.byteSize,
                mediaType: candidate.mediaType.rawValue,
                mime: candidate.mime,
                // The edit is what PhotoKit's size and duration describe.
                width: asset.pixelWidth,
                height: asset.pixelHeight,
                durationMs: asset.duration > 0 ? Int(asset.duration * 1000) : nil,
                // The same moment as the photo, so the two sit side by side.
                capturedAt: asset.creationDate,
                capturedTZOffset: nil,
                capturedTZOffsetFallback: asset.creationDate.map {
                    TimeZone.current.secondsFromGMT(for: $0)
                },
                latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude,
                isRaw: candidate.isRaw,
                // A photo of its own, so no burst and no Live Photo pairing: in
                // the burst it would be a frame the camera never took.
                subtypes: candidate.subtypes
            ))
            added += 1
        }
        return added
    }

    /// Picks up an edit made while the app is open, without a full scan.
    ///
    /// Fed by every change PhotoKit reports, and most of those are not edits —
    /// a favorite, an album, iCloud catching up — so a photo PhotoKit says has
    /// no edits is passed over before anything else is read, and only the rows
    /// of the few that do are fetched.
    func enqueueEdits(withIdentifiers ids: [String]) async {
        guard PhotoLibraryScanner.access == .authorized, !ids.isEmpty else { return }
        let includeVideos = settings.includeVideos
        // Off the main actor, for the reason `enqueueNewAssets` gives.
        let candidates = await Task.detached(priority: .userInitiated) {
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var candidates: [PhotoLibraryScanner.Candidate] = []
            // A pool per photo, as in `PhotoLibraryScanner.scan`.
            fetched.enumerateObjects { asset, _, _ in
                autoreleasepool {
                    guard asset.hasAdjustments,
                          asset.mediaType == .image
                            || (asset.mediaType == .video && includeVideos),
                          PhotoLibraryScanner.isBackedUp(asset),
                          let candidate = PhotoLibraryScanner.describe(asset),
                          candidate.editedAt != nil
                    else { return }
                    candidates.append(candidate)
                }
            }
            return candidates
        }.value
        guard !candidates.isEmpty else { return }

        // Each photo's own row, and the row its edit would have if queued.
        let wanted = candidates.flatMap { candidate -> [String] in
            let photo = candidate.asset.localIdentifier
            guard let editedAt = candidate.editedAt else { return [photo] }
            return [photo, BackupKey.edit(of: photo, editedAt: editedAt)]
        }
        let context = ModelContext(container)
        let known = (try? context.fetch(FetchDescriptor<BackupItem>(
            predicate: #Predicate { wanted.contains($0.localIdentifier) }
        ))) ?? []

        let added = queueEdits(candidates, known: known, context: context)
        guard added > 0 else { return }
        try? context.save()
        refreshProgress(context)
        statusText = "Queued \(added) edit\(added == 1 ? "" : "s")"
        reportBackupState()
        Task { await start() }
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
            let videoID = BackupKey.pairedVideo(of: asset.localIdentifier)
            guard let still = rows[asset.localIdentifier],
                  still.state != .done,
                  still.liveGroupID == nil,
                  rows[videoID] == nil,
                  let pairedVideo = candidate.pairedVideo
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

    /// Every reason a run may send right now: backup switched on, a network
    /// "Wi-Fi Only" allows, and power "Only While Charging" allows. Asked before
    /// each file, and before each chunk of one.
    private var maySend: Bool {
        settings.enabled && allowedOnCurrentNetwork && allowedOnCurrentPower
    }

    /// Runs the queue, or waits for the run already going.
    ///
    /// Waiting rather than returning is what keeps a background wake-up's
    /// window open. A catch-up that queues something starts a run of its own,
    /// and the wake-up's `start()` used to see it running and return, which
    /// told iOS the window was finished with uploads still to send.
    ///
    /// Checks the backup toggle itself, so nothing that calls this (a
    /// reconnect, a new photo, a wake-up) can send with backup switched off.
    func start() async {
        if let runTask {
            await runTask.value
            return
        }
        guard settings.enabled else { return }
        guard session.client != nil, settings.targetSpace(in: session.spaces) != nil else {
            lastError = "Not signed in."
            return
        }
        let run = Task {
            await self.run()
            // Cleared by the run itself rather than by whoever started it, so
            // anything waiting on it finds no run going when it resumes.
            self.runTask = nil
        }
        runTask = run
        await run.value
    }

    private func run() async {
        isRunning = true
        cancelled = false

        let context = ModelContext(container)
        runContext = context
        // Measured once a second for as long as the run goes. See `throughput`.
        let meter = Task { [weak self] in
            while !Task.isCancelled {
                self?.measureThroughput()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer {
            isRunning = false
            runContext = nil
            activeUploads.removeAll()
            meter.cancel()
            throughput = nil
            throughputSamples.removeAll()
            endBackgroundTime()
        }
        reclaimInterrupted(context)
        reconcileHolds(context)
        refreshProgress(context)

        // A small pool of lanes rather than one serial loop. Each lane claims
        // the next row atomically and uploads it; the slow part is the awaited
        // network transfer, so while one lane holds a big video the others keep
        // photos moving. State still mutates only on the main actor between
        // those awaits, so nothing races.
        //
        // Again if anything arrived while the last lanes were finishing: a
        // photograph queued in that moment found the run still marked as
        // running, so its own `start()` returned at once — and without this it
        // waited for the next trigger, which could be the next background
        // window.
        //
        // Only while the lanes could actually take something. They return at
        // once without a connection or a destination, and going round again
        // then would spin on the main actor for as long as rows were waiting.
        repeat {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.maxConcurrent {
                    group.addTask { @MainActor [weak self] in await self?.drainLane() }
                }
            }
        } while !cancelled && maySend && hasDestination
            && nextItem(context) != nil

        // In full: the lanes kept the byte count by subtraction. See
        // `noteFinished`.
        refreshProgress(context)
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
        let pending = settings.enabled ? progress.pending : 0
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

    /// One upload lane: claim, send, repeat until the queue is empty, a setting
    /// says to wait, or a run-ending failure trips `cancelled`.
    private func drainLane() async {
        guard let context = runContext,
              let client = session.client,
              let space = settings.targetSpace(in: session.spaces) else { return }

        while !cancelled {
            // Re-checked each claim, so a lane also stops if backup is switched
            // off, Wi-Fi drops to cellular, or the phone comes off its charger
            // mid-backup. Whatever starts the next run resumes from exactly here.
            guard settings.enabled else { break }
            guard allowedOnCurrentNetwork else {
                statusText = "Waiting for Wi‑Fi"
                break
            }
            guard allowedOnCurrentPower else {
                statusText = "Waiting until charging"
                break
            }
            guard let item = claimNext(context) else { break }
            let claimedBytes = item.byteSize
            let failure = await upload(
                item, client: client, spaceID: space.id, context: context
            )
            noteFinished(item, claimedBytes: claimedBytes, context: context)

            // One dropped connection while the NAS answers isn't an outage.
            // Stopping the run for it is what left a backup sitting still with
            // the app open: a transfer cut off by the app being suspended
            // failed this way on the way back, the NAS was fine, so nothing
            // counted as a reconnect and nothing started the run again. The
            // row is already back in the queue, and an item that keeps failing
            // this way is blamed after three tries (see `record`).
            if failure == .unreachable, await connection.confirmReachable() {
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            // Stop the whole run rather than marching the other lanes into the
            // same wall — a server that isn't there fails every item the same
            // way. Lanes already mid-transfer finish their item, then stop.
            if failure == .unreachable || failure == .authentication {
                cancelled = true
            }
        }
    }

    func stop() { cancelled = true }

    /// Picks backup up when the app comes to the front: the photos taken while
    /// it was closed, and whatever was still queued.
    ///
    /// Nothing used to. A run started from a background window, a new photo, or
    /// Back Up Now — so photographs still queued when the app was last put away
    /// waited, with the app open in front of them, until iOS next felt like
    /// granting a background window. Synology Photos carries on the moment it is
    /// opened, and so does this now.
    ///
    /// Not a scan of the library: a scan describes every photo on the phone,
    /// which is too much to do each time the app is opened. `catchUp` reads only
    /// what changed. Quietly does nothing when there is nothing to send, so
    /// opening the app doesn't report to the NAS or refresh the grid for no
    /// reason.
    func resume() async {
        guard settings.enabled else { return }
        // In front again, so time borrowed for leaving isn't needed.
        endBackgroundTime()
        await waitForPath()
        guard connection.hasReportedPath, hasDestination else { return }
        // Queued whatever the network or power, like a photo taken with the app
        // open: on cellular under "Wi-Fi Only", or on battery under "Only While
        // Charging", it waits in the grid as a tile rather than not being known
        // about at all. A full scan only when Photos can't say what changed.
        if await catchUp() == .unavailable { await scanLibrary() }
        // Checked after the catch-up, not before it: that suspends, and a run
        // that started meanwhile has lanes holding rows `reclaimInterrupted`
        // must not touch. From here to `start()` marking itself running there
        // is no suspension, so nothing can start in between.
        guard runTask == nil, !isRunning, maySend else { return }
        let context = ModelContext(container)
        reclaimInterrupted(context)
        guard nextItem(context) != nil else { return }
        await start()
    }

    /// At launch the path may not have reported yet, and until it has
    /// `isMetered` is only its permissive default. "Wi-Fi Only" is the setting
    /// that must not fail open, so this waits for the real answer — it comes
    /// within milliseconds — rather than start on the guess.
    private func waitForPath() async {
        var waited = 0
        while !connection.hasReportedPath, waited < 40 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
    }

    /// Takes one reading for `throughput`.
    ///
    /// Speed is the bytes that went out across the window, over the window.
    /// Time left is what is still to go over that speed: every queued file's
    /// size, less what the uploads in flight have already sent. Shown only
    /// once there are five seconds to go on — the first moments of a run are
    /// all reading photos out of the library, and a speed worked out from them
    /// would promise hours.
    private func measureThroughput() {
        let now = ContinuousClock.now
        throughputSamples.append((now, BackgroundTransfers.shared.bytesSent))
        throughputSamples.removeAll { now - $0.at > Self.throughputWindow }
        guard let first = throughputSamples.first,
              now - first.at >= .seconds(5)
        else { return }
        let rate = Double(throughputSamples[throughputSamples.count - 1].bytes - first.bytes)
            / ((now - first.at) / .seconds(1))
        guard rate > 0 else {
            throughput = Throughput(bytesPerSecond: 0, secondsRemaining: nil)
            return
        }
        let inFlight = activeUploads.reduce(Int64(0)) { $0 + $1.sentBytes }
        let left = max(progress.bytesRemaining - inFlight, 0)
        throughput = Throughput(bytesPerSecond: rate, secondsRemaining: Double(left) / rate)
    }

    /// Whether there is anywhere to send to: signed in, with a space to back up
    /// into. What `drainLane` needs before it will claim anything.
    private var hasDestination: Bool {
        session.client != nil && settings.targetSpace(in: session.spaces) != nil
    }

    /// False when "Only While Charging" is on and the phone isn't. Background
    /// windows are booked to require power already; this is the same rule for
    /// a run started because the app was opened.
    private var allowedOnCurrentPower: Bool {
        guard settings.chargingOnly else { return true }
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        return device.batteryState == .charging || device.batteryState == .full
    }

    /// Puts back any row a run left marked as in flight.
    ///
    /// Only a lane marks a row `.uploading`, and only this process runs lanes,
    /// so when no run is going a row in that state belongs to one that never
    /// finished — the app was terminated mid-file, most often by iOS while it
    /// was in the background. Nothing ever looked at those rows again: the
    /// photograph was never retried, and sat in the queue as "uploading" for
    /// good. Back to pending now, with the attempt `claimNext` spent refunded,
    /// because being interrupted is not the photo's fault. The NAS kept every
    /// chunk it received, so the upload resumes rather than starting over.
    ///
    /// Callers must hold the run — `start()` after marking itself running, or
    /// `resume()` before calling it.
    private func reclaimInterrupted(_ context: ModelContext) {
        let uploading = BackupItem.State.uploading.rawValue
        let stranded = (try? context.fetch(FetchDescriptor<BackupItem>(
            predicate: #Predicate { $0.stateRaw == uploading }
        ))) ?? []
        guard !stranded.isEmpty else { return }
        for item in stranded {
            item.state = .pending
            item.attempts = max(item.attempts - 1, 0)
        }
        try? context.save()
    }

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

    /// What one queue row will send, as found in Photos.
    private enum Resolution {
        /// The photo, the file of it to send, and which version of the photo
        /// that file shows (see `queueEdits`) where that matters.
        case send(PHAsset, PHAssetResource?, shows: String?)
        /// Nothing to send, and there never will be. The reason is recorded on
        /// the row.
        case skip(String)
    }

    /// Finds the photo behind a queue row and the file of it to send.
    ///
    /// Static and nonisolated so it runs off the main actor. See `upload`.
    nonisolated private static func resolve(
        kind: BackupKey.Kind, photo: String
    ) -> Resolution {
        guard let asset = PhotoLibraryScanner.asset(for: photo) else {
            // Deleted from the library since the scan. Not an error, and not
            // retryable.
            return .skip("No longer in the photo library")
        }
        // Queued before shared albums were left out, or hidden since it was.
        guard PhotoLibraryScanner.isBackedUp(asset) else {
            return .skip(asset.isHidden ? "Hidden in Photos" : "In a shared album, not your library")
        }
        switch kind {
        case .main:
            // Read before the export rather than after it: an edit landing in
            // between then looks newer than what went, and is sent again —
            // where the NAS recognizes the bytes — instead of being missed.
            let resource = PhotoLibraryScanner.primaryResource(for: asset)
            return .send(
                asset, resource,
                shows: resource.map { PhotoLibraryScanner.versionKey(of: asset, sending: $0) }
            )
        case .pairedVideo:
            guard let paired = PhotoLibraryScanner.livePhotoResource(for: asset) else {
                // The Live Photo lost its motion since the scan — usually
                // "Convert to Still" in Photos.
                return .skip("No longer a Live Photo")
            }
            return .send(asset, paired, shows: nil)
        case .edit:
            guard let render = PhotoLibraryScanner.editedResource(for: asset) else {
                // Reverted in Photos before it went. The photo is on the NAS as
                // it was; there is nothing else to send.
                return .skip("The edit was undone before it was backed up")
            }
            return .send(asset, render, shows: nil)
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
        // The row is already `.uploading` — `claimNext` marked it so no other
        // lane could take it. Here we only show it and send it.
        statusText = "Backing up \(item.filename)"
        setActive(ActiveUpload(
            localIdentifier: item.localIdentifier, filename: item.filename,
            byteSize: item.byteSize, sentBytes: 0, isPreparing: true
        ))
        defer { clearActive(item.localIdentifier) }

        // One photo can be several rows — a Live Photo's video half, each later
        // edit — because the queue keys on a unique identifier and every file
        // needs one. Photos only knows the asset by its real id. See `BackupKey`.
        let kind = BackupKey.kind(item.localIdentifier)
        let assetIdentifier = BackupKey.photo(item.localIdentifier)

        // Off the main actor, for the reason `enqueueNewAssets` gives: finding
        // which file to send makes Photos load its details on demand.
        let asset: PHAsset
        // Resolved now rather than at scan time: a `PHAssetResource` is a
        // handle into the library, not something a queue row can hold across a
        // relaunch.
        let resource: PHAssetResource?
        // Which version the photo's own upload shows, kept once it has gone so
        // that a later edit can be told from it. See `queueEdits`.
        let shows: String?
        switch await Task.detached(priority: .userInitiated, operation: {
            Self.resolve(kind: kind, photo: assetIdentifier)
        }).value {
        case .send(let found, let file, let version):
            asset = found
            resource = file
            shows = version
        case .skip(let reason):
            item.state = .skipped
            item.lastError = reason
            try? context.save()
            return nil
        }

        do {
            let localIdentifier = item.localIdentifier
            let result = try await AssetUploader.send(
                asset, descriptor: item.descriptor, to: spaceID, client: client,
                resource: resource, isAutomaticBackup: true,
                // Asked before every chunk, so a file that is part-way up when
                // the phone leaves the house stops there rather than finishing
                // over cellular — or when backup is switched off, or the phone
                // comes off its charger under "Only While Charging". `drainLane`
                // re-checks the same gates between items; this is the same
                // question asked often enough to matter on a video.
                //
                // Unwrapped before the hop, not optional-chained across it.
                // `self?.x` inside the `MainActor.run` closure reads the
                // captured weak *variable* from concurrently-executing code,
                // which Swift 6 rejects — the same thing `ConnectionMonitor`
                // and the phase handler below both had to be written around.
                shouldContinue: { [weak self] in
                    guard let self else { return false }
                    return await MainActor.run { self.maySend }
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
            if let shows { item.sentVersion = shows }
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
            // Holds the tile until the grid has the server's copy — see
            // `PendingUploads.Landed`. Recorded before `drainLane` rebuilds
            // `queued` without this row, so there is no moment with neither.
            //
            // Never for a Live Photo's video half. It had no tile on the way up
            // (see `refreshProgress`), and the timeline never shows it as a
            // photograph of its own, so there is no server copy to swap it
            // for — it would stand beside its still as a stray extra tile until
            // the grace period let it go.
            if result.addedToSpace, kind != .pairedVideo {
                session.pendingUploads.noteLanded(
                    item.localIdentifier, capturedAt: item.capturedAt ?? Date(),
                    spaceID: spaceID
                )
            }
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
            // Wi-Fi went away mid-file, or backup was switched off, or the phone
            // came off its charger. Put the row back exactly as it was found —
            // including the attempt `claimNext` spent on it, because none of
            // that is the item's fault and three of these would otherwise
            // retire a perfectly good photo. `drainLane`'s own check stops the
            // lane on the next turn of the loop.
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

    /// Counts and the head of the queue, from the store.
    ///
    /// Counts come from `fetchCount`, which never builds objects. The outstanding
    /// rows used to be loaded whole after every file, to sum their sizes and
    /// show the first five hundred, so the work per file grew with the backlog:
    /// on a first backup of thousands, each file cost more than the one before.
    /// Now only the head is loaded, and the sizes only when `recountBytes`
    /// asks for them; after a single file `noteFinished` subtracts instead.
    private func refreshProgress(_ context: ModelContext, recountBytes: Bool = true) {
        func count(_ predicate: Predicate<BackupItem>) -> Int {
            (try? context.fetchCount(FetchDescriptor<BackupItem>(predicate: predicate))) ?? 0
        }
        func count(_ state: BackupItem.State) -> Int {
            let raw = state.rawValue
            return count(#Predicate { $0.stateRaw == raw })
        }

        var next = BackupProgress()
        next.done = count(.done)
        next.failed = count(.failed)
        next.skipped = count(.skipped)
        next.held = count(.held)

        let pending = BackupItem.State.pending.rawValue
        let uploading = BackupItem.State.uploading.rawValue
        let outstanding = #Predicate<BackupItem> {
            $0.stateRaw == pending || $0.stateRaw == uploading
        }
        next.pending = count(outstanding)

        if recountBytes {
            var sizes = FetchDescriptor<BackupItem>(predicate: outstanding)
            sizes.propertiesToFetch = [\.byteSize]
            next.bytesRemaining = ((try? context.fetch(sizes)) ?? []).reduce(0) { $0 + $1.byteSize }
        } else {
            next.bytesRemaining = progress.bytesRemaining
        }

        // The grid only shows the head of the queue; a thousand-item backlog
        // doesn't need a thousand tiles laid out at once.
        //
        // Not a Live Photo's video half: it plays inside the still rather than
        // having a tile of its own, and there is no picture of it to draw — it
        // held a gray square in the grid until it went. Fetched with room to
        // spare for those, so the head still comes to five hundred.
        var head = FetchDescriptor<BackupItem>(
            predicate: outstanding, sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        head.fetchLimit = 600
        let rows = (try? context.fetch(head)) ?? []
        queued = Array(rows.lazy.filter {
            BackupKey.kind($0.localIdentifier) != .pairedVideo
        }.prefix(500).map {
            ($0.localIdentifier, $0.capturedAt ?? Date(),
             $0.state == .uploading ? .uploading : .pending)
        })

        progress = next
    }

    /// Brings the progress up to date after one file, without reading every
    /// waiting row again: the file's size comes off the total if it is no
    /// longer waiting. The total is recounted in full when a run ends.
    private func noteFinished(_ item: BackupItem, claimedBytes: Int64, context: ModelContext) {
        if item.state != .pending, item.state != .uploading {
            progress.bytesRemaining = max(progress.bytesRemaining - claimedBytes, 0)
        }
        refreshProgress(context, recountBytes: false)
    }

    /// Holds what the settings now leave out, and lets go of what they let back
    /// in. See `BackupScope`.
    ///
    /// Run when a setting changes, after a scan, and when a run starts, so
    /// nothing is sent under a setting that says not to: switching "Photos
    /// Only" on halfway through a backup used to leave every video already
    /// queued to go anyway. Held rather than removed, so switching it off again
    /// sends them after all.
    private func reconcileHolds(_ context: ModelContext? = nil) {
        let context = context ?? ModelContext(container)
        let scope = settings.scope
        let pending = BackupItem.State.pending.rawValue
        let failed = BackupItem.State.failed.rawValue
        let held = BackupItem.State.held.rawValue
        let rows = (try? context.fetch(FetchDescriptor<BackupItem>(
            predicate: #Predicate {
                $0.stateRaw == pending || $0.stateRaw == failed || $0.stateRaw == held
            }
        ))) ?? []
        var changed = false
        for row in rows {
            let wanted = scope.includes(
                isVideo: row.mediaTypeRaw == MediaType.video.rawValue,
                takenAt: row.capturedAt,
                isEdit: BackupKey.kind(row.localIdentifier) == .edit
            )
            if wanted, row.state == .held {
                row.state = .pending
                changed = true
            } else if !wanted, row.state != .held {
                row.state = .held
                changed = true
            }
        }
        guard changed else { return }
        try? context.save()
        refreshProgress(context)
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
