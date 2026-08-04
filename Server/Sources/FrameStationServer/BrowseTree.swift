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
    static func destination(
        for placement: Placement, configuration: Configuration
    ) -> String? {
        guard configuration.enabled else { return nil }
        guard let directory = directory(for: placement, configuration: configuration) else {
            return nil
        }
        return "\(directory)/\(fileName(for: placement))"
    }

    struct Configuration {
        /// Where DSM keeps user home directories.
        var homesRoot: String
        /// Where shared-space trees go.
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

    struct Placement {
        let id: UUID
        let sha256: String
        let blobExt: String
        let filename: String?
        let capturedAt: Date?
        let spaceKind: String
        let spaceName: String
        let deviceName: String?
        let dsmUsername: String?
        let dsmUID: Int?
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
    static func directory(
        for placement: Placement, configuration: Configuration
    ) -> String? {
        let stamp = placement.capturedAt ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy"
        let year = formatter.string(from: stamp)
        formatter.dateFormat = "MM"
        let month = formatter.string(from: stamp)

        if placement.spaceKind == "shared" {
            return [
                configuration.sharedRoot, sanitise(placement.spaceName), year, month,
            ].joined(separator: "/")
        }

        // Personal photos land in that person's DSM home, which is the whole
        // point: they open File Station and see their own library.
        guard let user = placement.dsmUsername, !user.isEmpty else { return nil }
        let device = sanitise(placement.deviceName ?? "Device")
        return [
            configuration.homesRoot, sanitise(user), "Photos", "MobileBackup",
            device, year, month,
        ].joined(separator: "/")
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
        let deviceName: String?
        let dsmUsername: String?
        let dsmUID: Int?
    }

    private func sweep() async {
        do {
            let sql = app.sql
            let rows = try await sql.raw("""
                SELECT sa.id, a.sha256, a.blob_ext AS "blobExt", sa.filename,
                       a.captured_at AS "capturedAt",
                       s.kind AS "spaceKind", s.name AS "spaceName",
                       d.name AS "deviceName",
                       u.dsm_username AS "dsmUsername", u.dsm_uid AS "dsmUID"
                FROM space_assets sa
                JOIN assets a ON a.id = sa.asset_id
                JOIN spaces s ON s.id = sa.space_id
                JOIN users u ON u.id = sa.uploaded_by_user_id
                LEFT JOIN devices d ON d.id = sa.source_device_id
                WHERE sa.browse_path IS NULL
                  AND sa.browse_error IS NULL
                  AND sa.deleted_at IS NULL
                  AND a.derived_at IS NOT NULL
                ORDER BY sa.uploaded_at
                LIMIT 200
                """).all(decoding: Row.self)

            for row in rows { await place(row, on: sql) }
        } catch {
            app.logger.error("browse tree sweep failed: \(String(reflecting: error))")
        }
    }

    private func place(_ row: Row, on sql: any SQLDatabase) async {
        let placement = BrowseTree.Placement(
            id: row.id, sha256: row.sha256, blobExt: row.blobExt, filename: row.filename,
            capturedAt: row.capturedAt, spaceKind: row.spaceKind, spaceName: row.spaceName,
            deviceName: row.deviceName, dsmUsername: row.dsmUsername, dsmUID: row.dsmUID
        )

        guard let directory = BrowseTree.directory(
            for: placement, configuration: configuration
        ) else {
            // An invite-only account has no DSM home to write into. Recorded so
            // the sweep stops reconsidering it every 20 seconds.
            try? await note(
                error: "no DSM account linked — sign in with DSM to get a File Station tree",
                for: row.id, on: sql
            )
            return
        }

        let source = app.blobStore.blobPath(sha256: row.sha256, fileExtension: row.blobExt)
        var destination = "\(directory)/\(BrowseTree.fileName(for: placement))"

        do {
            // Two different photos can share a filename — every phone starts at
            // IMG_0001. Suffix rather than overwrite.
            destination = Self.deduplicated(destination, sha256: row.sha256)
            let kind = try await BrowseTree.link(
                from: source.path, to: destination, logger: app.logger
            )
            if let uid = row.dsmUID {
                await BrowseTree.chown(destination, uid: uid, logger: app.logger)
            }
            try await sql.raw("""
                UPDATE space_assets SET browse_path = \(bind: destination)
                WHERE id = \(bind: row.id)
                """).run()
            app.logger.debug("browse tree: \(kind.rawValue) \(destination)")
        } catch {
            try? await note(error: error.localizedDescription, for: row.id, on: sql)
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
