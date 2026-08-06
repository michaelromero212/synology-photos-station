import FrameStationAPI
import Foundation
import SQLKit
import Vapor

/// `FrameStationServer rebuild` — reconstructs the index from the files.
///
/// Step four of ARCHITECTURE.md §3a, and the one that makes the other three
/// mean anything. The decision says the files are canonical and the database is
/// an index; until the index can actually be rebuilt from the files that is a
/// claim, not a property. This command is the proof, and it is meant to be run
/// for real after a `pgdata` loss.
///
/// It reads the layout the library already writes:
///
///     <homes>/<dsm user>/Photos/MobileBackup/<device>/YYYY/MM/IMG_4821.heic
///     <shared>/<Space>/YYYY/MM/IMG_9001.jpg
///
/// and turns it back into users, libraries, assets and placements. Nothing is
/// copied or moved: `storage_path` points at the file where it already lies.
///
/// ## What comes back, and what does not
///
/// The photos come back, with their EXIF, dates, places, dimensions and
/// attribution-by-folder. Everything a person typed does not: favourites,
/// ratings, tags, captions and albums live only in the database, and a folder
/// has nowhere to keep them. That is a real limit of the design and this
/// command says so out loud rather than implying a clean recovery.
struct RebuildCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "homes", help: "DSM home directories (default $FRAMESTATION_HOMES_ROOT or /volume1/homes)")
        var homes: String?

        @Option(name: "shared", help: "Shared library root (default $FRAMESTATION_SHARED_ROOT)")
        var shared: String?

        @Option(name: "owner", help: "DSM username to own rebuilt shared libraries (default: the first user found)")
        var owner: String?

        @Option(name: "concurrency", short: "c", help: "Parallel hash workers (default 4)")
        var concurrency: Int?

        @Option(name: "batch", short: "b", help: "Files per exiftool invocation (default 64)")
        var batch: Int?

        @Flag(name: "dry-run", help: "Report what would be indexed without writing anything")
        var dryRun: Bool
    }

    var help: String { "Rebuild the database index by scanning the library folders." }

    // MARK: - What a path says about a file

    /// Reconciles a probed capture date against the folder the file is in.
    ///
    /// This is what makes a corrected date survive a rebuild. Re-dating a photo
    /// moves it into the folder for its new month but never rewrites its EXIF —
    /// the bytes are the asset's identity — so a rebuild that trusted EXIF alone
    /// would quietly undo every correction anyone had ever made, and put the
    /// timeline back at odds with File Station.
    ///
    /// The folder wins on year and month; the time of day still comes from the
    /// file, because the path never carried it. A correction inside the same
    /// month is the one case this cannot recover, and it is the cheap one to
    /// redo. Paths that aren't a `YYYY/MM` pair are left entirely alone.
    static func reconciledCaptureDate(probed: Date?, path: URL) -> Date? {
        guard let probed else { return nil }

        let month = path.deletingLastPathComponent()
        let year = month.deletingLastPathComponent()
        guard let folderYear = Int(year.lastPathComponent),
              year.lastPathComponent.count == 4,
              let folderMonth = Int(month.lastPathComponent),
              month.lastPathComponent.count == 2,
              (1...12).contains(folderMonth) else { return probed }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: probed
        )
        guard parts.year != folderYear || parts.month != folderMonth else { return probed }

        parts.year = folderYear
        parts.month = folderMonth
        // The day may not exist in the target month — the 31st moved into
        // February — so clamp rather than letting the date roll into March.
        if let day = parts.day {
            let target = DateComponents(year: folderYear, month: folderMonth)
            if let monthStart = calendar.date(from: target),
               let range = calendar.range(of: .day, in: .month, for: monthStart) {
                parts.day = min(day, range.upperBound - 1)
            }
        }
        return calendar.date(from: parts) ?? probed
    }

    /// Where a file sits in the library, as read from its path alone.
    enum Home: Hashable {
        /// `<homes>/<user>/Photos/MobileBackup/<device>/…`
        case personal(user: String, device: String?)
        /// `<shared>/<Space>/…`
        case shared(space: String)
    }

    private struct Found {
        let candidate: LibraryScanner.Candidate
        let home: Home
    }

    private struct IDRow: Decodable { let id: UUID }
    private struct NameRow: Decodable { let name: String }

    // MARK: - Run

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let console = context.console

        let configuration = BrowseTree.Configuration.fromEnvironment()
        let homesRoot = signature.homes ?? configuration.homesRoot
        let sharedRoot = signature.shared ?? configuration.sharedRoot
        let concurrency = max(1, signature.concurrency ?? 4)
        let batchSize = max(1, signature.batch ?? 64)

        let missing = Derivatives.missingTools()
        guard missing.isEmpty else {
            throw Abort(.internalServerError,
                        reason: "Missing media tools: \(missing.joined(separator: ", "))")
        }

        // ---------------------------------------------------------------- scan
        console.info("Scanning \(homesRoot) and \(sharedRoot)…")
        var found = try Self.scanHomes(homesRoot, logger: app.logger)
        found += try Self.scanShared(sharedRoot, logger: app.logger)

        guard !found.isEmpty else {
            console.warning("No library files found under \(homesRoot) or \(sharedRoot).")
            console.warning("Check the roots — an empty scan would otherwise look like an empty library.")
            return
        }

        // Already indexed: the same file at the same path. Makes a re-run after
        // an interrupted rebuild resume rather than start over, and makes
        // running this against a live database a no-op for everything it
        // already knows.
        struct PathRow: Decodable { let storagePath: String }
        let indexed = Set(
            try await app.sql.raw("""
                SELECT storage_path AS "storagePath" FROM assets
                WHERE storage_path IS NOT NULL
                """).all(decoding: PathRow.self).map(\.storagePath)
        )
        let pending = found.filter { !indexed.contains($0.candidate.url.path) }

        let people = Set(found.compactMap { item -> String? in
            if case .personal(let user, _) = item.home { return user }
            return nil
        }).sorted()
        let sharedLibraries = Set(found.compactMap { item -> String? in
            if case .shared(let space) = item.home { return space }
            return nil
        }).sorted()

        console.info("")
        console.info("  Found:         \(found.count) files")
        console.info("  Already known: \(found.count - pending.count)")
        console.info("  To index:      \(pending.count) (\(ImportCommand.humanBytes(pending.reduce(Int64(0)) { $0 + $1.candidate.byteSize })))")
        console.info("  People:        \(people.isEmpty ? "—" : people.joined(separator: ", "))")
        console.info("  Shared:        \(sharedLibraries.isEmpty ? "—" : sharedLibraries.joined(separator: ", "))")
        console.info("")

        if signature.dryRun {
            console.info("Dry run — nothing written.")
            return
        }
        guard !pending.isEmpty else {
            console.info("Nothing to do — every file on disk is already indexed.")
            return
        }

        // ------------------------------------------------------------ accounts
        // Users and libraries first, so a file never has to invent its own
        // owner halfway through the walk.
        var users: [String: UUID] = [:]
        for person in people {
            users[person] = try await resolveUser(dsmUsername: person, on: app.sql)
        }

        var spaces: [Home: UUID] = [:]
        for person in people {
            guard let userID = users[person] else { continue }
            spaces[.personal(user: person, device: nil)] =
                try await resolvePersonalSpace(of: userID, on: app.sql)
        }

        // A shared folder names the library but nobody in it, so somebody has
        // to be named here. Resolved once rather than per file, so every
        // placement in a rebuilt shared library is attributed consistently
        // instead of to whichever account happened to sort first.
        var sharedOwnerID: UUID?
        if !sharedLibraries.isEmpty {
            if let requested = signature.owner {
                sharedOwnerID = try await resolveUser(dsmUsername: requested, on: app.sql)
            } else {
                sharedOwnerID = people.first.flatMap { users[$0] }
            }
            guard let sharedOwnerID else {
                throw Abort(.badRequest, reason:
                    "Shared libraries were found but there is nobody to own them — "
                    + "no home directories were scanned. Pass --owner <dsm username>.")
            }
            for library in sharedLibraries {
                spaces[.shared(space: library)] =
                    try await resolveSharedSpace(named: library, owner: sharedOwnerID, on: app.sql)
            }
        }

        // Both halves of a Live Photo sit in the same folder, but a batch
        // boundary could still fall between them — paired over everything
        // pending, once.
        let liveGroups = LibraryScanner.liveGroups(pending.map(\.candidate))

        // --------------------------------------------------------------- index
        let started = Date()
        var indexedCount = 0, failed = 0
        var bytesDone: Int64 = 0

        for chunk in stride(from: 0, to: pending.count, by: batchSize).map({
            Array(pending[$0..<min($0 + batchSize, pending.count)])
        }) {
            let hashes = await Self.hashes(of: chunk.map(\.candidate), concurrency: concurrency)
            let photos = chunk.filter { $0.candidate.mediaType == .photo }.map(\.candidate.url)
            let photoMetadata = (try? await MediaProbe.probePhotoBatch(photos)) ?? [:]

            for item in chunk {
                let path = item.candidate.url.path
                guard let sha = hashes[path] else {
                    failed += 1
                    app.logger.error("rebuild: could not hash \(path)")
                    continue
                }
                guard let spaceID = spaces[Self.spaceKey(item.home)],
                      let userID = Self.userID(
                          for: item.home, sharedOwner: sharedOwnerID, in: users
                      ) else {
                    failed += 1
                    app.logger.error("rebuild: no library for \(path)")
                    continue
                }

                do {
                    var metadata = item.candidate.mediaType == .photo
                        ? (photoMetadata[path] ?? MediaProbe.Metadata())
                        : try await MediaProbe.probe(url: item.candidate.url, mediaType: .video)
                    // A file with no EXIF date still has to land somewhere in
                    // the timeline, and its mtime is the best evidence left.
                    if metadata.capturedAt == nil { metadata.capturedAt = item.candidate.modifiedAt }
                    metadata.capturedAt = Self.reconciledCaptureDate(
                        probed: metadata.capturedAt, path: item.candidate.url
                    )

                    try await index(
                        item, sha: sha, metadata: metadata,
                        liveGroupID: liveGroups[path],
                        spaceID: spaceID, userID: userID, app: app
                    )
                    indexedCount += 1
                    bytesDone += item.candidate.byteSize
                } catch {
                    failed += 1
                    app.logger.error("rebuild failed for \(path): \(String(reflecting: error))")
                }
            }

            let done = indexedCount + failed
            let elapsed = Date().timeIntervalSince(started)
            let rate = elapsed > 0 ? Double(done) / elapsed : 0
            console.info(
                "  \(done)/\(pending.count)  \(ImportCommand.humanBytes(bytesDone))  "
                + String(format: "%.1f files/s  ", rate)
                + "eta \(ImportCommand.humanDuration(rate > 0 ? Double(pending.count - done) / rate : 0))"
            )
        }

        // ------------------------------------------------------------- summary
        console.info("")
        console.info("  Indexed: \(indexedCount)")
        console.info("  Failed:  \(failed)")
        console.info("  Elapsed: \(ImportCommand.humanDuration(Date().timeIntervalSince(started)))")
        console.info("")
        console.info("Thumbnails are queued; the derivation worker draws them down in the background.")
        console.info("")
        // Said plainly, because the alternative is someone assuming a clean
        // recovery and only noticing months later that the albums never
        // came back.
        console.warning("Rebuilt from files alone. These were never on disk and are gone:")
        console.warning("  favourites, ratings, tags, captions, albums, and per-photo attribution")
        console.warning("  in shared libraries. Photo ids changed, so every app will refetch.")
        if !sharedLibraries.isEmpty {
            console.warning("Shared libraries came back with one member — their owner. Re-add")
            console.warning("  everyone else in the app, or nobody else can see them.")
        }
        console.info("")
        console.info("People sign in with DSM as usual; their accounts are already here waiting.")
    }

    // MARK: - Scanning

    /// Walks `<homes>/*/Photos`, and nothing else under a home.
    ///
    /// Scoped to `Photos` deliberately. A home directory holds a person's
    /// documents and downloads too, and a photo attached to an email is not a
    /// library file — walking the whole home would claim it as one.
    ///
    /// Scoped no *further* than `Photos`, equally deliberately. Synology put
    /// phone backups in `MobileBackup/<device>/` and web uploads in
    /// `PhotoLibrary/`, so a scan of only the former silently leaves the latter
    /// behind — and someone whose photos all arrived through the browser would
    /// have been skipped entirely. Everything under `Photos` is the library,
    /// wherever a previous app chose to file it.
    private static func scanHomes(_ root: String, logger: Logger) throws -> [Found] {
        let manager = FileManager.default
        guard let people = try? manager.contentsOfDirectory(atPath: root) else {
            logger.notice("rebuild: no homes at \(root)")
            return []
        }

        var found: [Found] = []
        for person in people.sorted() {
            guard !person.hasPrefix("@"), !person.hasPrefix(".") else { continue }
            let photos = "\(root)/\(person)/Photos"
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: photos, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let candidates = try LibraryScanner.scan(
                root: URL(fileURLWithPath: photos, isDirectory: true), logger: logger
            )
            found += candidates.map {
                Found(
                    candidate: $0,
                    home: .personal(
                        user: person,
                        device: legacyDevice(of: $0.url.path, under: photos)
                    )
                )
            }
        }
        return found
    }

    /// The device a legacy `MobileBackup/<device>/…` path names, if any.
    ///
    /// Only meaningful for files Synology filed. Anything under `PhotoLibrary/`
    /// came from a browser and names no device, and anything written since the
    /// layout was flattened sits at `Photos/YYYY/MM/` and names none either —
    /// which is correct. The device belongs in `space_assets.source_device_id`,
    /// not in a path.
    static func legacyDevice(of path: String, under photos: String) -> String? {
        let parts = relative(path, to: photos)
        guard parts.count >= 3, parts[0] == "MobileBackup" else { return nil }
        return parts[1]
    }

    /// Walks `<shared>/<Space>`, one library per top-level folder.
    private static func scanShared(_ root: String, logger: Logger) throws -> [Found] {
        let manager = FileManager.default
        guard let libraries = try? manager.contentsOfDirectory(atPath: root) else {
            logger.notice("rebuild: no shared libraries at \(root)")
            return []
        }

        var found: [Found] = []
        for library in libraries.sorted() {
            guard !library.hasPrefix("@"), !library.hasPrefix(".") else { continue }
            guard !LibraryScanner.excludedDirectories.contains(library) else { continue }
            let path = "\(root)/\(library)"
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let candidates = try LibraryScanner.scan(
                root: URL(fileURLWithPath: path, isDirectory: true), logger: logger
            )
            found += candidates.map { Found(candidate: $0, home: .shared(space: library)) }
        }
        return found
    }

    /// Path components below `root`, e.g. `["iPhone", "2026", "07", "IMG.heic"]`.
    static func relative(_ path: String, to root: String) -> [String] {
        let root = root.hasSuffix("/") ? String(root.dropLast()) : root
        guard path.hasPrefix(root + "/") else { return [] }
        return path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
    }

    private static func hashes(
        of candidates: [LibraryScanner.Candidate], concurrency: Int
    ) async -> [String: String] {
        var digests: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            var running = 0
            var index = 0
            while index < candidates.count || running > 0 {
                while running < concurrency, index < candidates.count {
                    let candidate = candidates[index]
                    index += 1
                    running += 1
                    group.addTask {
                        (candidate.url.path, try? LibraryScanner.hash(candidate.url))
                    }
                }
                if let (path, digest) = await group.next() {
                    running -= 1
                    if let digest { digests[path] = digest }
                }
            }
        }
        return digests
    }

    // MARK: - Accounts

    /// The device folder is part of the path but not of the library's identity,
    /// so it is dropped when looking a space up.
    private static func spaceKey(_ home: Home) -> Home {
        switch home {
        case .personal(let user, _): return .personal(user: user, device: nil)
        case .shared: return home
        }
    }

    /// Who a placement is attributed to. A home directory names its person; a
    /// shared folder names nobody, so those go to the library's owner.
    private static func userID(
        for home: Home, sharedOwner: UUID?, in users: [String: UUID]
    ) -> UUID? {
        switch home {
        case .personal(let user, _): return users[user]
        case .shared: return sharedOwner
        }
    }

    private func existingUser(dsmUsername: String, on sql: any SQLDatabase) async throws -> UUID? {
        try await sql.raw("""
            SELECT id FROM users WHERE lower(dsm_username) = lower(\(bind: dsmUsername))
            """).first(decoding: IDRow.self)?.id
    }

    /// Recreates the account, keyed on the DSM username the folder is named
    /// after. Matched case-insensitively for the same reason sign-in is: DSM
    /// treats usernames that way, and a second row for the same person would
    /// split their library in half.
    ///
    /// `dsm_uid` and `dsm_home` stay NULL until they sign in — those come from
    /// DSM, not from a folder name — and sign-in adopts this row rather than
    /// making another.
    private func resolveUser(dsmUsername: String, on sql: any SQLDatabase) async throws -> UUID {
        if let existing = try await existingUser(dsmUsername: dsmUsername, on: sql) {
            return existing
        }
        guard let created = try await sql.raw("""
            INSERT INTO users (display_name, dsm_username)
            VALUES (\(bind: dsmUsername), \(bind: dsmUsername))
            RETURNING id
            """).first(decoding: IDRow.self) else {
            throw Abort(.internalServerError, reason: "Could not recreate the account \(dsmUsername).")
        }
        return created.id
    }

    private func resolvePersonalSpace(of userID: UUID, on sql: any SQLDatabase) async throws -> UUID {
        if let existing = try await sql.raw("""
            SELECT id FROM spaces WHERE kind = 'personal' AND created_by = \(bind: userID)
            """).first(decoding: IDRow.self) {
            return existing.id
        }
        guard let created = try await sql.raw("""
            INSERT INTO spaces (kind, name, created_by)
            VALUES ('personal', 'Personal Space', \(bind: userID))
            RETURNING id
            """).first(decoding: IDRow.self) else {
            throw Abort(.internalServerError, reason: "Could not recreate a personal library.")
        }
        try await sql.raw("""
            INSERT INTO space_members (space_id, user_id, role)
            VALUES (\(bind: created.id), \(bind: userID), 'owner')
            ON CONFLICT DO NOTHING
            """).run()
        return created.id
    }

    /// Membership is deliberately not guessed.
    ///
    /// The folder says a shared library exists and what it is called; it does
    /// not say who was in it. Adding everyone with a home would be the friendly
    /// guess and the wrong one — it hands a family member a library they may
    /// never have been in. One member, and a loud line in the summary.
    private func resolveSharedSpace(
        named name: String, owner: UUID, on sql: any SQLDatabase
    ) async throws -> UUID {
        if let existing = try await sql.raw("""
            SELECT id FROM spaces WHERE kind = 'shared' AND name = \(bind: name)
            """).first(decoding: IDRow.self) {
            return existing.id
        }
        guard let created = try await sql.raw("""
            INSERT INTO spaces (kind, name, created_by)
            VALUES ('shared', \(bind: name), \(bind: owner))
            RETURNING id
            """).first(decoding: IDRow.self) else {
            throw Abort(.internalServerError, reason: "Could not recreate the library \(name).")
        }
        try await sql.raw("""
            INSERT INTO space_members (space_id, user_id, role)
            VALUES (\(bind: created.id), \(bind: owner), 'owner')
            ON CONFLICT DO NOTHING
            """).run()
        return created.id
    }

    // MARK: - Indexing one file

    private func index(
        _ item: Found,
        sha: String,
        metadata: MediaProbe.Metadata,
        liveGroupID: UUID?,
        spaceID: UUID,
        userID: UUID,
        app: Application
    ) async throws {
        let candidate = item.candidate
        let path = candidate.url.path
        let filename = candidate.url.lastPathComponent

        try await app.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                // One row per file, not per hash. Two people holding the same
                // photo is two files under §3a, and collapsing them here would
                // put one person's copy in the other person's library.
                guard let asset = try await sql.raw("""
                    INSERT INTO assets
                        (sha256, byte_size, media_type, mime, blob_ext, is_raw,
                         live_group_id, storage_path)
                    VALUES
                        (\(bind: sha), \(bind: candidate.byteSize),
                         \(bind: candidate.mediaType.rawValue),
                         \(bind: metadata.mime ?? candidate.mime),
                         \(bind: BlobStore.fileExtension(for: filename)),
                         \(bind: metadata.isRaw), \(bind: liveGroupID), \(bind: path))
                    RETURNING id
                    """).first(decoding: IDRow.self) else {
                    throw Abort(.internalServerError, reason: "asset insert returned nothing")
                }

                // The same call commit uses, so a rebuilt row is populated the
                // way an uploaded one is — including reverse geocoding and the
                // local capture time the timeline buckets on.
                try await DerivationWorker.applyMetadata(
                    metadata, assetID: asset.id, on: sql, geocoder: app.geocoder
                )

                // browse_path is the file itself. Left NULL, the browse-tree
                // worker would try to link a second copy out of a blob store
                // that has nothing in it.
                guard let placement = try await sql.raw("""
                    INSERT INTO space_assets
                        (space_id, asset_id, uploaded_by_user_id, filename,
                         on_device, browse_path)
                    VALUES (\(bind: spaceID), \(bind: asset.id), \(bind: userID),
                            \(bind: filename), false, \(bind: path))
                    RETURNING id
                    """).first(decoding: IDRow.self) else {
                    throw Abort(.internalServerError, reason: "placement insert returned nothing")
                }

                _ = try await ChangeLog.append(
                    spaceID: spaceID, entity: "space_asset",
                    entityID: placement.id, op: "insert", on: sql
                )
                try await DerivationWorker.enqueue(
                    assetID: asset.id, kind: "thumbnails", on: sql
                )

                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
    }
}
