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

    private func sweep() async {
        let sql = app.sql
        do {
            let expired = try await sql.raw("""
                SELECT sa.id, a.sha256, a.blob_ext AS "blobExt"
                FROM space_assets sa
                JOIN assets a ON a.id = sa.asset_id
                WHERE sa.deleted_at IS NOT NULL
                  AND sa.purged_at IS NULL
                  AND sa.deleted_at < now() - \(unsafeRaw: Retention.interval)
                ORDER BY sa.deleted_at
                LIMIT 200
                """).all(decoding: Expired.self)

            for row in expired { await purge(row, on: sql) }

            if !expired.isEmpty {
                app.logger.info("retention: purged \(expired.count) expired removals")
            }
        } catch {
            app.logger.error("retention sweep failed: \(String(reflecting: error))")
        }
    }

    /// Marks the row purged, and removes the bytes if nothing else wants them.
    ///
    /// The order matters and is deliberate. The row is marked first, so a
    /// failure to unlink cannot leave an item that has passed its window sitting
    /// in Recently Deleted forever, offering a restore whose file may be half
    /// gone. Leaving bytes behind wastes space; leaving the row behind lies to
    /// the user, and of the two that is the one worth avoiding.
    private func purge(_ row: Expired, on sql: any SQLDatabase) async {
        do {
            try await sql.raw("""
                UPDATE space_assets SET purged_at = now() WHERE id = \(bind: row.id)
                """).run()
        } catch {
            app.logger.error("retention: could not mark \(row.id) purged: \(error)")
            return
        }

        // Blobs are content-addressed and `assets.sha256` is *not* unique —
        // sharing a photograph into a space makes a second asset row over the
        // same bytes. So the bytes may not be this row's to remove: unlinking
        // them because one copy expired would blank the photograph everywhere
        // else it still legitimately lives.
        do {
            struct Holder: Decodable { let count: Int }
            let holders = try await sql.raw("""
                SELECT count(*) AS count
                FROM space_assets sa
                JOIN assets a ON a.id = sa.asset_id
                WHERE a.sha256 = \(bind: row.sha256)
                  AND (sa.deleted_at IS NULL OR sa.purged_at IS NULL)
                """).first(decoding: Holder.self)

            guard (holders?.count ?? 1) == 0 else { return }
        } catch {
            // Couldn't establish that the bytes are unwanted, so leave them.
            // A retained blob is recoverable; a wrongly deleted one is not.
            app.logger.error("retention: could not check holders for \(row.sha256): \(error)")
            return
        }

        let fm = FileManager.default
        let blob = app.blobStore.blobPath(sha256: row.sha256, fileExtension: row.blobExt)
        try? fm.removeItem(at: blob)
        // Thumbnails, preview, poster and HLS all live under one directory per
        // blob, so the derivatives go with it rather than being enumerated.
        try? fm.removeItem(at: app.blobStore.derivativeDirectory(sha256: row.sha256))
    }
}

struct RetentionWorkerKey: StorageKey {
    typealias Value = RetentionWorker
}
