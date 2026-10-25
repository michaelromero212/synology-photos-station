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
/// A rebuilt library's files are grouped the same way (`RebuildCommand`), so
/// a rebuild brings back the items an import made rather than pairing by name.
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
        space: UUID, root: String, app: Application,
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
                   a.stacked_under AS "stackedUnder", sa.space_id AS "spaceID"
            FROM import_records r
            JOIN assets a ON a.id = r.asset_id
            JOIN space_assets sa ON sa.asset_id = a.id AND sa.space_id = \(bind: space)
            WHERE EXISTS (SELECT 1 FROM unnest(\(bind: prefixes)::text[]) p WHERE starts_with(r.source_path, p))
            """).all(decoding: Member.self)

        var summary = try await group(members, app: app)
        summary.read = read
        return summary
    }

    /// Groups `members` into items, and writes and announces what changed.
    /// Every file of a folder at once: an item is made of the files given.
    static func group(_ members: [Member], app: Application) async throws -> Summary {
        let layout = layout(of: members)
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
    /// motion, and the rest stacked under it. Nothing but the files decides
    /// it, so an import and a rebuild make the same items of the same files.
    static func layout(of members: [Member]) -> Layout {
        var groups: [String: [Member]] = [:]
        for member in members {
            guard let identifier = member.identifier, !identifier.isEmpty else { continue }
            groups[folder(of: member.path) + "\n" + identifier, default: []].append(member)
        }

        var layout = Layout()
        for group in groups.values where group.count > 1 {
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
