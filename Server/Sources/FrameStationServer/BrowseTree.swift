import Foundation
import FrameStationAPI
import SQLKit
import Vapor

/// Builds the human-readable tree people actually browse in File Station.
///
/// The blob store is named by hash — correct for storage, meaningless to
/// someone opening a folder. This mirrors every placement to a path built from
/// who it belongs to and when it was taken:
///
///   /volume1/homes/<dsm user>/Photos/MobileBackup/<device>/YYYY/MM/IMG_4821.heic
///   /volume1/FrameStation/Shared/<Space>/YYYY/MM/IMG_4821.heic
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

    /// How the copy was actually made. Recorded because a silent fallback to a
    /// full copy would double disk usage without anyone noticing.
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
    /// Personal photographs keep their existing shape at the root of `Photos`;
    /// shared ones sit under `Photos/Shared/<Space>` beside them, so one person
    /// opening their home sees everything they are entitled to in one tree.
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
            }
            parts.append(contentsOf: [year, month, file])
            return (parts.joined(separator: "/"), recipient)
        }
    }

    // MARK: - Linking

    /// Reflink, falling back only as far as the filesystem forces.
    ///
    /// Reported rather than silent: a fallback to `copy` means the tree is
    /// costing real disk space, which is worth knowing before it fills a volume.
    @discardableResult
    static func link(
        from source: String, to destination: String, logger: Logger
    ) async throws -> LinkKind {
        let manager = FileManager.default
        try manager.createDirectory(
            atPath: (destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        if manager.fileExists(atPath: destination) { return .reflink }

        // macOS clonefile and Linux --reflink spell this differently.
        #if os(macOS)
        let reflinkArguments = ["-c", source, destination]
        #else
        let reflinkArguments = ["--reflink=always", source, destination]
        #endif
        if let result = try? await Shell.run("cp", reflinkArguments), result.status == 0 {
            return .reflink
        }

        // Same subvolume after all, or a filesystem without CoW.
        if (try? manager.linkItem(atPath: source, toPath: destination)) != nil {
            logger.notice("browse tree: hardlinked \(destination) — no reflink support")
            return .hardlink
        }

        try manager.copyItem(atPath: source, toPath: destination)
        logger.warning(
            "browse tree: copied \(destination) — this duplicates the file on disk"
        )
        return .copy
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

    init(app: Application, configuration: BrowseTree.Configuration) {
        self.app = app
        self.configuration = configuration
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
    private func sweep() async {
        do {
            let sql = app.sql
            await placeMissing(on: sql)
            await removeStale(on: sql)
        } catch {
            app.logger.error("browse tree sweep failed: \(String(reflecting: error))")
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
                    from: source.path, to: destination, logger: app.logger
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
