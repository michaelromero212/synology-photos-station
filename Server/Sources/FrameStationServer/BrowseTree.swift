import Foundation
import FrameStationAPI
import SQLKit
import Vapor
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Builds the human-readable tree people actually browse in File Station.
///
/// The blob store is named by hash — correct for storage, meaningless to
/// someone opening a folder. This mirrors every placement into the home of
/// each person entitled to see it, at a path built from when it was taken:
///
///   /volume1/homes/<dsm user>/Photos/Personal/YYYY/MM/IMG_4821.heic        personal
///   /volume1/homes/<dsm user>/Photos/Shared/<Space>/YYYY/MM/IMG_4821.heic  shared
///
/// So opening `Photos` shows two folders, Personal and Shared, and nothing
/// else of FrameStation's. Synology Photos' own `MobileBackup` and
/// `PhotoLibrary` sit beside them until that library is migrated.
///
/// Entries are **reflinks**, not copies or hardlinks. Hardlinks cannot cross
/// Synology's per-shared-folder Btrfs subvolumes at all (`/volume1/FrameStation`
/// and `/volume1/homes` are different devices — see ARCHITECTURE.md §4).
/// Reflinks can, cost nothing until written, and diverge on write: someone
/// editing a photo in File Station gets their own copy instead of silently
/// corrupting the canonical blob every other member is reading.
enum BrowseTree {

    /// Where a newly committed file should live, or nil when the library
    /// layout can't place it — no DSM account linked, or the layout disabled.
    ///
    /// Called at commit time, so the date comes from what the client sent
    /// rather than from EXIF, which is only read later during derivation. The
    /// two agree for anything a phone uploads; a file whose EXIF later disputes
    /// the folder stays where it was put, because moving a file after the fact
    /// is worse than a month being off by one.
    struct Configuration {
        /// Where DSM keeps user home directories.
        var homesRoot: String
        /// Only `RebuildCommand` still reads this: it scans an existing tree to
        /// rebuild the database after a disaster. Nothing *writes* here any
        /// more — a shared space goes into each member's home, because one
        /// folder everybody could read could not tell members from
        /// non-members. A rebuild against a library written by this version
        /// wants the homes root; this stays for libraries written by an older
        /// one.
        var sharedRoot: String
        /// Off unless explicitly enabled: writing into `/volume1/homes` needs
        /// the container running as root, which is not the default.
        var enabled: Bool

        static func fromEnvironment() -> Configuration {
            Configuration(
                homesRoot: Environment.get("FRAMESTATION_HOMES_ROOT") ?? "/volume1/homes",
                sharedRoot: Environment.get("FRAMESTATION_SHARED_ROOT")
                    ?? "/volume1/FrameStation/Shared",
                enabled: (Environment.get("FRAMESTATION_BROWSE_TREE") ?? "0") == "1"
            )
        }
    }

    /// How the copy was actually made. `copy` is no longer made (see `link`),
    /// but older rows may carry it.
    enum LinkKind: String {
        case reflink, hardlink, copy
    }

    /// Somebody who may see this photograph, and the DSM account that decides
    /// where their copy goes.
    struct Recipient: Hashable {
        let userID: UUID
        let dsmUsername: String?
        let dsmUID: Int?
    }

    struct Placement {
        let id: UUID
        let sha256: String
        let blobExt: String
        let filename: String?
        let capturedAt: Date?
        let spaceKind: String
        let spaceName: String
        /// For a personal space, the owner. For a shared space, every member.
        ///
        /// Plural because that is the whole of the access model: a shared
        /// photograph appears in each member's own home, so DSM's home
        /// permissions do the enforcing and somebody who is not a member has no
        /// folder to find. One shared folder that everybody could read was the
        /// alternative, and it could not tell members from non-members at all.
        let recipients: [Recipient]
    }

    // MARK: - Path building

