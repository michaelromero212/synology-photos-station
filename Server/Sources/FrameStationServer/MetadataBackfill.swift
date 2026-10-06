import Foundation
import SQLKit
import Vapor

/// Fills in dates and the screenshot kind for assets already in the library,
/// from their filenames — so nothing has to be re-uploaded to gain the
/// metadata the app learned to read after it was stored.
///
/// Runs once at startup and makes one complete pass over the assets that could
/// still gain something: undated, or dated by an earlier version that kept a
/// stale offset, and with a name that could carry a date or says screenshot.
/// New uploads get their date from the file's own creation date at commit and
/// never need it.
enum MetadataBackfill {
    private struct Row: Decodable {
        let id: UUID
        let filename: String?
        let mediaSubtypes: [String]
        /// No trustworthy date on record: none at all, or one with an offset
        /// on a file that has no camera data to have taken it from.
        let needsDate: Bool
    }

    /// Candidates per page. The pass pages through all of them, in id order.
    private static let pageSize = 500

    static func run(on app: Application) async {
        var dated = 0
        var flagged = 0
        // Keyset paging, so one boot reaches every candidate.
        //
        // This used to take the first 2,000 rows matching a clause that also
        // matched every iPhone photo — `IMG_4821.HEIC` has a timezone offset
        // and no date in its name — and it never marked progress. Rows it
        // could do nothing with never left the result, so on a real library
        // every boot examined the same 2,000 undatable photos and never reached
        // the screenshots it exists for. Filtering on names that could carry a
        // date keeps those out, and paging past each row keeps the pass moving
        // even over the few whose names still don't parse.
        var after = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        do {
            while true {
                // Driven from the placements, where the names are: one pass
                // over their filenames per page rather than a lookup per asset.
                let rows = try await app.sql.raw("""
                    SELECT DISTINCT ON (a.id)
                           a.id, sa.filename, a.media_subtypes AS "mediaSubtypes",
                           (a.captured_at IS NULL
                            OR (a.captured_tz_off IS DISTINCT FROM 0 AND a.camera_make IS NULL))
                               AS "needsDate"
                    FROM space_assets sa
                    JOIN assets a ON a.id = sa.asset_id
                    WHERE a.id > \(bind: after)
                      AND sa.filename IS NOT NULL
                      AND (
                          -- A date the name could supply: eight digits, dashed
                          -- or not, which every shape FilenameMetadata reads
                          -- contains and `IMG_4821` does not.
                          ((a.captured_at IS NULL
                            OR (a.captured_tz_off IS DISTINCT FROM 0 AND a.camera_make IS NULL))
                           AND sa.filename ~ '[0-9]{4}-?[0-9]{2}-?[0-9]{2}')
                          -- Or a screenshot not yet marked as one.
                          OR (lower(sa.filename) ~ '^(simulator )?screenshot'
                              AND NOT ('screenshot' = ANY(a.media_subtypes)))
                      )
                    ORDER BY a.id, sa.id
                    LIMIT \(bind: pageSize)
                    """).all(decoding: Row.self)
                guard let last = rows.last else { break }
                after = last.id

                let page = try await app.withPinnedConnection { sql in
                    try await apply(rows, on: sql)
                }
                dated += page.dated
                flagged += page.flagged
                if rows.count < pageSize { break }
            }
        } catch {
            app.logger.error("metadata backfill failed: \(String(reflecting: error))")
        }

        if dated > 0 || flagged > 0 {
            app.logger.info(
                "metadata backfill: dated \(dated), flagged \(flagged) screenshot(s) from filenames"
            )
        }
    }

