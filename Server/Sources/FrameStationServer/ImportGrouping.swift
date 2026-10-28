import Foundation
import SQLKit
import Vapor
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Groups an imported library's files into grid items the way Synology Photos
/// does, so the grid has the items Synology's has.
///
/// Synology makes one item of every file in a folder that carries the same
/// Apple Live Photo identifier (`MediaProbe.Metadata.liveIdentifier`): a Live
/// Photo's photo and video, and a JPEG exported or an Instagram copy saved
/// from it. It shows one and keeps the rest with it. A file with no identifier
/// is an item of its own, even beside a photo or video of the same name.
/// Paired by name instead, one library (2026-10-24) showed 144 of its items as
/// 366 tiles, and hid 5 videos behind photos that only shared their names.
///
/// Here the item's photo is its tile, its video plays as its Live Photo motion
/// (`live_group_id`, as an upload's does), and the rest are stacked under it
/// (`stacked_under`): off the grid, and removed, restored and purged with it.
/// An item with no photo shows its first video.
///
/// One thing the files can't say: Synology starts an item from whichever of
/// its files reached the NAS first, and a camera's original doesn't join an
/// item an app's copy started, so in that library 8 Instagram copies that
/// arrived before their Live Photos were items of their own. Given Synology's
/// own items (`synologyItems`, from `Scripts/export-synology-dates.sh`), a
/// group is split where Synology split it, and joined where Synology made one
/// item of files the identifiers keep apart: in the second library
/// (2026-10-27), a Live Photo's own photo whose Make had gone, beside its
/// video of the same name.
///
/// A rebuilt library's files are grouped the same way (`RebuildCommand`), so
/// a rebuild brings back the items an import made rather than pairing by name.
///
/// A library the phone backed up to through the app may hold another version
/// of something Synology has, edited or from the Shared Space, which Synology
/// never had. There the imported file is kept with the phone's (`join`), so
/// the grid shows it once, as Synology's did.
enum ImportGrouping {
    struct Summary {
        /// Items of more than one file.
        var items = 0
        var livePhotos = 0
        var stacked = 0
        /// Identifiers read from files imported before they were recorded.
        var read = 0
        /// Files whose grouping changed.
        var changed = 0
        /// Files kept with the phone's version of the same item.
        var keptWithPhone = 0
    }

    /// A file to group, as it's grouped now.
    struct Member: Decodable {
        let assetID: UUID
        let placementID: UUID
        /// The library that hears of a change to it.
        let spaceID: UUID
        let path: String
        /// nil or "" for a file that carries none.
        let identifier: String?
        let mediaType: String
        let modifiedAt: Date
        let liveGroupID: UUID?
        let stackedUnder: UUID?
        /// Its local time to the second, to find the phone's version by.
        var local: String? = nil
    }

    /// A tile the phone backed up through the app.
    struct PhoneTile: Decodable {
        let id: UUID
        let mediaType: String
        /// Its local time to the second.
        let local: String
        let sha: String?
        /// Every name it has in any library, `/` between them.
        let names: String?
    }

    /// A file the import left out because the library had its bytes, and the
    /// tile that shows them here.
    struct Held: Decodable {
        let path: String
        let sha: String
        let tile: UUID?
    }

    /// What files make together: the Live Photo each pair plays as, and the
    /// file each of the rest is stacked under. Any other file is an item of
    /// its own.
    struct Layout {
        var liveGroup: [UUID: UUID] = [:]
        var stackedUnder: [UUID: UUID] = [:]
        var summary = Summary()
    }

