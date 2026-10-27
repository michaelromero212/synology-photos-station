import Foundation
import SQLKit
import Vapor

/// `FrameStationServer import-albums` — a person's Synology Photos albums, made
/// their own albums here once their library is imported.
///
/// `Scripts/export-synology-albums.sh` writes them from Synology's database,
/// one tab-separated line per file, each album's items in its order: the
/// album's id there, its name, when it was made (UTC), the item's place in it,
/// the item's id, the file's path as the import walked it, and "cover" on the
/// cover's files.
///
/// An item is found here by its files: the row the import made for a file or,
/// for one it skipped because the library already held the bytes (the app had
/// backed it up), the library's own copy. The album holds what the grid shows
/// for it: a Live Photo's photo, and for a copy kept with another (see
/// `ImportGrouping`), that other.
///
/// Each becomes a personal album of the library's owner, as New Album makes
/// one with nobody to share it with. Nothing is taken away: an album of theirs
/// with the same name gets only what it's missing, so running this again
/// changes nothing.
struct ImportAlbumsCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "from", help: "Tab-separated lines from Scripts/export-synology-albums.sh")
        var from: String?

        @Option(name: "space", short: "s", help: "The personal library the files were imported into")
        var space: String?

        @Flag(name: "dry-run", help: "Report what would be made without making anything")
        var dryRun: Bool
    }

    var help: String { "Make a person's Synology Photos albums their own albums here." }

    private struct Album {
        let key: String
        let name: String
        let created: Date?
        var items: [Item] = []
    }

    private struct Item {
        let key: String
        let position: Int
        var paths: [String] = []
        var isCover = false
    }

    private struct RecordRow: Decodable {
        let path: String
        let sha: String?
        let assetID: UUID?
        let outcome: String
    }

    private struct AssetRow: Decodable {
        let placementID: UUID
        let assetID: UUID
        let sha: String?
        let mediaType: String
        let liveGroupID: UUID?
        let stackedUnder: UUID?
        let deleted: Bool
    }

    private struct IDRow: Decodable { let id: UUID }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let console = context.console

        guard let from = signature.from else {
            throw Abort(.badRequest, reason: "--from is required: the file export-synology-albums.sh writes.")
        }
        guard let spaceID = signature.space.flatMap(UUID.init(uuidString:)) else {
            throw Abort(.badRequest, reason: "--space is required. Run `FrameStationServer spaces`.")
        }
        guard let owner = try await app.sql.raw("""
            SELECT m.user_id AS id FROM spaces s
            JOIN space_members m ON m.space_id = s.id AND m.role = 'owner'
            WHERE s.id = \(bind: spaceID) AND s.kind = 'personal'
            """).first(decoding: IDRow.self)?.id else {
            throw Abort(.badRequest, reason: "No personal library with id \(spaceID). Run `FrameStationServer spaces`.")
        }
        let (albums, unreadable) = try Self.load(from)

        // What the import made of each file, and everything in the library,
        // deleted or not, to tell a file that never came from one removed here.
        let paths = albums.flatMap { $0.items.flatMap(\.paths) }
        let records = try await app.sql.raw("""
            SELECT source_path AS path, sha256 AS sha, asset_id AS "assetID", outcome
            FROM import_records WHERE source_path = ANY(\(bind: paths)::text[])
            """).all(decoding: RecordRow.self)
        let recordByPath = Dictionary(records.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = try await app.sql.raw("""
            SELECT sa.id AS "placementID", a.id AS "assetID", a.sha256 AS sha,
                   a.media_type AS "mediaType", a.live_group_id AS "liveGroupID",
                   a.stacked_under AS "stackedUnder", (sa.deleted_at IS NOT NULL) AS deleted
            FROM space_assets sa JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID)
            """).all(decoding: AssetRow.self)
        var shown: [UUID: AssetRow] = [:], bySha: [String: [AssetRow]] = [:], livePhoto: [UUID: AssetRow] = [:]
        var held: Set<UUID> = []
        for row in rows {
            held.insert(row.assetID)
            if let sha = row.sha { bySha[sha, default: []].append(row) }
            guard !row.deleted else { continue }
            shown[row.assetID] = row
            if row.mediaType == "photo", let group = row.liveGroupID { livePhoto[group] = row }
        }

        /// The grid's tile for a file: the one it's kept with, a Live Photo's
        /// photo for its video, or its own.
        func tile(_ row: AssetRow, depth: Int = 0) -> AssetRow? {
            if let top = row.stackedUnder {
                guard depth < 4, let stack = shown[top] else { return nil }
                return tile(stack, depth: depth + 1)
            }
            if row.mediaType == "video", let group = row.liveGroupID, let photo = livePhoto[group] {
                return photo
            }
            return row
        }

        /// A file's tile here, or why it has none.
        func find(_ path: String) -> (tile: AssetRow?, missing: String?) {
            guard let record = recordByPath[path] else { return (nil, "never imported") }
            let own = record.assetID.flatMap { shown[$0] }
            let same = record.sha.map { bySha[$0, default: []] } ?? []
            if let row = own ?? same.first(where: { !$0.deleted }), let found = tile(row) {
                return (found, nil)
            }
            if record.outcome == "failed" { return (nil, "failed to import") }
            let wasHere = !same.isEmpty || record.assetID.map(held.contains) == true
            return (nil, wasHere ? "deleted here" : "not in this library")
        }

        console.info("")
        var made = 0, added = 0
        for album in albums {
            var placements: [UUID] = [], cover: UUID?
            var missing: [(path: String, why: String)] = []
            for item in album.items {
                for path in item.paths {
                    let (found, why) = find(path)
                    guard let found else {
                        missing.append((path, why ?? "not found"))
                        continue
                    }
                    if !placements.contains(found.placementID) { placements.append(found.placementID) }
                    if item.isCover, cover == nil { cover = found.assetID }
                }
            }
            console.info("  \(album.name): \(album.items.count) items, \(placements.count) here"
                + (missing.isEmpty ? "" : ", \(missing.count) files not found"))
            for (path, why) in missing.prefix(10) { console.info("      \(path)  (\(why))") }
            guard !signature.dryRun, !placements.isEmpty else { continue }

            let tiles = placements, chosenCover = cover
            let (albumID, isNew, inserted) = try await app.withPinnedConnection { sql -> (UUID, Bool, Int) in
                try await sql.raw("BEGIN").run()
                do {
                    var isNew = false
                    var albumID = try await sql.raw("""
                        SELECT id FROM albums
                        WHERE owner_user_id = \(bind: owner) AND space_id IS NULL AND name = \(bind: album.name)
                        ORDER BY created_at LIMIT 1
                        """).first(decoding: IDRow.self)?.id
                    if albumID == nil {
                        let when = album.created ?? Date()
                        albumID = try await sql.raw("""
                            INSERT INTO albums (owner_user_id, name, created_by, created_at, updated_at)
                            VALUES (\(bind: owner), \(bind: album.name), \(bind: owner), \(bind: when), \(bind: when))
                            RETURNING id
                            """).first(decoding: IDRow.self)?.id
                        isNew = true
                    }
                    guard let albumID else {
                        throw Abort(.internalServerError, reason: "Could not make the album \(album.name).")
                    }
                    var inserted = 0
                    for (position, placement) in tiles.enumerated() {
                        if try await sql.raw("""
                            INSERT INTO album_assets (album_id, space_asset_id, added_by, position)
                            VALUES (\(bind: albumID), \(bind: placement), \(bind: owner), \(bind: Double(position)))
                            ON CONFLICT (album_id, space_asset_id) DO NOTHING
                            RETURNING space_asset_id AS id
                            """).first(decoding: IDRow.self) != nil {
                            inserted += 1
                        }
                    }
                    // Synology's cover, or the first item, as an album made in
                    // the app starts out; never over one already chosen.
                    try await sql.raw("""
                        UPDATE albums SET cover_asset_id = COALESCE(\(bind: chosenCover), (
                            SELECT sa.asset_id FROM album_assets aa
                            JOIN space_assets sa ON sa.id = aa.space_asset_id
                            WHERE aa.album_id = \(bind: albumID) AND sa.deleted_at IS NULL
                            ORDER BY aa.position, aa.added_at LIMIT 1))
                        WHERE id = \(bind: albumID) AND cover_asset_id IS NULL
                        """).run()
                    try await sql.raw("COMMIT").run()
                    return (albumID, isNew, inserted)
                } catch {
                    try? await sql.raw("ROLLBACK").run()
                    throw error
                }
            }
            if isNew { made += 1 }
            added += inserted
            app.logger.info("album \(albumID): \(inserted) items added")
        }

        console.info("")
        if unreadable > 0 { console.info("  Unreadable lines: \(unreadable)") }
        if signature.dryRun {
            console.info("Dry run — nothing made.")
        } else {
            console.info("  Albums made: \(made) of \(albums.count); items added: \(added)")
        }
    }

    /// The albums in the file, each one's items in its order.
    private static func load(_ file: String) throws -> (albums: [Album], unreadable: Int) {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
            throw Abort(.badRequest, reason: "Can't read \(file).")
        }
        var albums: [Album] = [], albumIndex: [String: Int] = [:]
        var itemIndex: [String: [String: Int]] = [:]
        var unreadable = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let name = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            guard fields.count >= 6, !name.isEmpty, name.count <= 120,
                  let position = Int(fields[3]), !fields[5].isEmpty else {
                unreadable += 1
                continue
            }
            let albumKey = fields[0], itemKey = fields[4]
            if albumIndex[albumKey] == nil {
                albumIndex[albumKey] = albums.count
                albums.append(Album(key: albumKey, name: name,
                                    created: MediaProbe.parseDateAndZone(fields[2])?.clock))
            }
            let a = albumIndex[albumKey]!
            if itemIndex[albumKey]?[itemKey] == nil {
                itemIndex[albumKey, default: [:]][itemKey] = albums[a].items.count
                albums[a].items.append(Item(key: itemKey, position: position))
            }
            let i = itemIndex[albumKey]![itemKey]!
            albums[a].items[i].paths.append(fields[5])
            if fields.count > 6, fields[6] == "cover" { albums[a].items[i].isCover = true }
        }
        for a in albums.indices {
            albums[a].items = albums[a].items.enumerated()
                .sorted { ($0.element.position, $0.offset) < ($1.element.position, $1.offset) }
                .map(\.element)
        }
        return (albums, unreadable)
    }
}