    /// `IMG_4821.heic`, or the hash when the original name never arrived.
    static func fileName(for placement: Placement) -> String {
        if let raw = placement.filename?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return sanitise(raw)
        }
        return "\(placement.sha256.prefix(16)).\(placement.blobExt)"
    }

    /// Strips anything that would let a filename escape its directory or upset
    /// SMB. A name arrives from a phone and is not to be trusted with a path.
    static func sanitise(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let cleaned = base.unicodeScalars.map { scalar -> Character in
            let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\0")
            return bad.contains(scalar) ? "_" : Character(scalar)
        }
        let result = String(cleaned).trimmingCharacters(in: .whitespaces)
        if result.isEmpty || result == "." || result == ".." { return "untitled" }
        return String(result.prefix(200))
    }

    /// The directory a placement belongs in, or nil when it can't be placed.
    /// Where this photograph belongs, once per person entitled to see it.
    ///
    /// A shared space used to resolve to a single folder under the media share.
    /// It now resolves to one folder inside each member's home, which is the
    /// only arrangement where File Station tells members from non-members
    /// without anybody configuring an ACL — a home is already private, and a
    /// person who is not a member simply has no such folder.
    ///
    /// Personal photographs go under `Photos/Personal` and shared ones under
    /// `Photos/Shared/<Space>`, so one person opening their home sees
    /// everything they are entitled to in one tree, in two clearly named
    /// halves. Personal used to sit loose at the root of `Photos`;
    /// `BrowseTreeWorker.relocatePersonal` moves what was placed that way.
    static func destinations(
        for placement: Placement, configuration: Configuration
    ) -> [(path: String, recipient: Recipient)] {
        guard configuration.enabled else { return [] }

        let stamp = placement.capturedAt ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy"
        let year = formatter.string(from: stamp)
        formatter.dateFormat = "MM"
        let month = formatter.string(from: stamp)
        let file = fileName(for: placement)

        return placement.recipients.compactMap { recipient in
            // An invite-only account has no DSM home to write into, so there is
            // nowhere to put their copy. The others still get theirs.
            guard let user = recipient.dsmUsername, !user.isEmpty else { return nil }

            var parts = [configuration.homesRoot, sanitise(user), "Photos"]
            if placement.spaceKind == "shared" {
                parts.append("Shared")
                parts.append(sanitise(placement.spaceName))
            } else {
                parts.append("Personal")
            }
            parts.append(contentsOf: [year, month, file])
            return (parts.joined(separator: "/"), recipient)
        }
    }

    // MARK: - Linking

    /// Why a File Station copy couldn't be made.
    enum LinkError: Error, CustomStringConvertible {
        /// Neither a clone nor a hardlink is possible between the two.
        case unavailable(String)
        case rename(String, Int32)

        var description: String {
            switch self {
            case .unavailable(let path):
                return "can't clone or hardlink into \(path)"
            case .rename(let path, let code):
                return "can't move a new copy into place at \(path): \(String(cString: strerror(code)))"
            }
        }
    }

    /// Reflink, or hardlink where that's all the filesystem allows, and never a
    /// full copy.
    ///
    /// The file is made under a temporary name beside the destination, then
    /// renamed into place, so a failure leaves nothing at the real path. It
    /// used to leave an empty file: GNU `cp --reflink=always` creates its
    /// destination before cloning into it, the clone failed on the NAS (see
    /// `CloneRoute`), and the empty file was then counted as placed. Every
    /// File Station copy there was empty while `browse_entries` called it a
    /// reflink.
    ///
    /// There's no full-copy fallback. A copy of every shared photograph per
    /// member is hundreds of gigabytes nobody chose, and now that a failed
    /// clone no longer leaves an empty file behind, that fallback would have
    /// started running. A missing File Station copy is logged, and made once
    /// cloning works.
    @discardableResult
    static func link(
        from source: String, to destination: String,
        route: CloneRoute = CloneRoute(), logger: Logger
    ) async throws -> LinkKind {
        let manager = FileManager.default
        let folder = (destination as NSString).deletingLastPathComponent
        try manager.createDirectory(atPath: folder, withIntermediateDirectories: true)

        // Something already there was placed earlier or is somebody's edit in
        // File Station, and stays. The exception is an empty file standing in
        // for a photo that isn't empty, which only a failed clone ever made.
        let hollow = isHollow(destination, source: source)
        if !hollow, manager.fileExists(atPath: destination) { return .reflink }

        let temporary = "\(folder)/.framestation-\(UUID().uuidString).tmp"
        defer { try? manager.removeItem(atPath: temporary) }

        let kind: LinkKind
        if await route.clone(source, to: temporary) {
            kind = .reflink
        } else {
            // Whatever `cp` created before the clone failed.
            try? manager.removeItem(atPath: temporary)
            // Same subvolume after all, or a filesystem without CoW.
            guard (try? manager.linkItem(atPath: source, toPath: temporary)) != nil else {
                throw LinkError.unavailable(destination)
            }
            logger.notice("browse tree: hardlinked \(destination) — no reflink support")
            kind = .hardlink
        }

        if hollow {
            // Over the empty file in one step.
            guard rename(temporary, destination) == 0 else {
                throw LinkError.rename(destination, errno)
            }
        } else {
            do {
                try manager.moveItem(atPath: temporary, toPath: destination)
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                // Something arrived at the path in the meantime, and it stays.
                return .reflink
            }
        }
        return kind
    }

    /// An empty file at `path` standing in for a photo that isn't empty.
    static func isHollow(_ path: String, source: String) -> Bool {
        let manager = FileManager.default
        guard let size = (try? manager.attributesOfItem(atPath: path))?[.size] as? NSNumber,
              size.int64Value == 0,
              let sourceSize = (try? manager.attributesOfItem(atPath: source))?[.size] as? NSNumber
        else { return false }
        return sourceSize.int64Value > 0
    }

    /// Hands the file to its DSM owner so it is theirs in File Station, not
    /// root's. Without this the tree appears but nobody can edit it.
    static func chown(_ path: String, uid: Int, logger: Logger) async {
        guard uid > 0 else { return }
        guard let result = try? await Shell.run("chown", ["\(uid):users", path]),
              result.status == 0
        else {
            logger.warning("browse tree: could not chown \(path) — needs the container as root")
            return
        }
    }
}