    /// Regroups every file imported into `space` from under `root`, by the
    /// identifiers recorded at import, reading any not yet recorded from the
    /// files. Whole folders at a time: an item never spans two, and Synology
    /// kept a Live Photo's copy in another folder apart from it.
    static func regroup(
        space: UUID, root: String, app: Application, synologyItems: [String: String]? = nil,
        progress: (Int, Int) -> Void = { _, _ in }
    ) async throws -> Summary {
        // As given and as the walk may have recorded it, its links resolved:
        // macOS's /var is a link to /private/var.
        let prefixes = Array(Set([root, realPath(root)].map { $0.hasSuffix("/") ? $0 : $0 + "/" }))
        let read = try await recordMissingIdentifiers(
            under: prefixes, in: space, app: app, progress: progress
        )

        let members = try await app.sql.raw("""
            SELECT a.id AS "assetID", sa.id AS "placementID", r.source_path AS "path",
                   NULLIF(r.live_identifier, '') AS "identifier", a.media_type AS "mediaType",
                   r.modified_at AS "modifiedAt", a.live_group_id AS "liveGroupID",
                   a.stacked_under AS "stackedUnder", sa.space_id AS "spaceID",
                   to_char(a.local_captured_at, 'YYYY-MM-DD HH24:MI:SS') AS "local"
            FROM import_records r
            JOIN assets a ON a.id = r.asset_id
            JOIN space_assets sa ON sa.asset_id = a.id AND sa.space_id = \(bind: space)
            WHERE EXISTS (SELECT 1 FROM unnest(\(bind: prefixes)::text[]) p WHERE starts_with(r.source_path, p))
            """).all(decoding: Member.self)

        // The files left out because the library had their bytes, each with
        // the tile it shows as: its stack's, a Live Photo's photo, or its own.
        let held = try await app.sql.raw("""
            SELECT r.source_path AS "path", r.sha256 AS "sha", (
                SELECT COALESCE(a.stacked_under,
                                CASE WHEN a.media_type = 'video' AND a.live_group_id IS NOT NULL THEN
                                    (SELECT p.id FROM assets p
                                     JOIN space_assets ps ON ps.asset_id = p.id
                                      AND ps.space_id = \(bind: space) AND ps.deleted_at IS NULL
                                     WHERE p.live_group_id = a.live_group_id AND p.media_type = 'photo'
                                     LIMIT 1)
                                END,
                                a.id)
                FROM space_assets sa JOIN assets a ON a.id = sa.asset_id
                WHERE sa.space_id = \(bind: space) AND sa.deleted_at IS NULL AND a.sha256 = r.sha256
                ORDER BY (a.stacked_under IS NOT NULL), sa.uploaded_at
                LIMIT 1) AS "tile"
            FROM import_records r
            WHERE r.outcome = 'already in library' AND r.sha256 IS NOT NULL
              AND EXISTS (SELECT 1 FROM unnest(\(bind: prefixes)::text[]) p WHERE starts_with(r.source_path, p))
            """).all(decoding: Held.self)
        // Every tile the phone put here, with each name it has anywhere.
        let phone = try await app.sql.raw("""
            SELECT a.id, a.media_type AS "mediaType",
                   to_char(a.local_captured_at, 'YYYY-MM-DD HH24:MI:SS') AS "local", a.sha256 AS "sha",
                   (SELECT string_agg(DISTINCT n.filename, '/') FROM space_assets n
                    WHERE n.asset_id = a.id AND n.filename IS NOT NULL) AS "names"
            FROM space_assets sa JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: space) AND sa.deleted_at IS NULL AND sa.on_device
              AND a.stacked_under IS NULL AND a.local_captured_at IS NOT NULL
              AND NOT (a.media_type = 'video' AND a.live_group_id IS NOT NULL)
            """).all(decoding: PhoneTile.self)
        // The bytes of every file of the library left out as the phone's, in
        // any of its folders, which Synology has too. Given its items, the
        // library is every file of the export: in the second library a copy
        // in PhotoLibrary of a photo whose MobileBackup file the phone had
        // went under the phone's tile, as another version would (2026-10-28).
        struct LeftOut: Decodable {
            let path: String
            let sha: String
        }
        let heldBytes = Set(try await app.sql.raw("""
            SELECT source_path AS "path", sha256 AS "sha" FROM import_records
            WHERE outcome = 'already in library' AND sha256 IS NOT NULL
            """).all(decoding: LeftOut.self).filter { file in
                prefixes.contains { file.path.hasPrefix($0) } || synologyItems?[file.path] != nil
            }.map(\.sha))

        var summary = try await group(
            members, app: app, synologyItems: synologyItems, held: held, heldBytes: heldBytes,
            phone: phone
        )
        summary.read = read
        return summary
    }

