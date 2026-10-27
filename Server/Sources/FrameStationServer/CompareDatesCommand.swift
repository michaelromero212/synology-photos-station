import FrameStationAPI
import Foundation
import SQLKit
import Vapor

/// `FrameStationServer compare-dates` — whether a library from Synology Photos
/// is, or would be, in the same order here as there: every file's local time
/// beside the one Synology Photos shows, and the grid's size beside Synology's.
/// It only reads.
///
/// - Before an import, with `--path`: reads each file's dates the way the
///   import would (`ImportDating`), so a difference shows up while nothing has
///   been written.
/// - After it, with `--space` as well: compares the times the library holds.
///
/// Synology's side is `Scripts/export-synology-dates.sh`, one
/// `path<TAB>YYYY-MM-DD HH:MM:SS<TAB>item` line per file. Its taken time is the
/// local clock reading Synology Photos shows and orders by, and the item is the
/// tile: a Live Photo is two files and one item.
struct CompareDatesCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "path", short: "p", help: "The library's folder, spelled as for the import")
        var path: String?

        @Option(name: "synology", help: "Synology Photos' dates, from Scripts/export-synology-dates.sh")
        var synology: String?

        @Option(name: "space", short: "s", help: "After an import: compare the library's own times")
        var space: String?

        @Option(name: "time-zone", help: "As given to the import (default $FRAMESTATION_TIME_ZONE)")
        var timeZone: String?
    }

    var help: String { "Compare a library's dates with Synology Photos', reading only." }

    private struct Synology {
        let clock: Date
        let item: String
    }

    /// One file's local time here. Before an import, also the two dates it
    /// could have gone by, to say which one Synology went by where they differ.
    private struct Ours {
        let local: Date
        var how: String?
        var own: ImportDating?
        var modified: Date?
    }

    private struct Difference {
        let path: String
        let ours: Date
        let theirs: Date
        /// The kind of file, and the date each side went by where known.
        let kind: String
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let console = context.console
        guard let path = signature.path, let file = signature.synology else {
            throw Abort(.badRequest, reason: "--path and --synology are both required.")
        }
        let root = path.hasSuffix("/") ? path : path + "/"
        let synology = try Self.load(file).filter { $0.key.hasPrefix(root) }
        guard !synology.isEmpty else {
            throw Abort(.badRequest, reason: "\(file) has no dates for files under \(root).")
        }

        let ours: [String: Ours]
        if let space = signature.space {
            guard let spaceID = UUID(uuidString: space) else {
                throw Abort(.badRequest, reason: "--space must be a library's id.")
            }
            ours = try await Self.stored(under: root, in: spaceID, on: context.application.sql)
            console.info("Comparing \(ours.count) imported files with Synology Photos…")
        } else {
            var household: TimeZone?
            if let name = signature.timeZone ?? Environment.get("FRAMESTATION_TIME_ZONE") {
                guard let zone = TimeZone(identifier: name) else { throw ImportError.unknownTimeZone(name) }
                household = zone
            }
            console.info("Reading every file's dates under \(path), as the import would…")
            ours = try await Self.read(root: path, household: household, console: console,
                                       logger: context.application.logger)
        }

        // To the second: Synology keeps no fraction, and a burst's fraction
        // is what orders it within one.
        func second(_ date: Date) -> Int { Int(date.timeIntervalSince1970.rounded(.down)) }
        func kind(_ file: String, _ value: Ours, theirs: Date) -> String {
            var kind = "." + URL(fileURLWithPath: file).pathExtension.lowercased()
            if let how = value.how { kind += "  here: \(how)" }
            if let modified = value.modified {
                let went = if let own = value.own, second(own.local) == second(theirs) {
                    own.source.rawValue
                } else if second(modified) == second(theirs) {
                    ImportDating.Source.modified.rawValue
                } else {
                    "some other date"
                }
                kind += "  Synology: \(went)"
            }
            return kind
        }
        var same = 0
        var differences: [Difference] = []
        var notInSynology = 0
        for (file, value) in ours {
            guard let theirs = synology[file] else { notInSynology += 1; continue }
            if second(value.local) == second(theirs.clock) {
                same += 1
            } else {
                differences.append(Difference(path: file, ours: value.local, theirs: theirs.clock,
                                              kind: kind(file, value, theirs: theirs.clock)))
            }
        }
        let notHere = synology.keys.filter { ours[$0] == nil }.count

        console.info("")
        console.info("  Files compared:          \(same + differences.count)")
        console.info("  Same local time:         \(same)")
        console.info("  Different:               \(differences.count)")
        console.info("  Here, not in Synology:   \(notInSynology)")
        console.info("  In Synology, not here:   \(notHere)")
        var grouping: (split: [[String]], joined: [[String]], shown: Set<String>) = ([], [], [])
        if signature.space != nil, let spaceID = signature.space.flatMap(UUID.init(uuidString:)) {
            let tiles = try await Self.tiles(in: spaceID, on: context.application.sql)
            let theirTiles = Set(synology.values.map(\.item)).count
            grouping = try await Self.grouping(
                under: root, in: spaceID, synology: synology, on: context.application.sql
            )
            // A library the phone has backed up to holds more than Synology
            // did: what came after, and what Synology never had.
            console.info("  Grid items here:         \(tiles.count)")
            console.info("    showing these files:   \(tiles.intersection(grouping.shown).count)")
            console.info("  Grid items in Synology:  \(theirTiles)")
            console.info("  Items split here:        \(grouping.split.count)")
            console.info("  Items joined here:       \(grouping.joined.count)")
        }
        if !differences.isEmpty {
            // By kind, so a rule that's still wrong for one kind of file shows
            // as one line, with the date Synology went by instead.
            let byKind = Dictionary(grouping: differences, by: \.kind)
                .sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
            console.info("")
            console.info("  Different, by kind of file and the date each side went by,")
            console.info("  with up to 10 of each (here | Synology | difference):")
            for (kind, group) in byKind {
                console.info("    \(group.count)  \(kind)")
                for difference in group.sorted(by: { $0.path < $1.path }).prefix(10) {
                    let gap = Int(difference.ours.timeIntervalSince(difference.theirs))
                    console.info("      \(difference.path.dropFirst(root.count))  "
                        + "\(Self.text(difference.ours)) | \(Self.text(difference.theirs)) | "
                        + "\(gap < 0 ? "-" : "+")\(Self.duration(abs(gap)))")
                }
            }
        }
        for (title, items) in [("One item in Synology, more than one here", grouping.split),
                               ("More than one item in Synology, one here", grouping.joined)]
        where !items.isEmpty {
            console.info("")
            console.info("  \(title), up to 10:")
            for files in items.prefix(10) {
                console.info("    " + files.map { String($0.dropFirst(root.count)) }.joined(separator: "  +  "))
            }
        }
        console.info("")
        console.info(differences.isEmpty && notInSynology == 0 && notHere == 0
                     && grouping.split.isEmpty && grouping.joined.isEmpty
            ? "Every file matches Synology Photos to the second."
            : "Not identical yet: see above.")
    }

    // MARK: - Synology's side

    private static func load(_ file: String) throws -> [String: Synology] {
        let text = try String(contentsOfFile: file, encoding: .utf8)
        var dates: [String: Synology] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let parsed = MediaProbe.parseDateAndZone(String(fields[1])), parsed.zone == nil
            else { continue }
            dates[String(fields[0])] = Synology(clock: parsed.clock, item: String(fields[2]))
        }
        return dates
    }

    // MARK: - Ours

    /// What the import would make of each file, without importing it.
    private static func read(
        root: String, household: TimeZone?, console: any Console, logger: Logger
    ) async throws -> [String: Ours] {
        let candidates = try LibraryScanner.scan(root: URL(fileURLWithPath: root, isDirectory: true),
                                                 logger: logger)
        var result: [String: Ours] = [:]
        let batch = 64
        for start in stride(from: 0, to: candidates.count, by: batch) {
            let chunk = Array(candidates[start..<min(start + batch, candidates.count)])
            let photos = chunk.filter { $0.mediaType == .photo }.map(\.url)
            let photoMetadata = (try? await MediaProbe.probePhotoBatch(photos)) ?? [:]
            var videoMetadata: [String: MediaProbe.Metadata] = [:]
            // Four at a time, as the import hashes: ffprobe a video each.
            let videos = chunk.filter { $0.mediaType == .video }
            for group in stride(from: 0, to: videos.count, by: 4) {
                await withTaskGroup(of: (String, MediaProbe.Metadata?).self) { tasks in
                    for video in videos[group..<min(group + 4, videos.count)] {
                        tasks.addTask {
                            (video.url.path,
                             try? await MediaProbe.probe(url: video.url, mediaType: .video, dumpExif: false))
                        }
                    }
                    for await (path, metadata) in tasks {
                        if let metadata { videoMetadata[path] = metadata }
                    }
                }
            }
            for candidate in chunk {
                let probe = (candidate.mediaType == .photo ? photoMetadata : videoMetadata)[candidate.url.path]
                    ?? MediaProbe.Metadata()
                let dating = ImportDating.resolve(
                    probe: probe, modifiedAt: candidate.modifiedAt, household: household
                )
                result[candidate.url.path] = Ours(
                    local: dating.local, how: dating.source.rawValue,
                    own: ImportDating.fileDate(probe, household: household),
                    modified: ImportDating.modified(candidate.modifiedAt, household: household).local
                )
            }
            if (start / batch) % 25 == 0 || start + batch >= candidates.count {
                console.info("  \(min(start + batch, candidates.count))/\(candidates.count)")
            }
        }
        return result
    }

    private struct StoredRow: Decodable {
        let path: String
        let local: String?
    }

    /// Each imported file's row in the library, as `held(path, asset_id)`: the
    /// one the import made, or for a file it left out because the library had
    /// its bytes already, such as a photo the phone backed up through the app,
    /// the library's own copy, so that one is compared too.
    private static func held(under root: String, in space: UUID) -> SQLQueryString {
        """
        WITH held AS (
            SELECT r.source_path AS path, r.asset_id
            FROM import_records r
            JOIN space_assets sa ON sa.asset_id = r.asset_id AND sa.space_id = \(bind: space)
            WHERE starts_with(r.source_path, \(bind: root)) AND sa.deleted_at IS NULL
            UNION ALL
            SELECT r.source_path, (
                SELECT a.id FROM space_assets sa JOIN assets a ON a.id = sa.asset_id
                WHERE sa.space_id = \(bind: space) AND sa.deleted_at IS NULL AND a.sha256 = r.sha256
                ORDER BY (a.stacked_under IS NOT NULL), sa.uploaded_at LIMIT 1)
            FROM import_records r
            WHERE starts_with(r.source_path, \(bind: root)) AND r.asset_id IS NULL
              AND r.outcome = 'already in library'
        )
        """
    }

    /// The times the library holds, by the path each file was imported from.
    private static func stored(
        under root: String, in space: UUID, on sql: any SQLDatabase
    ) async throws -> [String: Ours] {
        let rows = try await sql.raw("""
            \(held(under: root, in: space))
            SELECT h.path AS "path",
                   to_char(a.local_captured_at, 'YYYY-MM-DD HH24:MI:SS.US') AS "local"
            FROM held h JOIN assets a ON a.id = h.asset_id
            """).all(decoding: StoredRow.self)
        var result: [String: Ours] = [:]
        for row in rows {
            guard let local = row.local, let parsed = MediaProbe.parseDateAndZone(local) else { continue }
            result[row.path] = Ours(local: parsed.clock)
        }
        return result
    }

    private struct TileRow: Decodable {
        let path: String
        let tile: String
    }

    /// Where the library here shows Synology's items otherwise: one item as
    /// more than one tile, or more than one item as one tile, each as its files.
    private static func grouping(
        under root: String, in space: UUID, synology: [String: Synology], on sql: any SQLDatabase
    ) async throws -> (split: [[String]], joined: [[String]], shown: Set<String>) {
        // Each imported file's tile: the file it's stacked under, the photo a
        // Live Photo's video plays from, or its own.
        let rows = try await sql.raw("""
            \(held(under: root, in: space))
            SELECT h.path AS "path",
                   COALESCE(a.stacked_under,
                            CASE WHEN a.media_type = 'video' AND a.live_group_id IS NOT NULL THEN
                                (SELECT p.id FROM assets p
                                 JOIN space_assets ps ON ps.asset_id = p.id
                                  AND ps.space_id = \(bind: space) AND ps.deleted_at IS NULL
                                 WHERE p.live_group_id = a.live_group_id AND p.media_type = 'photo'
                                 LIMIT 1)
                            END,
                            a.id)::text AS "tile"
            FROM held h JOIN assets a ON a.id = h.asset_id
            """).all(decoding: TileRow.self)
        var tilesByItem: [String: Set<String>] = [:], itemsByTile: [String: Set<String>] = [:]
        var filesByItem: [String: [String]] = [:], filesByTile: [String: [String]] = [:]
        for row in rows {
            guard let item = synology[row.path]?.item else { continue }
            tilesByItem[item, default: []].insert(row.tile)
            itemsByTile[row.tile, default: []].insert(item)
            filesByItem[item, default: []].append(row.path)
            filesByTile[row.tile, default: []].append(row.path)
        }
        let split = tilesByItem.filter { $0.value.count > 1 }.keys
            .map { filesByItem[$0, default: []].sorted() }.sorted { $0.first ?? "" < $1.first ?? "" }
        let joined = itemsByTile.filter { $0.value.count > 1 }.keys
            .map { filesByTile[$0, default: []].sorted() }.sorted { $0.first ?? "" < $1.first ?? "" }
        return (split, joined, Set(rows.map(\.tile)))
    }

    private struct TileID: Decodable { let tile: String }

    /// The grid's tiles: a Live Photo's video half isn't one.
    private static func tiles(in space: UUID, on sql: any SQLDatabase) async throws -> Set<String> {
        Set(try await sql.raw("""
            SELECT a.id::text AS tile
            FROM space_assets sa JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: space) AND sa.deleted_at IS NULL
              AND \(unsafeRaw: TimelineController.visible)
            """).all(decoding: TileID.self).map(\.tile))
    }

    // MARK: - Formatting

    private static func text(_ clock: Date) -> String {
        let seconds = Int(clock.timeIntervalSince1970.rounded(.down))
        let days = seconds >= 0 ? seconds / 86_400 : (seconds - 86_399) / 86_400
        let time = seconds - days * 86_400
        // Hinnant's civil_from_days, the inverse of `MediaProbe.utcSeconds`.
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d",
                      year, month, day, time / 3_600, (time % 3_600) / 60, time % 60)
    }

    private static func duration(_ seconds: Int) -> String {
        if seconds >= 86_400 { return "\(seconds / 86_400)d \((seconds % 86_400) / 3_600)h" }
        return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
    }
}
