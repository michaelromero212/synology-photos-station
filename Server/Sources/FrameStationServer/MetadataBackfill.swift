import Foundation
import SQLKit
import Vapor

/// Fills in dates and the screenshot kind for assets already in the library,
/// from their filenames — so nothing has to be re-uploaded to gain the
/// metadata the app learned to read after it was stored.
///
/// Runs once at startup, over only the assets that are still missing a capture
/// date. Anything whose name yields no date is left alone and re-examined on
/// the next boot, which is a cheap read and no write. New uploads get their
/// date from the file's own creation date at commit and never reach here.
enum MetadataBackfill {
    private struct Row: Decodable {
        let id: UUID
        let filename: String?
        let mediaSubtypes: [String]
    }

    static func run(on app: Application) async {
        let sql = app.sql
        do {
            // Only the dateless, and only enough per pass to keep startup brisk
            // on a large library — the rest come on the next boot.
            let rows = try await sql.raw("""
                SELECT a.id,
                       (SELECT sa.filename FROM space_assets sa
                        WHERE sa.asset_id = a.id AND sa.filename IS NOT NULL
                        LIMIT 1) AS filename,
                       a.media_subtypes AS "mediaSubtypes"
                FROM assets a
                -- Missing a date, or carrying a non-zero offset a filename date
                -- must not keep. The second half re-corrects rows an earlier
                -- version mis-dated: it stored the filename wall clock but kept
                -- a stale offset from the upload, so a 3:45 AM screenshot showed
                -- 11:45 PM the day before and sorted into the wrong day.
                WHERE (a.captured_at IS NULL OR a.captured_tz_off IS DISTINCT FROM 0)
                LIMIT 2000
                """).all(decoding: Row.self)

            var dated = 0
            var flagged = 0
            for row in rows {
                guard let filename = row.filename else { continue }

                // A filename time is a bare wall clock with no zone, so it is
                // stored at a *zero* offset — never a COALESCE that would keep a
                // stale one — and `local_captured_at` is the same wall clock.
                // Display and sort then both read the time written in the name.
                //
                // Overwrites unconditionally: a file whose name carries a date
                // has no better source (a screenshot has no EXIF), and a camera
                // file, whose name carries none, never reaches this branch — so
                // this never overrides a real EXIF or device date.
                if let date = FilenameMetadata.captureDate(from: filename) {
                    try await sql.raw("""
                        UPDATE assets
                        SET captured_at = \(bind: date),
                            captured_tz_off = 0,
                            local_captured_at = \(bind: date) AT TIME ZONE 'UTC'
                        WHERE id = \(bind: row.id)
                        """).run()
                    dated += 1
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

            if dated > 0 || flagged > 0 {
                app.logger.info(
                    "metadata backfill: dated \(dated), flagged \(flagged) screenshot(s) from filenames"
                )
            }
        } catch {
            app.logger.error("metadata backfill failed: \(String(reflecting: error))")
        }
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
    /// grey. `thumb_version < current` is a row whose thumbnails were built with
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
                       OR a.thumb_version < \(bind: Derivatives.thumbnailVersion)
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