    /// One page, in one transaction with its announcements.
    private static func apply(
        _ rows: [Row], on sql: any SQLDatabase
    ) async throws -> (dated: Int, flagged: Int) {
        var dated = 0
        var flagged = 0
        try await sql.raw("BEGIN").run()
        do {
            for row in rows {
                guard let filename = row.filename else { continue }

                // A filename time is a bare wall clock with no zone, so it is
                // stored at a *zero* offset — never a COALESCE that would keep a
                // stale one — and `local_captured_at` is the same wall clock.
                // Display and sort then both read the time written in the name.
                //
                // Only where there is no better source. A screenshot has no
                // EXIF; a camera file does, and one whose name happens to carry
                // a date too — `PXL_20260902_193249.jpg` — keeps the offset its
                // camera recorded rather than trading it for zero.
                if row.needsDate, let date = FilenameMetadata.captureDate(from: filename) {
                    struct Changed: Decodable { let id: UUID }
                    let changed = try await sql.raw("""
                        UPDATE assets
                        SET captured_at = \(bind: date),
                            captured_tz_off = 0,
                            local_captured_at = \(bind: date) AT TIME ZONE 'UTC'
                        WHERE id = \(bind: row.id)
                          AND (captured_at IS DISTINCT FROM \(bind: date)
                               OR captured_tz_off IS DISTINCT FROM 0)
                        RETURNING id
                        """).all(decoding: Changed.self)

                    // A new date can mean a new day, and every device showing
                    // the old one has to be told — the same announcement a
                    // date edited in the app makes. Without it the photo stayed
                    // on its old day everywhere until that day was refetched.
                    if !changed.isEmpty {
                        dated += 1
                        let placements = try await sql.raw("""
                            SELECT id, space_id AS "spaceID" FROM space_assets
                            WHERE asset_id = \(bind: row.id) AND deleted_at IS NULL
                            """).all(decoding: DerivationWorker.SpacePlacement.self)
                        for placement in placements {
                            _ = try await ChangeLog.append(
                                spaceID: placement.spaceID, entity: "space_asset",
                                entityID: placement.id, op: "update", on: sql
                            )
                        }
                    }
                }

                // The kind, from the same name: a screenshot with no recorded
                // subtype (a Mac upload has none — no PhotoKit to ask) gets one
                // so the Information panel can say "Screenshot".
                if FilenameMetadata.isScreenshot(filename),
                   !row.mediaSubtypes.contains("screenshot") {
                    try await sql.raw("""
                        UPDATE assets
                        SET media_subtypes = array_append(media_subtypes, 'screenshot')
                        WHERE id = \(bind: row.id)
                          AND NOT ('screenshot' = ANY(media_subtypes))
                        """).run()
                    flagged += 1
                }
            }
            try await sql.raw("COMMIT").run()
        } catch {
            try? await sql.raw("ROLLBACK").run()
            throw error
        }
        return (dated, flagged)
    }

    /// Re-probes already-stored assets for the full metadata dump.
    ///
    /// The `exif` column existed from the first migration but was never filled;
    /// the file's own bytes are the only source, and they are already on the
    /// NAS — so nothing is re-uploaded. This just re-pends the `metadata`
    /// derivation job, which reads the stored blob and now captures the dump
    /// alongside the curated columns. `applyMetadata` COALESCEs those columns,
    /// so re-running never disturbs a corrected capture date.
    ///
    /// Re-pending (not insert-if-absent) is the point: every existing asset
    /// already has a `done` metadata job from its upload, so a plain insert
    /// would conflict and skip it, and the column would stay null forever.
    ///
    /// Bounded per boot. `applyMetadata` writes at least `'[]'`, so an asset it
    /// has processed is no longer null and drops out of the next pass — the
    /// backlog drains over successive restarts without ever flooding the queue.
    static func enqueueMissingExif(on app: Application) async {
        do {
            try await app.sql.raw("""
                WITH todo AS (
                    SELECT id FROM assets WHERE exif IS NULL LIMIT 5000
                )
                INSERT INTO derivation_jobs (asset_id, kind)
                SELECT id, 'metadata' FROM todo
                ON CONFLICT (asset_id, kind)
                DO UPDATE SET state = 'pending', attempts = 0, last_error = NULL
                """).run()

            struct CountRow: Decodable { let remaining: Int }
            if let row = try await app.sql.raw("""
                SELECT count(*)::int AS remaining FROM assets WHERE exif IS NULL
                """).first(decoding: CountRow.self), row.remaining > 0 {
                app.logger.info("metadata dump backfill: \(row.remaining) asset(s) still to probe")
            }
        } catch {
            app.logger.error("metadata dump backfill failed: \(String(reflecting: error))")
        }
    }

    /// Enqueues thumbnails for live assets that need (re)generating.
    ///
    /// Two cases. `derived_at IS NULL` is a row that reached a live placement
    /// without derivatives at all — chiefly the dedup/purge bug, where a
    /// re-upload of purged content was treated as "already derived" and stayed
    /// gray. `thumb_version < current` is a row whose thumbnails were built with
    /// an older *sizing* — the long-edge fit that left odd-aspect images blurry
    /// on the square grid — and wants rebuilding with the current short-edge
    /// sizing. Either way this re-pends any stale job or creates a fresh one.
    ///
    /// Only live placements, so purged/deleted rows aren't dragged back onto the
    /// queue. Bounded per boot; a rebuilt thumbnail stamps the current version,
    /// so a healed asset drops out of the next pass and the regeneration doesn't
    /// repeat every restart.
    static func enqueueMissingThumbnails(on app: Application) async {
        do {
            try await app.sql.raw("""
                WITH todo AS (
                    SELECT DISTINCT a.id
                    FROM assets a
                    JOIN space_assets sa ON sa.asset_id = a.id AND sa.deleted_at IS NULL
                    WHERE a.derived_at IS NULL
                       -- Videos have their own version, so a change to how
                       -- posters are picked rebuilds only the videos.
                       OR (a.media_type = 'video'
                           AND a.thumb_version < \(bind: Derivatives.videoThumbnailVersion))
                       OR (a.media_type <> 'video'
                           AND a.thumb_version < \(bind: Derivatives.thumbnailVersion))
                    LIMIT 5000
                )
                INSERT INTO derivation_jobs (asset_id, kind)
                SELECT id, 'thumbnails' FROM todo
                ON CONFLICT (asset_id, kind)
                DO UPDATE SET state = 'pending', attempts = 0, last_error = NULL
                """).run()
        } catch {
            app.logger.error("thumbnail heal failed: \(String(reflecting: error))")
        }
    }