/// Walks placements that have no tree entry yet and makes one.
///
/// Runs after derivation rather than at commit: the capture date decides the
/// YYYY/MM folder, and for a file whose EXIF the client never sent, that date
/// only exists once the media probe has read it.
actor BrowseTreeWorker {
    private let app: Application
    private let configuration: BrowseTree.Configuration
    private var task: Task<Void, Never>?
    /// Personal copies `relocatePersonal` found it couldn't move, such as one
    /// filed under a home the person's DSM name no longer matches. Left where
    /// they are, and not asked about again until the server restarts, so a
    /// few of them can't hold up the rest.
    private var unmovable: Set<UUID> = []
    private let route: CloneRoute
    /// Whether a File Station copy can be made here at all. Nil until checked.
    private var canLink: Bool?
    /// How far `refillHollow` has got through `browse_entries`, by id.
    private var refillCursor: UUID?
    /// Empty copies `refillHollow` couldn't refill, left until the server
    /// restarts so one failure doesn't repeat every sweep.
    private var unrefillable: Set<UUID> = []

    init(app: Application, configuration: BrowseTree.Configuration) {
        self.app = app
        self.configuration = configuration
        self.route = CloneRoute.fromEnvironment(
            blobRoot: app.blobStore.root.path, homesRoot: configuration.homesRoot
        )
    }

    func start() {
        guard configuration.enabled, task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sweep()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private struct Row: Decodable {
        let id: UUID
        let sha256: String
        let blobExt: String
        let filename: String?
        let capturedAt: Date?
        let spaceKind: String
        let spaceName: String
        let dsmUsername: String?
        let dsmUID: Int?
    }

    private struct RecipientRow: Decodable {
        let userID: UUID
        let dsmUsername: String?
        let dsmUID: Int?
    }

    /// Brings the tree back in line with the database.
    ///
    /// Deliberately a reconciler rather than a queue of things to do. A shared
    /// photograph belongs in one folder per member, and that set changes when
    /// people join and leave a space — so "what should exist" is a question
    /// with a current answer, and the only safe way to keep N trees correct is
    /// to ask it rather than to remember every event that ever changed it.
    ///
    /// It matters most in the direction nobody watches. A missed *addition* is
    /// a photograph somebody cannot see in File Station, which they will
    /// mention. A missed *removal* is a photograph somebody can still see after
    /// leaving the space, which nobody will mention at all. Recomputing catches
    /// both; an event queue only ever catches the first.
    ///
    /// Neither half throws: each logs its own failures and leaves what it
    /// couldn't do for the next sweep.
    private func sweep() async {
        let sql = app.sql
        await relocatePersonal(on: sql)
        if await linkingWorks() {
            await refillHollow(on: sql)
            await placeMissing(on: sql)
        }
        await removeStale(on: sql)
    }

    /// Proves one File Station copy can be made before trying hundreds.
    ///
    /// A small file in the blob store is linked into the homes root the way a
    /// photo would be, then both are removed. Until that works, nothing is
    /// placed or refilled, and one line in the log says why, instead of a
    /// failure per photo every sweep. It's checked each sweep until it works,
    /// then trusted, because what decides it (the mounts and the route) only
    /// changes with a restart. Relocation and withdrawal carry on regardless:
    /// a rename needs no clone, and removing a copy someone is no longer
    /// entitled to can't wait.
    private func linkingWorks() async -> Bool {
        if canLink == true { return true }

        let manager = FileManager.default
        let probe = app.blobStore.root
            .appendingPathComponent(".link-check-\(UUID().uuidString)").path
        let target = "\(configuration.homesRoot)/.framestation-link-check-\(UUID().uuidString)"
        defer {
            try? manager.removeItem(atPath: probe)
            try? manager.removeItem(atPath: target)
        }
        var works = false
        if manager.createFile(atPath: probe, contents: Data("FrameStation link check\n".utf8)) {
            works = (try? await BrowseTree.link(
                from: probe, to: target, route: route, logger: app.logger
            )) != nil
        }

        if works {
            app.logger.notice(canLink == false
                ? "browse tree: File Station copies can be made again"
                : "browse tree: File Station copies can be made here")
        } else if canLink != false {
            app.logger.error("""
                browse tree: can't clone or hardlink from the blob store into \
                \(configuration.homesRoot), so File Station copies are paused rather \
                than made as full copies. On a Synology, compose mounts the volume once \
                and sets FRAMESTATION_CLONE_BLOB_ROOT and FRAMESTATION_CLONE_HOMES_ROOT; \
                see DEPLOY.md.
                """)
        }
        canLink = works
        return works
    }

    /// Re-makes File Station copies that are empty files.
    ///
    /// Every copy on the NAS was one until clones went through a single mount
    /// (see `BrowseTree.link`). This walks every entry, 500 a sweep and then
    /// round again, and clones the photo over any empty file standing in for
    /// one that isn't. It keeps the same path and the same row. A copy
    /// somebody deleted stays deleted, and one with content is never touched.
    private func refillHollow(on sql: any SQLDatabase) async {
        struct Row: Decodable {
            let id: UUID
            let path: String
            let sha256: String
            let blobExt: String
            let dsmUID: Int?
        }
        do {
            let rows = try await sql.raw("""
                SELECT be.id, be.path, a.sha256, a.blob_ext AS "blobExt",
                       u.dsm_uid AS "dsmUID"
                FROM browse_entries be
                JOIN space_assets sa ON sa.id = be.space_asset_id
                JOIN assets a ON a.id = sa.asset_id
                JOIN users u ON u.id = be.user_id
                WHERE be.id > \(bind: refillCursor ?? Self.beforeEveryID)
                  AND sa.deleted_at IS NULL
                ORDER BY be.id
                LIMIT 500
                """).all(decoding: Row.self)
            refillCursor = rows.count < 500 ? nil : rows.last?.id

            var refilled = 0
            for row in rows where !unrefillable.contains(row.id) {
                let source = app.blobStore.blobPath(
                    sha256: row.sha256, fileExtension: row.blobExt
                ).path
                guard BrowseTree.isHollow(row.path, source: source) else { continue }
                do {
                    let kind = try await BrowseTree.link(
                        from: source, to: row.path, route: route, logger: app.logger
                    )
                    if let uid = row.dsmUID {
                        await BrowseTree.chown(row.path, uid: uid, logger: app.logger)
                    }
                    try await sql.raw("""
                        UPDATE browse_entries SET link_kind = \(bind: kind.rawValue)
                        WHERE id = \(bind: row.id)
                        """).run()
                    refilled += 1
                } catch {
                    unrefillable.insert(row.id)
                    app.logger.warning("browse tree: could not refill \(row.path): \(error)")
                }
            }
            if refilled > 0 {
                app.logger.info("browse tree: refilled \(refilled) empty File Station copies")
            }
        } catch {
            app.logger.error("browse tree refill failed: \(String(reflecting: error))")
        }
    }

    /// Sorts before every real id, to start a walk of `browse_entries`.
    private static let beforeEveryID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// Moves personal copies placed loose in `Photos/YYYY/MM` into
    /// `Photos/Personal/YYYY/MM`, where `destinations` now puts them.
    ///
    /// A rename, not a delete and re-link. It's instant on the same volume,
    /// keeps anything somebody edited in File Station (a reflink they wrote to
    /// is their own copy now), and there is never a moment when the photo
    /// isn't in the person's home. The canonical file in the blob store isn't
    /// touched.
    ///
    /// Safe to stop at any point. Each move is one rename and then one row,
    /// and a move whose row didn't get written is finished next sweep: the
    /// file is already at its new path, so only the row changes. A copy the
    /// person deleted themselves just has its row pointed at the new path,
    /// exactly as before, rather than being put back.
    ///
    /// Once a month's folder is empty it goes, then its year's, so `Photos`
    /// ends up holding Personal and Shared and nothing loose. See
    /// `removeEmptied`: a person's own files are never at risk. Nothing to do
    /// costs one indexed query a sweep.
    private func relocatePersonal(on sql: any SQLDatabase) async {
        struct Row: Decodable {
            let id: UUID
            let path: String
            let sha256: String
            let dsmUsername: String?
        }
        do {
            let rows = try await sql.raw("""
                SELECT be.id, be.path, a.sha256, u.dsm_username AS "dsmUsername"
                FROM browse_entries be
                JOIN space_assets sa ON sa.id = be.space_asset_id
                JOIN spaces s ON s.id = sa.space_id
                JOIN assets a ON a.id = sa.asset_id
                JOIN users u ON u.id = be.user_id
                WHERE s.kind = 'personal'
                  AND be.path NOT LIKE '%/Photos/Personal/%'
                  AND NOT (be.id = ANY(\(bind: Array(unmovable))::uuid[]))
                LIMIT 500
                """).all(decoding: Row.self)
            guard !rows.isEmpty else { return }

            let manager = FileManager.default
            var moved = 0
            // Each folder a copy left, with the `Photos` folder it is under.
            var emptied: [String: String] = [:]
            for row in rows {
                guard let user = row.dsmUsername, !user.isEmpty else {
                    unmovable.insert(row.id)
                    continue
                }
                let photos = "\(configuration.homesRoot)/\(BrowseTree.sanitise(user))/Photos"
                // Only a copy this layout put there: loose under the person's
                // own `Photos`. Anything else is left exactly where it is.
                guard row.path.hasPrefix(photos + "/") else {
                    unmovable.insert(row.id)
                    continue
                }
                let rest = String(row.path.dropFirst(photos.count + 1))
                guard !rest.hasPrefix("Shared/"), !rest.hasPrefix("Personal/") else {
                    unmovable.insert(row.id)
                    continue
                }
                var target = "\(photos)/Personal/\(rest)"

                if manager.fileExists(atPath: row.path) {
                    if manager.fileExists(atPath: target) {
                        target = Self.deduplicated(target, sha256: row.sha256)
                    }
                    try manager.createDirectory(
                        atPath: (target as NSString).deletingLastPathComponent,
                        withIntermediateDirectories: true
                    )
                    try manager.moveItem(atPath: row.path, toPath: target)
                    moved += 1
                    emptied[(row.path as NSString).deletingLastPathComponent] = photos
                }
                try await sql.raw("""
                    UPDATE browse_entries SET path = \(bind: target) WHERE id = \(bind: row.id)
                    """).run()
            }

            // Deepest first, so a month goes before its year.
            for (folder, photos) in emptied.sorted(by: { $0.key.count > $1.key.count }) {
                Self.removeEmptied(folder, under: photos)
            }
            if moved > 0 {
                app.logger.info("browse tree: moved \(moved) personal photos into Photos/Personal")
            }
        } catch {
            app.logger.error("browse tree relocation failed: \(String(reflecting: error))")
        }
    }

    /// Removes a folder the move left empty, then its parent, and so on up
    /// to, but never including, the person's `Photos` folder.
    ///
    /// "Empty" allows for what Synology leaves behind: its indexing writes an
    /// `@eaDir` thumbnail cache into every folder it has seen, describing
    /// files that are no longer there once they've moved. Anything else in a
    /// folder (a person's own file, a folder of their own) means it stays,
    /// and `rmdir` refuses a folder that still holds anything.
    static func removeEmptied(_ folder: String, under photos: String) {
        let manager = FileManager.default
        let leftovers: Set<String> = ["@eaDir", ".DS_Store"]
        var current = folder
        while current.hasPrefix(photos + "/") {
            guard let contents = try? manager.contentsOfDirectory(atPath: current),
                  contents.allSatisfy(leftovers.contains)
            else { return }
            for item in contents {
                try? manager.removeItem(atPath: "\(current)/\(item)")
            }
            guard rmdir(current) == 0 else { return }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    /// Placements that somebody entitled to see them has no copy of.
    private func placeMissing(on sql: any SQLDatabase) async {
        do {
            let rows = try await sql.raw("""
                SELECT sa.id, a.sha256, a.blob_ext AS "blobExt", sa.filename,
                       a.captured_at AS "capturedAt",
                       s.kind AS "spaceKind", s.name AS "spaceName"
                FROM space_assets sa
                JOIN assets a ON a.id = sa.asset_id
                JOIN spaces s ON s.id = sa.space_id
                WHERE sa.browse_error IS NULL
                  AND sa.deleted_at IS NULL
                  AND a.derived_at IS NOT NULL
                  AND EXISTS (
                      -- Somebody who should have a copy and hasn't got one.
                      SELECT 1 FROM space_members m
                      WHERE m.space_id = sa.space_id
                        AND NOT EXISTS (
                            SELECT 1 FROM browse_entries be
                            WHERE be.space_asset_id = sa.id AND be.user_id = m.user_id
                        )
                  )
                ORDER BY sa.uploaded_at
                LIMIT 100
                """).all(decoding: Row.self)

            for row in rows { await place(row, on: sql) }
        } catch {
            app.logger.error("browse tree placement failed: \(String(reflecting: error))")
        }
    }

    /// Copies belonging to people who are no longer entitled to them.
    ///
    /// This is the half that makes the whole arrangement a permission boundary
    /// rather than a convenience. Removing somebody from a shared space has to
    /// take the photographs out of their home, or they keep reading a library
    /// they were removed from and the app's membership list becomes decorative.
    private func removeStale(on sql: any SQLDatabase) async {
        struct StaleRow: Decodable {
            let id: UUID
            let path: String
        }
        do {
            let rows = try await sql.raw("""
                SELECT be.id, be.path
                FROM browse_entries be
                JOIN space_assets sa ON sa.id = be.space_asset_id
                WHERE sa.deleted_at IS NOT NULL
                   OR NOT EXISTS (
                       SELECT 1 FROM space_members m
                       WHERE m.space_id = sa.space_id AND m.user_id = be.user_id
                   )
                LIMIT 200
                """).all(decoding: StaleRow.self)

            for row in rows {
                // Unlinked rather than recycled. It is one of several names for
                // the same extents — the blob store still holds the file, and
                // the person's own recycle bin is the wrong place for something
                // they were never entitled to keep.
                try? FileManager.default.removeItem(atPath: row.path)
                try? await sql.raw("""
                    DELETE FROM browse_entries WHERE id = \(bind: row.id)
                    """).run()
            }
            if !rows.isEmpty {
                app.logger.info("browse tree: withdrew \(rows.count) entries")
            }
        } catch {
            app.logger.error("browse tree withdrawal failed: \(String(reflecting: error))")
        }
    }

    private func place(_ row: Row, on sql: any SQLDatabase) async {
        let recipients: [BrowseTree.Recipient]
        do {
            recipients = try await sql.raw("""
                SELECT m.user_id AS "userID",
                       u.dsm_username AS "dsmUsername", u.dsm_uid AS "dsmUID"
                FROM space_members m
                JOIN users u ON u.id = m.user_id
                JOIN space_assets sa ON sa.space_id = m.space_id
                WHERE sa.id = \(bind: row.id)
                  AND NOT EXISTS (
                      SELECT 1 FROM browse_entries be
                      WHERE be.space_asset_id = sa.id AND be.user_id = m.user_id
                  )
                """).all(decoding: RecipientRow.self).map {
                    BrowseTree.Recipient(
                        userID: $0.userID, dsmUsername: $0.dsmUsername, dsmUID: $0.dsmUID
                    )
                }
        } catch {
            try? await note(error: error.localizedDescription, for: row.id, on: sql)
            return
        }

        let placement = BrowseTree.Placement(
            id: row.id, sha256: row.sha256, blobExt: row.blobExt, filename: row.filename,
            capturedAt: row.capturedAt, spaceKind: row.spaceKind, spaceName: row.spaceName,
            recipients: recipients
        )

        let wanted = BrowseTree.destinations(for: placement, configuration: configuration)
        guard !wanted.isEmpty else {
            // Every recipient is an invite-only account with no DSM home to
            // write into. Recorded so the sweep stops reconsidering it every
            // twenty seconds.
            try? await note(
                error: "no DSM account linked — sign in with DSM to get a File Station tree",
                for: row.id, on: sql
            )
            return
        }

        let source = app.blobStore.blobPath(sha256: row.sha256, fileExtension: row.blobExt)

        for (intended, recipient) in wanted {
            do {
                // Two different photos can share a filename — every phone starts
                // at IMG_0001. Suffix rather than overwrite.
                let destination = Self.deduplicated(intended, sha256: row.sha256)
                let kind = try await BrowseTree.link(
                    from: source.path, to: destination, route: route, logger: app.logger
                )
                if let uid = recipient.dsmUID {
                    await BrowseTree.chown(destination, uid: uid, logger: app.logger)
                }
                try await sql.raw("""
                    INSERT INTO browse_entries (space_asset_id, user_id, path, link_kind)
                    VALUES (\(bind: row.id), \(bind: recipient.userID),
                            \(bind: destination), \(bind: kind.rawValue))
                    ON CONFLICT (space_asset_id, user_id) DO NOTHING
                    """).run()
                app.logger.debug("browse tree: \(kind.rawValue) \(destination)")
            } catch {
                // One recipient failing must not cost the others theirs.
                app.logger.warning(
                    "browse tree: could not place for \(recipient.dsmUsername ?? "?"): \(error)"
                )
            }
        }
    }

    /// `IMG_0001.jpg` → `IMG_0001-3f2a1c.jpg` when the name is already taken by
    /// different bytes.
    static func deduplicated(_ path: String, sha256: String) -> String {
        guard FileManager.default.fileExists(atPath: path) else { return path }
        let base = (path as NSString).deletingPathExtension
        let ext = (path as NSString).pathExtension
        let suffix = sha256.prefix(6)
        return ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
    }

    private func note(error: String, for id: UUID, on sql: any SQLDatabase) async throws {
        try await sql.raw("""
            UPDATE space_assets SET browse_error = \(bind: error) WHERE id = \(bind: id)
            """).run()
    }
}

struct BrowseTreeWorkerKey: StorageKey {
    typealias Value = BrowseTreeWorker
}
