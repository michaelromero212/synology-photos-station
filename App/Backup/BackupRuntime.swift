#if os(iOS)
import Foundation
import SwiftData

/// The one backup engine this process has, whether the app is on screen or iOS
/// launched it in the background.
///
/// The engine used to be built by the tab view, so it existed only once the app
/// had drawn a screen. When iOS woke a closed app for a background window, or
/// for the NAS's nudge, it drew nothing: there was no engine, the wake-up did
/// nothing, and a window that found nothing never booked the next one. Backup
/// in the background stopped whenever iOS had quit the app, until someone
/// opened it. Built here, it's there for whichever needs it first, and the
/// screen adopts the same one — two engines on one queue would claim the same
/// photos twice.
@MainActor
final class BackupRuntime {
    static let shared = BackupRuntime()

    private(set) var engine: BackupEngine?
    private(set) var connection: ConnectionMonitor?

    /// What else a reconnect restarts, beyond backup. The screen sets it for
    /// curation, which runs only while the app is open.
    var onReconnect: (@MainActor () async -> Void)?

    private init() {}

    /// The engine for this session, built the first time anybody asks.
    func engine(session: AppSession, settings: BackupSettings) -> BackupEngine {
        if let engine { return engine }
        let container = BackupStore.container
        // Before anything reads the ledger: it may belong to whoever was signed
        // in last. See `BackupAccount.adopt`.
        if let userID = session.user?.id {
            BackupAccount.adopt(userID: userID, container: container)
        }
        // The monitor must not retain the session: it outlives any one use of
        // it, and the session is the app's for as long as the app runs.
        let monitor = ConnectionMonitor { [weak session] in session?.client }
        monitor.start()
        let created = BackupEngine(
            container: container, session: session, settings: settings, connection: monitor
        )
        // Picking up where the outage stopped it. Waiting for the next
        // background window instead would mean a phone that reconnects on the
        // sofa does nothing until iOS decides to wake us. `start()` checks the
        // settings itself, so this can't send with backup switched off.
        monitor.onReconnect = { [weak created, weak self] in
            await created?.start()
            await self?.onReconnect?()
        }
        // Before the first grid draws, and whether or not backup is on: this is
        // what lets a tile whose thumbnail the NAS hasn't made yet be drawn from
        // the copy still on the phone. See `LocalOriginals`.
        created.seedLocalOriginals()
        if settings.enabled { created.enableBackgroundRuns() }
        connection = monitor
        engine = created
        return created
    }

    /// Lets go of the engine when its account signs out, so whoever signs in
    /// next gets one built for their own ledger. Called before the session lets
    /// go of its connection; see `BackupEngine.retire`.
    func discard() {
        engine?.retire()
        engine = nil
        connection = nil
        onReconnect = nil
    }

    /// A wake-up from iOS or from the NAS. Answers whether anything moved.
    ///
    /// A closed app launched in the background has drawn nothing, so nothing
    /// has restored the sign-in either. The restore here is the same one
    /// launch runs, and the screen, if it appears later, finds it done.
    func wake() async -> Bool {
        let settings = BackupSettings.load()
        guard settings.enabled else { return false }
        let session = AppSession.shared
        if session.phase == .launching { _ = await session.restore() }
        guard session.phase == .connected else {
            Diagnostics.shared.log(.backup, "woken to back up, but not signed in")
            return false
        }
        return await engine(session: session, settings: settings).runInBackground()
    }
}

/// The durable backup queue, opened once for the whole process. On-disk because
/// the engine must survive being killed mid-run — see `BackupQueue`.
@MainActor
enum BackupStore {
    static let container: ModelContainer = {
        // SwiftData puts its store in Application Support, and iOS does not
        // create that directory for you — only `Library` itself. On a fresh
        // install the store therefore fails to open, CoreData dumps a few
        // hundred lines of filesystem diagnostics walking the tree looking for
        // somewhere writable, and *then* recovers by creating the directory it
        // needed all along. The store ends up fine; the log looks like the app
        // is broken. Creating it first skips the whole performance.
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            try? FileManager.default.createDirectory(
                at: support, withIntermediateDirectories: true
            )
        }
        do { return try ModelContainer(for: BackupItem.self, ManualUpload.self) }
        catch {
            // Degraded, never dead.
            //
            // This was a `fatalError`, which made an unopenable queue a phone
            // that cannot start its photo library at all — the one outcome
            // worse than losing the queue. A store can fail to open for
            // reasons that have nothing to do with the photographs: a disk
            // full at the wrong moment, a schema the app can't migrate, a file
            // left unreadable by a restore.
            //
            // An in-memory container keeps every other part of the app
            // working: browsing, uploading by hand, shared albums, playback.
            // Only the durable queue is lost, and it rebuilds itself from the
            // photo library on the next scan.
            Diagnostics.shared.log(
                .launch, "backup queue unavailable, running in memory: \(error)"
            )
            do {
                return try ModelContainer(
                    for: BackupItem.self, ManualUpload.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                )
            } catch {
                fatalError("Could not open even an in-memory queue: \(error)")
            }
        }
    }()
}
#endif
