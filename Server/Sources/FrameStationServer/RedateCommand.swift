import Foundation
import SQLKit
import Vapor

/// `FrameStationServer redate` — puts each file of a Synology Photos library at
/// the time Synology Photos shows it, where the library's row for it holds
/// another: a row an import made before the import read dates the way Synology
/// does (the Shared Space's, 2026-10-06, kept every video's UTC stamp as local
/// time, four or five hours late), or a phone's own backup of a file whose time
/// was set in Synology. The rows are the ones `compare-dates` compares
/// (`CompareDatesCommand.held`), and each takes Synology's time in the
/// household's zone, as the import gives it (`ImportDating.synology`). Files
/// are never touched; one in the library layout moves to its new month's
/// folder, as a time edited in the app does.
///
/// A date is the row's, so a row another library shows too changes there as
/// well: it's left alone without `--with-other-libraries`. So is a row two of
/// Synology's files share at different times, which no one time can match.
struct RedateCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "path", short: "p", help: "The library's folder, spelled as for the import")
        var path: String?

        @Option(name: "space", short: "s", help: "The library whose rows to put right")
        var space: String?

        @Option(name: "synology", help: "Synology Photos' dates, from Scripts/export-synology-dates.sh")
        var synology: String?

        @Option(name: "time-zone", help: "As given to the import (default $FRAMESTATION_TIME_ZONE)")
        var timeZone: String?

        @Flag(name: "with-other-libraries", help: "Also change a row another library shows, there too")
        var withOtherLibraries: Bool

        @Flag(name: "dry-run", help: "Say what would change, and change nothing")
        var dryRun: Bool
    }

    var help: String { "Put a library's rows at the times Synology Photos shows its files." }

    private struct Row: Decodable {
        let path: String
        let assetID: UUID
        let local: String?
        /// Other libraries showing the row.
        let elsewhere: Int
        let origin: String
        let storagePath: String?
    }

    /// A row to put at Synology's time, and the files of Synology's it holds.
    private struct Change {
        let assetID: UUID
        let from: String?
        let to: Date
        let paths: [String]
        let origin: String
        let storagePath: String?
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let console = context.console
        guard let path = signature.path, let file = signature.synology,
              let spaceID = signature.space.flatMap(UUID.init(uuidString:)) else {
            throw Abort(.badRequest, reason: "--path, --space (a library's id) and --synology are required.")
        }
        var zone: TimeZone?
        if let name = signature.timeZone ?? Environment.get("FRAMESTATION_TIME_ZONE") {
            guard let named = TimeZone(identifier: name) else { throw ImportError.unknownTimeZone(name) }
            zone = named
        }
        let household = zone
        let root = path.hasSuffix("/") ? path : path + "/"
        let synology = try ImportDating.synologyDates(from: file).filter { $0.key.hasPrefix(root) }
        guard !synology.isEmpty else {
            throw Abort(.badRequest, reason: "\(file) has no dates for files under \(root).")
        }

        let rows = try await app.sql.raw("""
            \(CompareDatesCommand.held(under: root, in: spaceID))
            SELECT h.path AS "path", a.id AS "assetID",
                   to_char(a.local_captured_at, 'YYYY-MM-DD HH24:MI:SS') AS "local",
                   (SELECT count(*) FROM space_assets o
                    WHERE o.asset_id = a.id AND o.space_id <> \(bind: spaceID)
                      AND o.deleted_at IS NULL)::int AS "elsewhere",
                   CASE WHEN EXISTS (SELECT 1 FROM import_records r
                                     WHERE r.asset_id = a.id AND starts_with(r.source_path, \(bind: root)))
                            THEN 'imported from here'
                        WHEN EXISTS (SELECT 1 FROM import_records r WHERE r.asset_id = a.id)
                            THEN 'imported from elsewhere'
                        ELSE 'backed up from a phone' END AS "origin",
                   a.storage_path AS "storagePath"
            FROM held h JOIN assets a ON a.id = h.asset_id
            """).all(decoding: Row.self)

        // To the second, as compare-dates compares.
        func second(_ date: Date) -> Int { Int(date.timeIntervalSince1970.rounded(.down)) }
        var byRow: [UUID: [Row]] = [:]
        for row in rows where synology[row.path] != nil { byRow[row.assetID, default: []].append(row) }
        var same = 0
        var changes: [Change] = [], shared: [Change] = [], torn: [[String]] = []
        for (assetID, files) in byRow {
            let times = Set(files.compactMap { synology[$0.path] }.map(second))
            guard times.count == 1, let first = files.first, let to = synology[first.path] else {
                torn.append(files.map(\.path).sorted())
                continue
            }
            if let local = first.local, let ours = MediaProbe.parseDateAndZone(local)?.clock,
               second(ours) == second(to) {
                same += 1
                continue
            }
            let change = Change(assetID: assetID, from: first.local, to: to,
                                paths: files.map(\.path).sorted(), origin: first.origin,
                                storagePath: first.storagePath)
            if first.elsewhere > 0, !signature.withOtherLibraries { shared.append(change) } else { changes.append(change) }
        }
        changes.sort { $0.paths[0] < $1.paths[0] }
        shared.sort { $0.paths[0] < $1.paths[0] }

        console.info("")
        console.info("  Rows holding files Synology lists: \(byRow.count)")
        console.info("  At Synology's time already:        \(same)")
        console.info("  To put at Synology's time:         \(changes.count)")
        for (origin, count) in Dictionary(grouping: changes, by: \.origin).mapValues(\.count).sorted(by: { $0.key < $1.key }) {
            console.info("    \(origin): \(count)")
        }
        for change in changes.prefix(10) { console.info("      " + describe(change, under: root)) }
        if !shared.isEmpty {
            console.info("  Shown in another library too, left alone: \(shared.count)")
            for change in shared.prefix(10) { console.info("      " + describe(change, under: root)) }
            console.info("    (--with-other-libraries puts them right there as well)")
        }
        if !torn.isEmpty {
            console.info("  Held for files Synology shows at different times, left alone: \(torn.count)")
            for files in torn.sorted(by: { $0[0] < $1[0] }).prefix(10) {
                console.info("      " + files.map { String($0.dropFirst(root.count)) }.joined(separator: "  +  "))
            }
        }
        console.info("")
        guard !signature.dryRun else {
            console.info("Dry run — nothing changed.")
            return
        }
        guard !changes.isEmpty else {
            console.info("Nothing to change.")
            return
        }

        var changed = 0, moved = 0
        for start in stride(from: 0, to: changes.count, by: 100) {
            let batch = changes[start..<min(start + 100, changes.count)]
            let done: [(Change, ImportDating)] = try await app.withPinnedConnection { sql in
                try await sql.raw("BEGIN").run()
                do {
                    var done: [(Change, ImportDating)] = []
                    for change in batch {
                        let dating = ImportDating.synology(change.to, household: household)
                        // Only a row still at the time read: one edited since keeps its edit.
                        struct Changed: Decodable { let id: UUID }
                        let updated = try await sql.raw("""
                            UPDATE assets
                            SET captured_at = \(bind: dating.capturedAt),
                                captured_tz_off = \(bind: dating.zone),
                                tz_off_fallback = \(bind: dating.fallbackZone),
                                local_captured_at = \(bind: dating.local) AT TIME ZONE 'UTC'
                            WHERE id = \(bind: change.assetID)
                              AND to_char(local_captured_at, 'YYYY-MM-DD HH24:MI:SS')
                                  IS NOT DISTINCT FROM \(bind: change.from)
                            RETURNING id
                            """).all(decoding: Changed.self)
                        guard !updated.isEmpty else { continue }
                        // Every library showing it re-buckets it, as for a time
                        // edited in the app.
                        let placements = try await sql.raw("""
                            SELECT id, space_id AS "spaceID" FROM space_assets
                            WHERE asset_id = \(bind: change.assetID) AND deleted_at IS NULL
                            """).all(decoding: DerivationWorker.SpacePlacement.self)
                        for placement in placements {
                            _ = try await ChangeLog.append(
                                spaceID: placement.spaceID, entity: "space_asset",
                                entityID: placement.id, op: "update", on: sql
                            )
                        }
                        done.append((change, dating))
                    }
                    try await sql.raw("COMMIT").run()
                    return done
                } catch {
                    try? await sql.raw("ROLLBACK").run()
                    throw error
                }
            }
            changed += done.count
            // After the commit, as `MediaEditController` moves a re-timed file.
            for (change, dating) in done {
                guard let from = change.storagePath,
                      let to = MediaEditController.relocationTarget(for: from, newDate: dating.capturedAt),
                      let landed = MediaEditController.move(from: from, to: to, logger: app.logger)
                else { continue }
                moved += 1
                try? await app.sql.raw("""
                    UPDATE assets SET storage_path = \(bind: landed) WHERE storage_path = \(bind: from)
                    """).run()
            }
        }
        console.info("Put \(changed) rows at Synology's time; \(moved) files moved to their month's folder.")
    }

    private func describe(_ change: Change, under root: String) -> String {
        let files = change.paths.map { String($0.dropFirst(root.count)) }.joined(separator: "  +  ")
        return "\(files)  \(change.from ?? "no time") → \(CompareDatesCommand.text(change.to))"
    }
}