    /// Re-queues a rendition whose file is no longer on disk.
    ///
    /// A finished job says the work was done, not that the result survived — a
    /// file can be deleted, or thrown away by the generator itself for being
    /// unplayable. Without this the job stays `done` for ever and the server
    /// quietly falls back to the 51 Mbps original on every cellular play, which
    /// is exactly the thing the rendition exists to avoid.
    ///
    /// Bounded, and a `stat` each: cheap for a handful, and it stops long before
    /// it could matter on a migrated library.
    static func requeueVanishedPlaybackRenditions(on app: Application) async {
        struct Row: Decodable {
            let id: UUID
            let sha256: String
        }
        do {
            let rows = try await app.sql.raw("""
                SELECT a.id, a.sha256
                FROM assets a
                JOIN derivation_jobs j ON j.asset_id = a.id
                WHERE a.media_type = 'video'
                  AND j.kind = \(bind: Derivatives.playbackJobKind)
                  AND j.state = 'done'
                LIMIT 500
                """).all(decoding: Row.self)

            for row in rows {
                let file = app.blobStore
                    .derivativeDirectory(sha256: row.sha256)
                    .appendingPathComponent(Derivatives.playbackName)
                guard !FileManager.default.fileExists(atPath: file.path) else { continue }
                app.logger.info(
                    "playback rendition for \(row.sha256.prefix(8)) is gone; re-queuing"
                )
                try await app.sql.raw("""
                    UPDATE derivation_jobs
                    SET state = 'pending', attempts = 0, last_error = NULL
                    WHERE asset_id = \(bind: row.id)
                      AND kind = \(bind: Derivatives.playbackJobKind)
                    """).run()
            }
        } catch {
            app.logger.error("playback rendition re-queue failed: \(String(reflecting: error))")
        }
    }

    /// Queues the cellular rendition for videos uploaded before it existed.
    ///
    /// Filtered in SQL to fat clips only, so the library's already-lean videos
    /// never reach the worker: the job would no-op on them anyway, but on a
    /// migrated library that is thousands of rows of pointless queue churn.
    /// Duration is required — a row without it has no bitrate to judge, and the
    /// worker will make that call for itself.
    ///
    /// Idempotent by the same `ON CONFLICT` as the thumbnail heal, and bounded,
    /// so a big library trickles through restarts rather than trying to
    /// transcode itself in one sitting.
    static func enqueueMissingPlaybackRenditions(on app: Application) async {
        do {
            try await app.sql.raw("""
                WITH todo AS (
                    SELECT DISTINCT a.id
                    FROM assets a
                    JOIN space_assets sa ON sa.asset_id = a.id AND sa.deleted_at IS NULL
                    WHERE a.media_type = 'video'
                      AND a.duration_ms > 0
                      AND (a.byte_size * 8000 / a.duration_ms)
                          >= \(bind: Derivatives.playbackBitrateThreshold)
                    LIMIT 500
                )
                INSERT INTO derivation_jobs (asset_id, kind)
                SELECT id, \(bind: Derivatives.playbackJobKind) FROM todo
                -- Retries a *failed* rendition, and only a failed one. The
                -- worker gives up after three attempts, so without this a job
                -- that died for a reason since fixed — a bad ffmpeg argument,
                -- say — stays dead forever and the only cure is editing the
                -- table by hand. Restricted to 'failed' because resetting a
                -- 'done' row would retranscode the whole library on every boot.
                ON CONFLICT (asset_id, kind) DO UPDATE
                  SET state = 'pending', attempts = 0, last_error = NULL
                  WHERE derivation_jobs.state = 'failed'
                """).run()
        } catch {
            app.logger.error("playback rendition heal failed: \(String(reflecting: error))")
        }
    }
}