    /// Groups `members` into items, and writes and announces what changed.
    /// Every file of a folder at once: an item is made of the files given.
    static func group(
        _ members: [Member], app: Application, synologyItems: [String: String]? = nil,
        held: [Held] = [], heldBytes: Set<String>? = nil, phone: [PhoneTile] = []
    ) async throws -> Summary {
        var layout = layout(of: members, synologyItems: synologyItems)
        join(&layout, members: members, held: held, heldBytes: heldBytes ?? Set(held.map(\.sha)),
             phone: phone, synologyItems: synologyItems)
        let liveGroup = layout.liveGroup, stackedUnder = layout.stackedUnder
        var summary = layout.summary

        // Only what changes, with its announcement: a device showing a file
        // that's now stacked away, or a photo that's now a Live Photo, has to
        // hear about it.
        let changed = members.filter {
            $0.liveGroupID != liveGroup[$0.assetID] || $0.stackedUnder != stackedUnder[$0.assetID]
        }
        summary.changed = changed.count
        guard !changed.isEmpty else { return summary }
        let ids = changed.map(\.assetID)
        let paired = changed.compactMap { member in liveGroup[member.assetID].map { (member.assetID, $0) } }
        let stacked = changed.compactMap { member in stackedUnder[member.assetID].map { (member.assetID, $0) } }
        try await app.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                // Each its own item first, so no file is ever stacked under a
                // file stacked in turn under another.
                try await sql.raw("""
                    UPDATE assets SET live_group_id = NULL, stacked_under = NULL
                    WHERE id = ANY(\(bind: ids))
                    """).run()
                if !paired.isEmpty {
                    try await sql.raw("""
                        UPDATE assets a SET live_group_id = v.group_id
                        FROM unnest(\(bind: paired.map { $0.0 })::uuid[], \(bind: paired.map { $0.1 })::uuid[])
                             AS v(id, group_id)
                        WHERE a.id = v.id
                        """).run()
                }
                if !stacked.isEmpty {
                    try await sql.raw("""
                        UPDATE assets a SET stacked_under = v.under
                        FROM unnest(\(bind: stacked.map { $0.0 })::uuid[], \(bind: stacked.map { $0.1 })::uuid[])
                             AS v(id, under)
                        WHERE a.id = v.id
                        """).run()
                }
                for member in changed {
                    _ = try await ChangeLog.append(
                        spaceID: member.spaceID, entity: "space_asset", entityID: member.placementID,
                        op: "update", on: sql
                    )
                }
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
        return summary
    }

    /// The items `members` make: every file in a folder with the same
    /// identifier is one, its photo shown, its first video that photo's
    /// motion, and the rest stacked under it, split and joined as Synology's
    /// items are when they're given. Nothing else decides it, so an import and
    /// a rebuild make the same items of the same files.
    static func layout(of members: [Member], synologyItems: [String: String]? = nil) -> Layout {
        var groups: [String: [Member]] = [:]
        for member in members {
            guard let identifier = member.identifier, !identifier.isEmpty else { continue }
            groups[folder(of: member.path) + "\n" + identifier, default: []].append(member)
        }
        var parts = groups.values.flatMap { split($0, as: synologyItems) }
        if let synologyItems { parts = joined(parts, members: members, as: synologyItems) }

        var layout = Layout()
        for group in parts where group.count > 1 {
            layout.summary.items += 1
            let photos = group.filter { $0.mediaType == "photo" }
            let videos = group.filter { $0.mediaType == "video" }
            let videoStems = Set(videos.map { stem(of: $0.path) })
            let shown: Member
            if let photo = photos.min(by: { rank($0, partners: videoStems) < rank($1, partners: videoStems) }) {
                shown = photo
                let photoStem: Set<String> = [stem(of: photo.path)]
                if let motion = videos.min(by: { rank($0, partners: photoStem) < rank($1, partners: photoStem) }) {
                    // The pair's id as it was, when it was already this pair.
                    let id = photo.liveGroupID != nil && photo.liveGroupID == motion.liveGroupID
                        ? photo.liveGroupID! : UUID()
                    layout.liveGroup[photo.assetID] = id
                    layout.liveGroup[motion.assetID] = id
                    layout.summary.livePhotos += 1
                }
            } else {
                shown = videos.min(by: { rank($0, partners: []) < rank($1, partners: []) })!
            }
            for member in group where member.assetID != shown.assetID && layout.liveGroup[member.assetID] == nil {
                layout.stackedUnder[member.assetID] = shown.assetID
                layout.summary.stacked += 1
            }
        }
        return layout
    }

