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
///     <homes>/<dsm user>/Photos/Shared/<Space>/YYYY/MM/IMG_9001.jpg
///     <shared>/<Space>/YYYY/MM/IMG_9001.jpg
///
/// and turns it back into users, libraries, assets and placements. Nothing is
/// copied or moved: `storage_path` points at the file where it already lies.
///
/// A shared library is in every member's home, a copy of each photo in each
/// (`BrowseTree`), and comes back as the one library: each photo indexed once,
/// the other homes' copies recorded as those members' own, and its members the
/// people whose homes hold it.
///
/// ## What comes back, and what does not
///
/// The photos come back, with their EXIF, dates, places, dimensions and
/// attribution-by-folder. Everything a person typed does not: favorites,
/// ratings, tags, captions and albums live only in the database, and a folder
/// has nowhere to keep them. That is a real limit of the design and this
/// command says so out loud rather than implying a clean recovery.
struct RebuildCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "homes", help: "DSM home directories (default $FRAMESTATION_HOMES_ROOT or /volume1/homes)")
        var homes: String?

        @Option(name: "shared", help: "Shared library root (default $FRAMESTATION_SHARED_ROOT)")
        var shared: String?

        @Option(name: "owner", help: "DSM username to own rebuilt shared libraries (default: the first whose home holds each, else the first user found)")
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
        /// `<shared>/<Space>/…`, or a member's copy of it in their own home,
        /// `<homes>/<holder>/Photos/Shared/<Space>/…`.
        case shared(space: String, holder: String?)
    }

    private struct Found {
        let candidate: LibraryScanner.Candidate
        let home: Home
        /// A shared library's file's path within the library,
        /// `2026/07/IMG_9001.jpg`, the same for its copy in every home.
        var within: String? = nil
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

        // Already indexed: the same file at the same path, or somebody's File
        // Station copy of one. Makes a re-run after an interrupted rebuild
        // resume rather than start over, and makes running this against a
        // live database a no-op for everything it already knows.
        struct PathRow: Decodable { let path: String }
        let indexed = Set(
            try await app.sql.raw("""
                SELECT storage_path AS "path" FROM assets WHERE storage_path IS NOT NULL
                UNION SELECT path FROM browse_entries
                """).all(decoding: PathRow.self).map(\.path)
        )
        let pending = found.filter { !indexed.contains($0.candidate.url.path) }

        // Everyone with a home holding library files, a shared library's
        // copies included.
        let people = Set(found.compactMap { item -> String? in
            switch item.home {
            case .personal(let user, _): return user
            case .shared(_, let holder): return holder
            }
        }).sorted()
        var holders: [String: Set<String>] = [:]
        for item in found {
            if case .shared(let space, let holder) = item.home {
                holders[space, default: []].formUnion(holder.map { [$0] } ?? [])
            }
        }
        let sharedLibraries = holders.keys.sorted()
        // Each one's owner: whoever is named, else the first of those whose
        // homes hold it, else, for one only under the shared root, which
        // names nobody, the first person found.
        let owners = Dictionary(uniqueKeysWithValues: sharedLibraries.compactMap { library in
            (signature.owner ?? holders[library]?.min() ?? people.first).map { (library, $0) }
        })
        let (toIndex, copies) = Self.collapse(pending, owners: owners)
        let copyCount = copies.values.reduce(0) { $0 + $1.count }

        console.info("")
        console.info("  Found:         \(found.count) files")
        console.info("  Already known: \(found.count - pending.count)")
        console.info("  To index:      \(toIndex.count) (\(ImportCommand.humanBytes(toIndex.reduce(Int64(0)) { $0 + $1.candidate.byteSize })))")
        if copyCount > 0 {
            console.info("  Copies:        \(copyCount) (a shared photo in another member's home, kept as theirs)")
        }
        console.info("  People:        \(people.isEmpty ? "—" : people.joined(separator: ", "))")
        console.info("  Shared:        \(sharedLibraries.isEmpty ? "—" : sharedLibraries.joined(separator: ", "))")
        console.info("")

        if signature.dryRun {
            console.info("Dry run — nothing written.")
            return
        }
        guard !toIndex.isEmpty else {
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

        // No folder says who added a shared library's photos, so they're all
        // its owner's: resolved once per library rather than per file, so each
        // library's placements are attributed consistently instead of to
        // whichever account happened to sort first.
        var sharedOwners: [String: UUID] = [:]
        for library in sharedLibraries {
            guard let owner = owners[library] else {
                throw Abort(.badRequest, reason:
                    "Shared libraries were found but there is nobody to own them — "
                    + "no home directories were scanned. Pass --owner <dsm username>.")
            }
            let ownerID = try await resolveUser(dsmUsername: owner, on: app.sql)
            sharedOwners[library] = ownerID
            spaces[.shared(space: library, holder: nil)] = try await resolveSharedSpace(
                named: library, owner: ownerID,
                members: holders[library, default: []].sorted().compactMap { users[$0] },
                on: app.sql
            )
        }

        // Into items the way an import's files are (`ImportGrouping`): by the
        // Live Photo identifier each file's probe reads, a folder at a time
        // once the last of its files is in. A batch boundary can fall between
        // a Live Photo's photo and its video, and a run stopped halfway leaves
        // its folder to the next, which groups it with what it adds.
        var unfinished = Dictionary(toIndex.map { (Self.folder(of: $0), 1) }, uniquingKeysWith: +)
        let folders = Dictionary(
            grouping: found.filter { unfinished[Self.folder(of: $0)] != nil }, by: Self.folder(of:)
        )
        var identifiers: [String: String] = [:]
        var grouping = ImportGrouping.Summary()
        var ungrouped = 0

        // --------------------------------------------------------------- index
        let started = Date()
        var indexedCount = 0, failed = 0
        var bytesDone: Int64 = 0

        for chunk in stride(from: 0, to: toIndex.count, by: batchSize).map({
            Array(toIndex[$0..<min($0 + batchSize, toIndex.count)])
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
                          for: item.home, sharedOwners: sharedOwners, in: users
                      ) else {
                    failed += 1
                    app.logger.error("rebuild: no library for \(path)")
                    continue
                }
                // The other members' copies of it, each theirs.
                let theirs = (copies[path] ?? []).compactMap { copy -> (UUID, String)? in
                    guard case .shared(_, let holder?) = copy.home, let holderID = users[holder] else {
                        return nil
                    }
                    return (holderID, copy.candidate.url.path)
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
                        spaceID: spaceID, userID: userID, copies: theirs, app: app
                    )
                    identifiers[path] = metadata.liveIdentifier ?? ""
                    indexedCount += 1
                    bytesDone += item.candidate.byteSize
                } catch {
                    failed += 1
                    app.logger.error("rebuild failed for \(path): \(String(reflecting: error))")
                }
            }

            // Each folder this batch finished, grouped as a whole. One that
            // can't be is left as the batch left it, rather than costing the
            // rest of the library its rebuild.
            for item in chunk {
                let folder = Self.folder(of: item)
                unfinished[folder, default: 0] -= 1
                guard unfinished[folder] == 0, let files = folders[folder] else { continue }
                do {
                    let summary = try await group(
                        files, identifiers: identifiers, spaces: spaces, batchSize: batchSize, app: app
                    )
                    grouping.items += summary.items
                    grouping.livePhotos += summary.livePhotos
                    grouping.stacked += summary.stacked
                } catch {
                    ungrouped += 1
                    app.logger.error("rebuild: could not group \(folder): \(String(reflecting: error))")
                }
            }

            let done = indexedCount + failed
            let elapsed = Date().timeIntervalSince(started)
            let rate = elapsed > 0 ? Double(done) / elapsed : 0
            console.info(
                "  \(done)/\(toIndex.count)  \(ImportCommand.humanBytes(bytesDone))  "
                + String(format: "%.1f files/s  ", rate)
                + "eta \(ImportCommand.humanDuration(rate > 0 ? Double(toIndex.count - done) / rate : 0))"
            )
        }

        // ------------------------------------------------------------- summary
        console.info("")
        console.info("  Indexed: \(indexedCount)")
        console.info("  Failed:  \(failed)")
        console.info("  Elapsed: \(ImportCommand.humanDuration(Date().timeIntervalSince(started)))")
        console.info("")
        console.info("  Grouped as Synology Photos groups them:")
        console.info("    items of more than one file: \(grouping.items)")
        console.info("    of them Live Photos:         \(grouping.livePhotos)")
        console.info("    files kept with another:     \(grouping.stacked)")
        if ungrouped > 0 {
            console.warning("  \(ungrouped) folders couldn't be grouped (see above): a Live Photo in one may show as more than one tile.")
        }
        console.info("")
        console.info("Thumbnails are queued; the derivation worker draws them down in the background.")
        console.info("")
        // Said plainly, because the alternative is someone assuming a clean
        // recovery and only noticing months later that the albums never
        // came back.
        console.warning("Rebuilt from files alone. These were never on disk and are gone:")
        console.warning("  favorites, ratings, tags, captions, albums, and per-photo attribution")
        console.warning("  in shared libraries. Photo ids changed, so every app will refetch.")
        if !sharedLibraries.isEmpty {
            struct MemberRow: Decodable { let library: String; let name: String; let role: String }
            let members = try await app.sql.raw("""
                SELECT s.name AS "library", COALESCE(u.dsm_username, u.display_name) AS "name", m.role
                FROM spaces s
                JOIN space_members m ON m.space_id = s.id
                JOIN users u ON u.id = m.user_id
                WHERE s.kind = 'shared' AND s.name = ANY(\(bind: sharedLibraries)::text[])
                ORDER BY s.name, m.role <> 'owner', 2
                """).all(decoding: MemberRow.self)
            console.warning("Shared libraries came back with their owner and whoever's home holds them:")
            for library in sharedLibraries {
                let names = members.filter { $0.library == library }
                    .map { $0.role == "owner" ? "\($0.name) (owner)" : $0.name }
                console.warning("  \(library): \(names.joined(separator: ", "))")
            }
            console.warning("  Anyone can make that folder in their own home, so check each in the")
            console.warning("  app, and add back anyone with no home here, or they can't see it.")
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
    ///
    /// Except `Photos/Shared/<Space>`, where the tree files a shared library's
    /// photos in each member's home: those are that library's, not the
    /// person's own, and the person whose home holds them is one of its members.
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
            // As given and as the walk spells it, links resolved: macOS's
            // /tmp is a link to /private/tmp.
            let roots = Set([photos, ImportGrouping.realPath(photos)])
            found += candidates.map { candidate in
                let parts = roots.lazy.map { relative(candidate.url.path, to: $0) }
                    .first { !$0.isEmpty } ?? []
                if parts.count >= 3, parts[0] == "Shared" {
                    return Found(
                        candidate: candidate, home: .shared(space: parts[1], holder: person),
                        within: parts.dropFirst(2).joined(separator: "/")
                    )
                }
                return Found(
                    candidate: candidate,
                    home: .personal(
                        user: person,
                        device: legacyDevice(of: candidate.url.path, under: photos)
                    )
                )
            }
        }
        return found
    }

    /// The device a legacy `MobileBackup/<device>/…` path names, if any.
    ///
    /// Only meaningful for files Synology filed. Anything under `PhotoLibrary/`
    /// came from a browser and names no device, and anything FrameStation wrote
    /// sits at `Photos/Personal/YYYY/MM/` (loose at `Photos/YYYY/MM/` before
    /// Personal existed) and names none either —
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
            let roots = Set([path, ImportGrouping.realPath(path)])
            found += candidates.map { candidate in
                Found(
                    candidate: candidate, home: .shared(space: library, holder: nil),
                    within: roots.lazy.map { relative(candidate.url.path, to: $0) }
                        .first { !$0.isEmpty }?.joined(separator: "/")
                )
            }
        }
        return found
    }

    /// Path components below `root`, e.g. `["iPhone", "2026", "07", "IMG.heic"]`.
    static func relative(_ path: String, to root: String) -> [String] {
        let root = root.hasSuffix("/") ? String(root.dropLast()) : root
        guard path.hasPrefix(root + "/") else { return [] }
        return path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
    }

    /// One file of each shared photo to index, however many homes hold a copy
    /// of it: the shared root's if there is one, else its owner's, else the
    /// first member's. The rest, at the same path in the library and the same
    /// size, are the other members' copies, kept as theirs rather than indexed
    /// again, and not read: the tree makes every copy of the one file.
    private static func collapse(
        _ pending: [Found], owners: [String: String]
    ) -> (index: [Found], copies: [String: [Found]]) {
        var photos: [String: [Found]] = [:]
        for item in pending {
            guard case .shared(let space, _) = item.home, let within = item.within else { continue }
            photos["\(space)\n\(within)\n\(item.candidate.byteSize)", default: []].append(item)
        }
        func preference(_ item: Found) -> (Int, String) {
            guard case .shared(let space, let holder?) = item.home else { return (0, "") }
            return (holder == owners[space] ? 1 : 2, holder)
        }
        var chosen: Set<String> = []
        var copies: [String: [Found]] = [:]
        for items in photos.values {
            let ordered = items.sorted { preference($0) < preference($1) }
            let first = ordered[0].candidate.url.path
            chosen.insert(first)
            if ordered.count > 1 { copies[first] = Array(ordered.dropFirst()) }
        }
        let index = pending.filter { item in
            guard case .shared = item.home, item.within != nil else { return true }
            return chosen.contains(item.candidate.url.path)
        }
        return (index, copies)
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

    /// The device folder, and the home a shared library's copy is in, are part
    /// of the path but not of the library's identity, so they're dropped when
    /// looking a space up.
    private static func spaceKey(_ home: Home) -> Home {
        switch home {
        case .personal(let user, _): return .personal(user: user, device: nil)
        case .shared(let space, _): return .shared(space: space, holder: nil)
        }
    }

    /// Who a placement is attributed to. A home directory names its person; a
    /// shared folder names nobody, so those go to the library's owner.
    private static func userID(
        for home: Home, sharedOwners: [String: UUID], in users: [String: UUID]
    ) -> UUID? {
        switch home {
        case .personal(let user, _): return users[user]
        case .shared(let space, _): return sharedOwners[space]
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

    /// Its members are its owner and the people whose homes hold it.
    ///
    /// The tree files a shared library's photos in each member's home and
    /// takes them out of the home of anyone who leaves, so a home holding it
    /// is the record of who was in it. A folder under the shared root says a
    /// library exists and what it is called, but not who was in it, and adding
    /// everyone with a home would be the friendly guess and the wrong one: it
    /// hands a family member a library they may never have been in. Anyone can
    /// make the folder in their own home, too, so the summary names everyone
    /// let in.
    ///
    /// Only when the library is made. One that's already here keeps the
    /// members it has, so a re-run never puts back someone since removed.
    private func resolveSharedSpace(
        named name: String, owner: UUID, members: [UUID], on sql: any SQLDatabase
    ) async throws -> UUID {
        if let existing = try await sql.raw("""
            SELECT id FROM spaces WHERE kind = 'shared' AND name = \(bind: name)
            """).first(decoding: IDRow.self) {
            return existing.id
        }
        // The library and everyone in it at once, so a run stopped in between
        // can't leave one with nobody in it to be found on the next.
        guard let created = try await sql.raw("""
            WITH created AS (
                INSERT INTO spaces (kind, name, created_by)
                VALUES ('shared', \(bind: name), \(bind: owner))
                RETURNING id
            ), joined AS (
                INSERT INTO space_members (space_id, user_id, role)
                SELECT created.id, m.user_id,
                       CASE WHEN m.user_id = \(bind: owner) THEN 'owner' ELSE 'contributor' END
                FROM created, unnest(\(bind: Array(Set([owner] + members)))::uuid[]) AS m(user_id)
            )
            SELECT id FROM created
            """).first(decoding: IDRow.self) else {
            throw Abort(.internalServerError, reason: "Could not recreate the library \(name).")
        }
        return created.id
    }

    // MARK: - Indexing one file

    /// An item of its own until its folder is grouped (`group`). `copies` are
    /// the other members' copies of a shared photo, each recorded as theirs.
    private func index(
        _ item: Found,
        sha: String,
        metadata: MediaProbe.Metadata,
        spaceID: UUID,
        userID: UUID,
        copies: [(user: UUID, path: String)],
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
                        (sha256, byte_size, media_type, mime, blob_ext, is_raw, storage_path)
                    VALUES
                        (\(bind: sha), \(bind: candidate.byteSize),
                         \(bind: candidate.mediaType.rawValue),
                         \(bind: metadata.mime ?? candidate.mime),
                         \(bind: BlobStore.fileExtension(for: filename)),
                         \(bind: metadata.isRaw), \(bind: path))
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

                // browse_path is the file itself. Nothing has read it since
                // the tree's entries became one per person (`browse_entries`).
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

                // Each other member's copy of a shared photo is their File
                // Station copy, as if the tree had just made it, so it's taken
                // out of their home if they leave. Never this file, the only
                // one: the tree unlinks an entry's file when its photo is
                // removed or its person leaves.
                if !copies.isEmpty {
                    try await sql.raw("""
                        INSERT INTO browse_entries (space_asset_id, user_id, path, link_kind)
                        SELECT \(bind: placement.id), v.user_id, v.path, 'reflink'
                        FROM unnest(\(bind: copies.map(\.user))::uuid[], \(bind: copies.map(\.path))::text[])
                             AS v(user_id, path)
                        ON CONFLICT (space_asset_id, user_id) DO NOTHING
                        """).run()
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

    // MARK: - Grouping

    /// The folder a file is grouped in. A shared library's by its folder in
    /// the library, so a folder's photos group together whichever home holds
    /// the copy of each that's indexed.
    private static func folder(of item: Found) -> String {
        if case .shared(let space, _) = item.home, let within = item.within {
            return space + "\n" + (within as NSString).deletingLastPathComponent
        }
        return item.candidate.url.deletingLastPathComponent().path
    }

    /// Groups one folder's files into items as an import's are, those an
    /// earlier run indexed there with them: nothing kept their identifiers,
    /// so they're read off the files again, one exiftool run per batch.
    private func group(
        _ files: [Found], identifiers: [String: String], spaces: [Home: UUID],
        batchSize: Int, app: Application
    ) async throws -> ImportGrouping.Summary {
        struct Row: Decodable {
            let assetID: UUID
            let placementID: UUID
            let spaceID: UUID
            let path: String
            let mediaType: String
            let liveGroupID: UUID?
            let stackedUnder: UUID?
        }
        // Each file's row, in the library its folder belongs to.
        let placed = files.compactMap { file in
            spaces[Self.spaceKey(file.home)].map { (file.candidate.url.path, $0) }
        }
        let rows = try await app.sql.raw("""
            SELECT a.id AS "assetID", sa.id AS "placementID", sa.space_id AS "spaceID",
                   a.storage_path AS "path", a.media_type AS "mediaType",
                   a.live_group_id AS "liveGroupID", a.stacked_under AS "stackedUnder"
            FROM unnest(\(bind: placed.map(\.0))::text[], \(bind: placed.map(\.1))::uuid[]) AS f(path, space)
            JOIN assets a ON a.storage_path = f.path
            JOIN space_assets sa ON sa.asset_id = a.id AND sa.space_id = f.space
            """).all(decoding: Row.self)

        let unread = rows.map(\.path).filter { identifiers[$0] == nil }
        var read: [String: String] = [:]
        for start in stride(from: 0, to: unread.count, by: batchSize) {
            let batch = unread[start..<min(start + batchSize, unread.count)]
            let identified = try await MediaProbe.liveIdentifiers(batch.map { URL(fileURLWithPath: $0) })
            read.merge(identified) { $1 }
        }

        let byPath = Dictionary(files.map { ($0.candidate.url.path, $0) }, uniquingKeysWith: { first, _ in first })
        let members = rows.compactMap { row -> ImportGrouping.Member? in
            guard let file = byPath[row.path] else { return nil }
            return ImportGrouping.Member(
                assetID: row.assetID, placementID: row.placementID, spaceID: row.spaceID,
                // A shared photo by its path in the library, wherever its copy is.
                path: file.within.map { "/" + $0 } ?? row.path,
                identifier: identifiers[row.path] ?? read[row.path],
                mediaType: row.mediaType, modifiedAt: file.candidate.modifiedAt,
                liveGroupID: row.liveGroupID, stackedUnder: row.stackedUnder
            )
        }
        return try await ImportGrouping.group(members, app: app)
    }
}
