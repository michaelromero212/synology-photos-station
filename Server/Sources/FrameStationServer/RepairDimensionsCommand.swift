import FrameStationAPI
import Foundation
import SQLKit
import Vapor

/// `FrameStationServer repair-dimensions` — turns back photos whose size was
/// recorded a quarter turn out.
///
/// Stored width and height are the file's pixels, and the orientation says how
/// to turn them — see `ExifOrientation`. A photo backed up from a phone used to
/// be recorded with PhotoKit's upright size beside the file's orientation, so
/// every portrait iPhone photo reported itself landscape: 4032 × 3024 in the
/// Information panel, a wide tile in the justified grid on the Mac and the
/// television. Uploads now reconcile the two (`DerivationWorker.applyMetadata`);
/// this puts right the photos recorded before they did.
///
/// Only a photo that carries a quarter turn can be wrong this way, so only
/// those are read. Each file's own size is read with exiftool, and a record
/// that disagrees with it about which side is the long one is turned — the rule
/// uploads follow now. The files are only read, never written. Each corrected
/// photo is announced in every library it is in, so an app that keeps the
/// timeline on the device redraws it rather than holding the old shape.
///
/// Running it twice is harmless: the second run finds nothing to change.
struct RepairDimensionsCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Flag(name: "dry-run", help: "Report what would change without writing anything")
        var dryRun: Bool

        @Option(name: "batch", short: "b", help: "Files per exiftool invocation (default 64)")
        var batch: Int?
    }

    var help: String { "Correct photos whose size was recorded a quarter turn out." }

    private struct Row: Decodable {
        let id: UUID
        let sha256: String
        let blobExt: String
        let storagePath: String?
        let width: Int?
        let height: Int?
    }

    private struct Correction {
        let assetID: UUID
        let width: Int
        let height: Int
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let console = context.console
        let batchSize = max(1, signature.batch ?? 64)

        let rows = try await app.sql.raw("""
            SELECT id, sha256, blob_ext AS "blobExt", storage_path AS "storagePath",
                   width, height
            FROM assets
            WHERE media_type = 'photo' AND orientation BETWEEN 5 AND 8
            ORDER BY id
            """).all(decoding: Row.self)

        guard !rows.isEmpty else {
            console.info("No photos carry a quarter turn, so none can be recorded the wrong way round.")
            return
        }
        console.info("Checking \(rows.count) \(rows.count == 1 ? "photo" : "photos") with a quarter turn…")
        if signature.dryRun { console.info("(dry run — nothing will be written)") }

        var turned = 0, alreadyRight = 0, missing = 0, unreadable = 0
        for start in stride(from: 0, to: rows.count, by: batchSize) {
            let chunk = rows[start..<min(start + batchSize, rows.count)]

            // Where each file is: the library copy when there is one, the blob
            // otherwise — the order `AssetController` serves them in. A file
            // that isn't there is left out of the batch rather than handed to
            // exiftool, which fails the whole invocation over one bad path.
            var files: [UUID: URL] = [:]
            for row in chunk {
                let url: URL
                if let path = row.storagePath, FileManager.default.fileExists(atPath: path) {
                    url = URL(fileURLWithPath: path)
                } else {
                    url = app.blobStore.blobPath(sha256: row.sha256, fileExtension: row.blobExt)
                }
                if FileManager.default.fileExists(atPath: url.path) {
                    files[row.id] = url
                } else {
                    missing += 1
                }
            }

            let probed = try await MediaProbe.probePhotoBatch(Array(files.values))

            var corrections: [Correction] = []
            for row in chunk {
                guard let url = files[row.id] else { continue }
                guard let file = probed[url.path], file.width != nil, file.height != nil else {
                    unreadable += 1
                    continue
                }
                let size = ExifOrientation.fileOrientedSize(
                    recorded: (row.width, row.height), file: (file.width, file.height)
                )
                guard let width = size.width, let height = size.height,
                      width != row.width || height != row.height
                else {
                    alreadyRight += 1
                    continue
                }
                corrections.append(Correction(assetID: row.id, width: width, height: height))
            }
            turned += corrections.count

            if !signature.dryRun, !corrections.isEmpty {
                // An immutable copy for the transaction to capture — a `var`
                // across that boundary is an error under Swift 6.
                let batch = corrections
                try await app.withPinnedConnection { sql in
                    try await sql.raw("BEGIN").run()
                    do {
                        for correction in batch {
                            try await sql.raw("""
                                UPDATE assets
                                SET width = \(bind: correction.width),
                                    height = \(bind: correction.height)
                                WHERE id = \(bind: correction.assetID)
                                """).run()

                            // Per library, and by placement: `/changes` is
                            // scoped per space and hydrates placements — see
                            // `DerivationWorker.SpacePlacement`.
                            let placements = try await sql.raw("""
                                SELECT id, space_id AS "spaceID" FROM space_assets
                                WHERE asset_id = \(bind: correction.assetID)
                                  AND deleted_at IS NULL
                                """).all(decoding: DerivationWorker.SpacePlacement.self)
                            for placement in placements {
                                _ = try await ChangeLog.append(
                                    spaceID: placement.spaceID, entity: "space_asset",
                                    entityID: placement.id, op: "update", on: sql
                                )
                            }
                        }
                        try await sql.raw("COMMIT").run()
                    } catch {
                        try? await sql.raw("ROLLBACK").run()
                        throw error
                    }
                }
            }
            console.info("  \(min(start + batchSize, rows.count))/\(rows.count)")
        }

        func line(_ label: String, _ count: Int) -> String {
            let name = label + ":"
            return "  " + name + String(repeating: " ", count: max(1, 16 - name.count)) + "\(count)"
        }
        console.info("")
        console.info(line(signature.dryRun ? "Would turn" : "Turned", turned))
        console.info(line("Already right", alreadyRight))
        if missing > 0 { console.info(line("File missing", missing)) }
        if unreadable > 0 { console.info(line("No size read", unreadable)) }
    }
}