    /// Keeps an imported file that's another version of something the phone
    /// backed up with the phone's tile, so the grid shows it once, as
    /// Synology's did: Synology never had the phone's version.
    ///
    /// Synology's item says so where the phone's copy of one of its files is
    /// here already: a Live Photo whose video the app backed up byte for byte
    /// and whose photo it backed up otherwise (in the second library the app
    /// had it from the Shared Space). Without that, only a tile of the same
    /// kind, second and name the phone backed up and no file of Synology's
    /// holds: a burst frame the phone also backed up is in Synology too, and
    /// stays an item of its own. A whole item goes under the phone's tile, its
    /// motion and kept files too, one level deep, as every stack is.
    private static func join(
        _ layout: inout Layout, members: [Member], held: [Held], heldBytes: Set<String>,
        phone: [PhoneTile], synologyItems: [String: String]?
    ) {
        guard !phone.isEmpty else { return }
        var photoOfPair: [UUID: UUID] = [:]
        for member in members where member.mediaType == "photo" {
            if let pair = layout.liveGroup[member.assetID] { photoOfPair[pair] = member.assetID }
        }
        var tileOf: [UUID: UUID] = [:]
        for member in members {
            if let under = layout.stackedUnder[member.assetID] {
                tileOf[member.assetID] = under
            } else if member.mediaType == "video", let pair = layout.liveGroup[member.assetID],
                      let photo = photoOfPair[pair] {
                tileOf[member.assetID] = photo
            } else {
                tileOf[member.assetID] = member.assetID
            }
        }

        var joins: [UUID: UUID] = [:]
        let phoneIDs = Set(phone.map(\.id))
        if let synologyItems {
            var phoneTileOfItem: [String: UUID] = [:]
            for file in held {
                guard let tile = file.tile, phoneIDs.contains(tile),
                      let item = synologyItems[file.path], phoneTileOfItem[item] == nil else { continue }
                phoneTileOfItem[item] = tile
            }
            for member in members {
                guard let item = synologyItems[member.path], let tile = phoneTileOfItem[item],
                      let own = tileOf[member.assetID] else { continue }
                joins[own] = tile
            }
        }
        var unheld: [String: [PhoneTile]] = [:]
        for tile in phone where !(tile.sha.map(heldBytes.contains) ?? false) {
            unheld[tile.local + "|" + tile.mediaType, default: []].append(tile)
        }
        for member in members where tileOf[member.assetID] == member.assetID && joins[member.assetID] == nil {
            guard let local = member.local, let candidates = unheld[local + "|" + member.mediaType] else { continue }
            let name = stem(of: member.path).uppercased()
            if let match = candidates.first(where: { candidate in
                (candidate.names ?? "").split(separator: "/").contains { stem(of: String($0)).uppercased() == name }
            }) {
                joins[member.assetID] = match.id
            }
        }
        guard !joins.isEmpty else { return }

        let grouped = Set(layout.stackedUnder.values).union(photoOfPair.values)
        var pairs = Set<UUID>()
        for member in members {
            guard let own = tileOf[member.assetID], let tile = joins[own] else { continue }
            if let pair = layout.liveGroup.removeValue(forKey: member.assetID) { pairs.insert(pair) }
            if layout.stackedUnder[member.assetID] != nil { layout.summary.stacked -= 1 }
            layout.stackedUnder[member.assetID] = tile
            layout.summary.keptWithPhone += 1
        }
        layout.summary.livePhotos -= pairs.count
        layout.summary.items -= Set(joins.keys).intersection(grouped).count
    }

    /// A group as Synology's items divide it, when they're known. A file
    /// Synology doesn't have goes with the largest part.
    private static func split(_ group: [Member], as synologyItems: [String: String]?) -> [[Member]] {
        guard let synologyItems else { return [group] }
        var parts: [String: [Member]] = [:]
        var unknown: [Member] = []
        for member in group {
            if let item = synologyItems[member.path] { parts[item, default: []].append(member) }
            else { unknown.append(member) }
        }
        var divided = parts.values.sorted { $0.count > $1.count }
        if divided.isEmpty { return [unknown] }
        divided[0] += unknown
        return divided
    }

