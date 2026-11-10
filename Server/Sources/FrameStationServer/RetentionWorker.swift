import Foundation
import FrameStationAPI
import SQLKit
import Vapor

extension Retention {
    /// The window as a Postgres interval literal.
    ///
    /// Interpolated rather than bound — `$1 * interval '1 day'` binds fine but
    /// reads badly at every call site, and the value is an integer constant in
    /// the API package rather than anything reaching us from a request.
    static var interval: String { "interval '\(days) days'" }
}

/// Empties Recently Deleted on time.
///
/// Deletion is soft: the row keeps its `deleted_at` and the bytes stay in the
/// blob store, so a photograph can be put back for `Retention.days` days. This
/// is the other end of that promise. Without it, "Recently Deleted" is a room
/// with no exit — which is what it was until now, and the reason a library
/// would grow forever no matter how much you deleted from it.
///
/// Runs hourly rather than daily. The window is 29 days, so the hour something
/// is purged in is immaterial; what an hourly pass buys is that a server which
/// was asleep at midnight still catches up promptly instead of waiting a whole
/// day for the next tick.
///
/// Each pass then forgets what was seen in files people no longer hold
/// (`forget`), by their devices and by the NAS's analyzer, faces included, so
/// a photo deleted for good leaves nothing about itself behind.
actor RetentionWorker {
    private let app: Application
    private let interval: Duration
    private var task: Task<Void, Never>?

    init(app: Application, interval: Duration = .seconds(3600)) {
        self.app = app
        self.interval = interval
    }

    func start() {
        guard task == nil else { return }
        let every = interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sweep()
                try? await Task.sleep(for: every)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private struct Expired: Decodable {
        let id: UUID
        let sha256: String
        let blobExt: String
    }

    /// Purges everything past the window, a batch at a time, until nothing due
    /// is left.
    ///
    /// It used to take one batch of 200 an hour, which was plenty while things
    /// left a library a few at a time. A deleted account takes its whole
    /// library at once — tens of thousands of photos on this NAS — and 200 an
    /// hour would have kept them for weeks past the window the person was told.
    /// The cap only bounds a pass whose purges keep failing, so it can't spin.
    private func sweep() async {
        let sql = app.sql
        let batch = 200
        var purged = 0
        do {
            for _ in 0..<1_000 {
                let expired = try await sql.raw("""
                    SELECT sa.id, a.sha256, a.blob_ext AS "blobExt"
                    FROM space_assets sa
                    JOIN assets a ON a.id = sa.asset_id
                    WHERE sa.deleted_at IS NOT NULL
                      AND sa.purged_at IS NULL
                      AND sa.deleted_at < now() - \(unsafeRaw: Retention.interval)
                    ORDER BY sa.deleted_at
                    LIMIT \(bind: batch)
                    """).all(decoding: Expired.self)

                var marked = 0
                for row in expired {
                    let done = await Self.purge(
                        placementID: row.id, sha256: row.sha256, blobExt: row.blobExt,
                        on: sql, blobStore: app.blobStore, logger: app.logger
                    )
                    if done { marked += 1 }
                }
                purged += marked
                // Done, or stuck: rows the database won't mark come straight
                // back in the next batch, and the next hourly pass is the
                // place to try them again, not this loop.
                if expired.count < batch || marked == 0 { break }
            }

            if purged > 0 {
                app.logger.info("retention: purged \(purged) expired removals")
            }
        } catch {
            app.logger.error("retention sweep failed: \(String(reflecting: error))")
        }

        // After the purges, so what ran out its window in this pass is
        // forgotten in this pass too. Both run even when the purges failed,
        // since they only read what's already marked, and neither needs the
        // analyzer: it may be stopped, crashing or not set up at all.
        let nas = await forgetting(.nasAnalysis, on: sql)
        let devices = await forgetting(.deviceObservations, on: sql)
        if nas + devices > 0 {
            app.logger.info("retention: removed \(devices) device observations and \(nas) NAS analyses of files no longer in their libraries")
        }
    }

    /// `forget`, with a failure logged rather than thrown, so one kind failing
    /// doesn't keep the other from running. The next pass tries again.
    private func forgetting(_ what: Forgotten, on sql: any SQLDatabase) async -> Int {
        do {
            return try await Self.forget(what, on: sql)
        } catch is CancellationError {
            return 0
        } catch {
            app.logger.error("retention: forgetting \(what) failed: \(String(reflecting: error))")
            return 0
        }
    }

    /// What a pass forgets about files people no longer hold, and where a file
    /// has to be for it to stay.
    enum Forgotten: Sendable {
        /// What a person's devices saw (`media_observations`). It stays while
        /// any library the person is in holds the file, shared libraries and
        /// shared albums included, because covers there read the caller's own
        /// observations (`CollectionsController.observed(by:)`).
        case deviceObservations
        /// What the NAS's analyzer saw (`nas_analysis`, whose faces and scene
        /// labels go with it), and the names given to those faces. It stays
        /// while the person's own library holds the file, the only library
        /// the NAS analyzes.
        case nasAnalysis
    }

    /// Forgets `what` for every file its person no longer holds. Returns how
    /// many rows went.
    ///
    /// Both kinds are keyed by person and file hash, not by placement, so a
    /// permanent delete used to leave them behind. Device observations stayed
    /// for good: Vision's labels, the aesthetic score, the tags and the search
    /// terms of a photo that's gone. The NAS's analysis, sealed face
    /// templates included, was swept only while the analyzer was answering.
    /// Data that outlives what it describes is a leak waiting to happen. This
    /// takes it within the hour, however the file went: its 29 days ran out,
    /// someone chose Delete Permanently, or the person left the last library
    /// that held it.
    ///
    /// Held is matched by hash, since sharing a photo can make a second asset
    /// row over the same bytes. A photo in Recently Deleted still holds it, by
    /// the same test `purge` uses for the bytes, so a restore needs no new
    /// analysis.
    ///
    /// Paced for the J4125: a page of rows in key order, each judged by a
    /// probe of the indexes on hash and placement, then a pause twice as long
    /// as the page took, never under `breath`. The pass stays under a third
    /// of one core and slows itself down when the NAS is busy.
    static func forget(
        _ what: Forgotten,
        on sql: any SQLDatabase,
        pageSize: Int = 1_000,
        breath: Duration = .milliseconds(100)
    ) async throws -> Int {
        struct Page: Decodable {
            let lastUser: UUID
            let lastHash: String
            let scanned: Int
            let removed: Int
        }
        // Before every key: no id sorts below the nil UUID, and no hash below
        // the empty string.
        var afterUser = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        var afterHash = ""
        var removed = 0
        while true {
            try Task.checkCancellation()
            let started = ContinuousClock.now
            guard let page = try await sql.raw(
                Self.page(of: what, after: afterUser, afterHash, limit: pageSize)
            ).first(decoding: Page.self)
            else { return removed }

            removed += page.removed
            if page.scanned < pageSize { return removed }
            afterUser = page.lastUser
            afterHash = page.lastHash
            try await Task.sleep(for: max(breath, (ContinuousClock.now - started) * 2))
        }
    }

    /// One page of `forget`: the next rows after the given key, whether each
    /// is held, and the ones that aren't, deleted.
    ///
    /// Whether a row is held is worked out row by row, in the page's select
    /// list, so the plan is always a few index probes per row and never a scan
    /// of every placement in the house. What's spliced in is constant SQL,
    /// never input.
    private static func page(
        of what: Forgotten, after user: UUID, _ hash: String, limit: Int
    ) -> SQLQueryString {
        let table: String
        let scope: String
        let along: String
        switch what {
        case .deviceObservations:
            table = "media_observations"
            scope = ""
            along = ""
        case .nasAnalysis:
            // Its faces and scene labels go with the row, by cascade. The names
            // given to those faces are kept by file and place rather than by
            // face row, so that a name outlives a model upgrade, and go here.
            table = "nas_analysis"
            scope = "JOIN spaces s ON s.id = sa.space_id AND s.kind = 'personal'"
            along = """
                , names AS (
                    DELETE FROM person_faces pf
                    USING gone g
                    WHERE pf.user_id = g.user_id AND pf.sha256 = g.sha256
                )
                """
        }
        return """
            WITH page AS (
                SELECT o.user_id, o.sha256,
                       EXISTS (
                           SELECT 1 FROM assets a
                           JOIN space_assets sa ON sa.asset_id = a.id
                           \(unsafeRaw: scope)
                           JOIN space_members m
                             ON m.space_id = sa.space_id AND m.user_id = o.user_id
                           WHERE a.sha256 = o.sha256
                             AND (sa.deleted_at IS NULL OR sa.purged_at IS NULL)
                       ) AS held
                FROM \(unsafeRaw: table) o
                WHERE (o.user_id, o.sha256) > (\(bind: user), \(bind: hash))
                ORDER BY o.user_id, o.sha256
                LIMIT \(bind: limit)
            ), gone AS (
                DELETE FROM \(unsafeRaw: table) o
                USING page p
                WHERE o.user_id = p.user_id AND o.sha256 = p.sha256 AND NOT p.held
                RETURNING o.user_id, o.sha256
            )\(unsafeRaw: along), last AS (
                SELECT user_id, sha256 FROM page
                ORDER BY user_id DESC, sha256 DESC
                LIMIT 1
            )
            SELECT last.user_id AS "lastUser", last.sha256 AS "lastHash",
                   (SELECT count(*)::int FROM page) AS scanned,
                   (SELECT count(*)::int FROM gone) AS removed
            FROM last
            """
    }

    /// Marks one removed placement purged and removes its bytes if nothing else
    /// wants them. The permanent end of a deletion.
    ///
    /// Static and shared: the hourly sweep runs it on everything past the
    /// window, and the "Delete Permanently" endpoint runs it on the photographs
    /// someone chose not to wait for. One implementation so the two can never
    /// tear down differently.
    ///
    /// The order matters and is deliberate. The row is marked first, so a
    /// failure to unlink cannot leave a purged item still sitting in Recently
    /// Deleted, offering a restore whose file may be half gone. Leaving bytes
    /// behind wastes space; leaving the row behind lies to the user, and of the
    /// two that is the one worth avoiding.
    ///
    /// Returns whether the row was marked, which is what counts as purged:
    /// the bytes may rightly stay, for another library still holding them.
    @discardableResult
    static func purge(
        placementID: UUID,
        sha256: String,
        blobExt: String,
        on sql: any SQLDatabase,
        blobStore: BlobStore,
        logger: Logger
    ) async -> Bool {
        do {
            try await sql.raw("""
                UPDATE space_assets SET purged_at = now() WHERE id = \(bind: placementID)
                """).run()
        } catch {
            logger.error("purge: could not mark \(placementID) purged: \(error)")
            return false
        }

        // Blobs are content-addressed and `assets.sha256` is *not* unique —
        // sharing a photograph into a space makes a second asset row over the
        // same bytes. So the bytes may not be this row's to remove: unlinking
        // them because one copy went would blank the photograph everywhere else
        // it still legitimately lives.
        do {
            struct Holder: Decodable { let count: Int }
            let holders = try await sql.raw("""
                SELECT count(*) AS count
                FROM space_assets sa
                JOIN assets a ON a.id = sa.asset_id
                WHERE a.sha256 = \(bind: sha256)
                  AND (sa.deleted_at IS NULL OR sa.purged_at IS NULL)
                """).first(decoding: Holder.self)

            guard (holders?.count ?? 1) == 0 else { return true }
        } catch {
            // Couldn't establish that the bytes are unwanted, so leave them.
            // A retained blob is recoverable; a wrongly deleted one is not.
            logger.error("purge: could not check holders for \(sha256): \(error)")
            return true
        }

        let fm = FileManager.default
        try? fm.removeItem(at: blobStore.blobPath(sha256: sha256, fileExtension: blobExt))
        // Thumbnails, preview, poster and HLS all live under one directory per
        // blob, so the derivatives go with it rather than being enumerated.
        try? fm.removeItem(at: blobStore.derivativeDirectory(sha256: sha256))
        return true
    }
}

struct RetentionWorkerKey: StorageKey {
    typealias Value = RetentionWorker
}
