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

    private struct Difference {
        let path: String
        let ours: Date
        let theirs: Date
        let how: String
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

        let ours: [String: (local: Date, how: String)]
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
        var same = 0
        var differences: [Difference] = []
        var notInSynology = 0
        for (file, value) in ours {
            guard let theirs = synology[file] else { notInSynology += 1; continue }
            if second(value.local) == second(theirs.clock) {
                same += 1
            } else {
                differences.append(Difference(path: file, ours: value.local, theirs: theirs.clock, how: value.how))
            }
        }
        let notHere = synology.keys.filter { ours[$0] == nil }.count

        console.info("")
        console.info("  Files compared:          \(same + differences.count)")
        console.info("  Same local time:         \(same)")
        console.info("  Different:               \(differences.count)")
        console.info("  Here, not in Synology:   \(notInSynology)")
        console.info("  In Synology, not here:   \(notHere)")
        if signature.space != nil, let spaceID = signature.space.flatMap(UUID.init(uuidString:)) {
            let tiles = try await Self.tiles(in: spaceID, on: context.application.sql)
            let theirTiles = Set(synology.values.map(\.item)).count
            console.info("  Grid items here:         \(tiles)")
            console.info("  Grid items in Synology:  \(theirTiles)")
        }
        if !differences.isEmpty {
            let byHow = Dictionary(grouping: differences, by: \.how)
            console.info("")
            console.info("  Different, by what dated them here:")
            for (how, group) in byHow.sorted(by: { $0.value.count > $1.value.count }) {
                console.info("    \(group.count)  \(how)")
            }
            console.info("")
            console.info("  The first 25 (here | Synology | difference):")
            for difference in differences.sorted(by: { $0.path < $1.path }).prefix(25) {
                let gap = Int(difference.ours.timeIntervalSince(difference.theirs))
                console.info("    \(difference.path.dropFirst(root.count))  "
                    + "\(Self.text(difference.ours)) | \(Self.text(difference.theirs)) | "
                    + "\(gap < 0 ? "-" : "+")\(Self.duration(abs(gap)))")
            }
        }
        console.info("")
        console.info(differences.isEmpty && notInSynology == 0 && notHere == 0
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
    ) async throws -> [String: (local: Date, how: String)] {
        let candidates = try LibraryScanner.scan(root: URL(fileURLWithPath: root, isDirectory: true),
                                                 logger: logger)
        var result: [String: (local: Date, how: String)] = [:]
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
                result[candidate.url.path] = (dating.local, dating.source.rawValue)
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

    /// The times an import stored, by the path it was imported from.
    private static func stored(
        under root: String, in space: UUID, on sql: any SQLDatabase
    ) async throws -> [String: (local: Date, how: String)] {
        let rows = try await sql.raw("""
            SELECT r.source_path AS "path",
                   to_char(a.local_captured_at, 'YYYY-MM-DD HH24:MI:SS.US') AS "local"
            FROM import_records r
            JOIN assets a ON a.id = r.asset_id
            JOIN space_assets sa ON sa.asset_id = a.id AND sa.space_id = \(bind: space)
            WHERE r.source_path LIKE \(bind: root + "%") AND sa.deleted_at IS NULL
            """).all(decoding: StoredRow.self)
        var result: [String: (local: Date, how: String)] = [:]
        for row in rows {
            guard let local = row.local, let parsed = MediaProbe.parseDateAndZone(local) else { continue }
            result[row.path] = (parsed.clock, "stored")
        }
        return result
    }

    private struct CountRow: Decodable { let count: Int }

    /// Tiles in the grid: a Live Photo's video half isn't one.
    private static func tiles(in space: UUID, on sql: any SQLDatabase) async throws -> Int {
        try await sql.raw("""
            SELECT count(*)::int AS count
            FROM space_assets sa JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: space) AND sa.deleted_at IS NULL
              AND \(unsafeRaw: TimelineController.visible)
            """).first(decoding: CountRow.self)?.count ?? 0
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
