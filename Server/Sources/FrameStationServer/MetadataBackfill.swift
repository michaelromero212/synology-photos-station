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
}