    /// The parts as Synology's items join them: every file of one item in a
    /// folder together, whatever its identifier, or with none. After `split`,
    /// a part is of one item at most.
    private static func joined(
        _ parts: [[Member]], members: [Member], as synologyItems: [String: String]
    ) -> [[Member]] {
        func item(of member: Member) -> String? {
            synologyItems[member.path].map { folder(of: member.path) + "\n" + $0 }
        }
        var result: [[Member]] = []
        var index: [String: Int] = [:]
        var grouped = Set<UUID>()
        for part in parts {
            grouped.formUnion(part.map(\.assetID))
            guard let key = part.lazy.compactMap(item(of:)).first else { result.append(part); continue }
            if let at = index[key] { result[at] += part } else { index[key] = result.count; result.append(part) }
        }
        for member in members where !grouped.contains(member.assetID) {
            guard let key = item(of: member) else { continue }
            if let at = index[key] { result[at].append(member) } else { index[key] = result.count; result.append([member]) }
        }
        return result
    }

    /// Synology's item for each file, from `Scripts/export-synology-dates.sh`:
    /// `path<TAB>taken<TAB>item` per line.
    static func synologyItems(from file: String) throws -> [String: String] {
        var items: [String: String] = [:]
        for line in try String(contentsOfFile: file, encoding: .utf8).split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if fields.count >= 3 { items[String(fields[0])] = String(fields[2]) }
        }
        return items
    }

    /// Reads the identifier of every file imported before it was recorded, and
    /// records it: "" for a file that carries none. One exiftool run per 64.
    private static func recordMissingIdentifiers(
        under prefixes: [String], in space: UUID, app: Application,
        progress: (Int, Int) -> Void
    ) async throws -> Int {
        struct Row: Decodable { let path: String }
        let rows = try await app.sql.raw("""
            SELECT r.source_path AS "path" FROM import_records r
            JOIN space_assets sa ON sa.asset_id = r.asset_id AND sa.space_id = \(bind: space)
            WHERE EXISTS (SELECT 1 FROM unnest(\(bind: prefixes)::text[]) p WHERE starts_with(r.source_path, p))
              AND r.live_identifier IS NULL
            ORDER BY r.source_path
            """).all(decoding: Row.self)
        var recorded = 0
        for start in stride(from: 0, to: rows.count, by: 64) {
            let paths = rows[start..<min(start + 64, rows.count)].map(\.path)
            let read = try await MediaProbe.liveIdentifiers(paths.map { URL(fileURLWithPath: $0) })
            // A file exiftool says nothing about stays unread, to try again.
            let found = paths.compactMap { path in read[path].map { (path, $0) } }
            if !found.isEmpty {
                try await app.sql.raw("""
                    UPDATE import_records r SET live_identifier = v.identifier
                    FROM unnest(\(bind: found.map { $0.0 })::text[], \(bind: found.map { $0.1 })::text[])
                         AS v(path, identifier)
                    WHERE r.source_path = v.path
                    """).run()
                recorded += found.count
            }
            progress(min(start + 64, rows.count), rows.count)
        }
        return recorded
    }

    /// The order an item's files are shown in, its tile first: as near as the
    /// files tell to the order Synology indexed them, which put a Live Photo's
    /// own photo first (named as its video is), an older file before a newer
    /// copy, and a camera's name before an app's (`5A5A644B-….jpg`).
    private static func rank(_ member: Member, partners: Set<String>) -> (Int, Date, Int, String) {
        let stem = stem(of: member.path)
        return (partners.contains(stem) ? 0 : 1, member.modifiedAt, isAppName(stem) ? 1 : 0, member.path)
    }

    /// `realpath`, not `resolvingSymlinksInPath`, which takes `/private` back
    /// off a path the walk recorded with it.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func folder(of path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    private static func stem(of path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    /// A name an app gave a file it saved, which starts with a UUID.
    private static func isAppName(_ stem: String) -> Bool {
        stem.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-"#, options: .regularExpression) != nil
    }
}
