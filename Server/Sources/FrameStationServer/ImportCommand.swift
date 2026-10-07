import FrameStationAPI
import Foundation
import NIOCore
import SQLKit
import Vapor

/// `FrameStationServer spaces` — ids for the import command.
struct SpacesCommand: AsyncCommand {
    struct Signature: CommandSignature {}
    var help: String { "List users and spaces with their ids." }

    private struct Row: Decodable {
        let spaceID: UUID
        let name: String
        let kind: String
        let owner: String
        let ownerID: UUID
        let assetCount: Int
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let rows = try await context.application.sql.raw("""
            SELECT s.id AS "spaceID", s.name, s.kind,
                   u.display_name AS owner, u.id AS "ownerID",
                   (SELECT count(*)::int FROM space_assets sa
                    WHERE sa.space_id = s.id AND sa.deleted_at IS NULL) AS "assetCount"
            FROM spaces s
            JOIN users u ON u.id = s.created_by
            ORDER BY s.kind, u.display_name
            """).all(decoding: Row.self)

        guard !rows.isEmpty else {
            context.console.warning("No spaces yet. Redeem an invite from the app first.")
            return
        }

        context.console.info("")
        for row in rows {
            context.console.info("  \(row.name)  [\(row.kind)]  \(row.assetCount) items")
            context.console.info("    space: \(row.spaceID)")
            context.console.info("    owner: \(row.owner)  \(row.ownerID)")
            context.console.info("")
        }
    }
}

/// `FrameStationServer import` — one-time ingest of an existing library.
///
/// Ordered before the device backup engine deliberately. Reading 800 GB off
/// local disks is disk-bound and finishes overnight; pushing the same library
/// up from two phones through a background `URLSession` takes weeks of
/// opportunistic scheduling. Import first, and the phones only ever handle the
/// delta.
struct ImportCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "path", short: "p", help: "Library root to walk, e.g. /photo")
        var path: String?

        @Option(name: "space", short: "s", help: "Destination space id (see `spaces`)")
        var space: String?

        @Option(name: "user", short: "u", help: "Attribute uploads to this user id (defaults to the space owner)")
        var user: String?

        @Option(name: "mode", short: "m", help: "reflink (default), copy or hardlink")
        var mode: String?

        @Option(name: "concurrency", short: "c", help: "Parallel hash/probe workers (default 4)")
        var concurrency: Int?

        @Option(name: "batch", short: "b", help: "Files per exiftool invocation (default 64)")
        var batch: Int?

        @Flag(name: "dry-run", help: "Report what would be imported without writing anything")
        var dryRun: Bool
    }

    enum Mode: String {
        /// A copy-on-write clone. It's instant, takes no space until one side
        /// is edited, and leaves the source library exactly as it was. Needs
        /// the library and the blob store on one Btrfs volume, which on the NAS
        /// they are, reached through one mount (`CloneRoute`); checked before
        /// anything is imported. The default, because
        /// importing a few hundred gigabytes shouldn't need a few hundred
        /// gigabytes free.
        case reflink
        /// Duplicates bytes. Needs free space equal to the library.
        case copy
        /// Same inode as the source: instant, zero extra space. Requires the
        /// library and the blob store to be on the same volume.
        case hardlink
    }

    var help: String { "Import an existing photo library from disk." }

    private struct IDRow: Decodable { let id: UUID }
    private struct OwnerRow: Decodable { let ownerID: UUID }
    private struct RecordRow: Decodable {
        let sourcePath: String
        let byteSize: Int64
        let modifiedAt: Date
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let console = context.console

        guard let path = signature.path else {
            throw Abort(.badRequest, reason: "--path is required, e.g. --path /photo")
        }
        guard let spaceString = signature.space, let spaceID = UUID(uuidString: spaceString) else {
            throw Abort(.badRequest, reason: "--space is required. Run `FrameStationServer spaces`.")
        }
        guard let mode = Mode(rawValue: signature.mode ?? Mode.reflink.rawValue) else {
            throw ImportError.unknownMode(signature.mode ?? "")
        }
        let concurrency = max(1, signature.concurrency ?? 4)
        let batchSize = max(1, signature.batch ?? 64)

        let missing = Derivatives.missingTools()
        guard missing.isEmpty else {
            throw Abort(.internalServerError,
                        reason: "Missing media tools: \(missing.joined(separator: ", "))")
        }

        // Resolve and validate the destination up front — discovering a bad
        // space id an hour into an import would be miserable.
        guard let owner = try await app.sql.raw("""
            SELECT created_by AS "ownerID" FROM spaces WHERE id = \(bind: spaceID)
            """).first(decoding: OwnerRow.self) else {
            throw ImportError.noSuchSpace(spaceID)
        }
        let userID = signature.user.flatMap(UUID.init(uuidString:)) ?? owner.ownerID
        guard try await app.sql.raw("""
            SELECT user_id AS id FROM space_members
            WHERE space_id = \(bind: spaceID) AND user_id = \(bind: userID)
            """).first(decoding: IDRow.self) != nil else {
            throw ImportError.notAMember
        }

        // ---------------------------------------------------------------- scan
        console.info("Scanning \(path)…")
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw ImportError.unreadableRoot(root.path)
        }
        let candidates = try LibraryScanner.scan(root: root, logger: app.logger)
        guard !candidates.isEmpty else {
            console.warning("No importable media found under \(path).")
            return
        }
        let liveGroups = LibraryScanner.liveGroups(candidates)

        // Resume: skip anything already recorded whose size and mtime match.
        let previous = try await app.sql.raw("""
            SELECT source_path AS "sourcePath", byte_size AS "byteSize",
                   modified_at AS "modifiedAt"
            FROM import_records WHERE outcome <> 'failed'
            """).all(decoding: RecordRow.self)
        var seen: [String: (Int64, Date)] = [:]
        for record in previous { seen[record.sourcePath] = (record.byteSize, record.modifiedAt) }

        let pending = candidates.filter { candidate in
            guard let (size, modified) = seen[candidate.url.path] else { return true }
            // Second granularity: Postgres and the filesystem disagree below it.
            return size != candidate.byteSize
                || abs(modified.timeIntervalSince(candidate.modifiedAt)) > 1
        }

        let totalBytes = pending.reduce(Int64(0)) { $0 + $1.byteSize }
        console.info("")
        console.info("  Found:     \(candidates.count) files")
        console.info("  Already:   \(candidates.count - pending.count) imported")
        console.info("  To import: \(pending.count) (\(Self.humanBytes(totalBytes)))")
        console.info("  Mode:      \(mode.rawValue)")
        console.info("")

        if signature.dryRun {
            console.info("Dry run — nothing written.")
            return
        }
        guard !pending.isEmpty else {
            console.info("Nothing to do.")
            return
        }

        if mode == .hardlink {
            console.warning("Hardlink mode: blobs share inodes with the source library.")
            console.warning("Editing a source file in place would silently change the stored asset.")
        }

        // Through the volume mount compose provides, when it does, so the
        // library and the blob store are one mount to the kernel. See
        // `CloneRoute`.
        let route = CloneRoute.fromEnvironment(
            blobRoot: app.blobStore.root.path,
            homesRoot: BrowseTree.Configuration.fromEnvironment().homesRoot
        )

        // Proved on one file before an hour of hashing, not discovered as a
        // failure on every file after it.
        if mode == .reflink, let first = pending.first {
            try await Self.checkReflink(from: first.url, store: app.blobStore, route: route)
        }

        // --------------------------------------------------------------- import
        let started = Date()
        var imported = 0, reused = 0, present = 0, failed = 0
        var bytesDone: Int64 = 0

        for chunk in stride(from: 0, to: pending.count, by: batchSize).map({
            Array(pending[$0..<min($0 + batchSize, pending.count)])
        }) {
            // Hash in parallel; this is the disk-bound part.
            var hashes: [String: String] = [:]
            await withTaskGroup(of: (String, String?).self) { group in
                var running = 0
                var index = 0
                while index < chunk.count || running > 0 {
                    while running < concurrency, index < chunk.count {
                        let candidate = chunk[index]
                        index += 1
                        running += 1
                        group.addTask {
                            (candidate.url.path, try? LibraryScanner.hash(candidate.url))
                        }
                    }
                    if let (path, digest) = await group.next() {
                        running -= 1
                        if let digest { hashes[path] = digest }
                    }
                }
            }

            // One exiftool for every photo in the chunk.
            let photos = chunk.filter { $0.mediaType == .photo }.map(\.url)
            let photoMetadata = (try? await MediaProbe.probePhotoBatch(photos)) ?? [:]

            for candidate in chunk {
                guard let sha = hashes[candidate.url.path] else {
                    failed += 1
                    try? await record(candidate, sha: nil, assetID: nil,
                                      outcome: "failed", error: "could not hash", on: app.sql)
                    continue
                }

                do {
                    // Already in this library, put there by an upload, a share
                    // or an earlier import, or deliberately removed from it. A
                    // second copy is never what anyone wants, and a removal is
                    // a decision the import doesn't get to reverse.
                    if try await alreadyInSpace(sha: sha, spaceID: spaceID, on: app.sql) {
                        present += 1
                        bytesDone += candidate.byteSize
                        try? await record(candidate, sha: sha, assetID: nil,
                                          outcome: "already in library", error: nil, on: app.sql)
                        continue
                    }

                    var metadata = candidate.mediaType == .photo
                        ? (photoMetadata[candidate.url.path] ?? MediaProbe.Metadata())
                        : try await MediaProbe.probe(url: candidate.url, mediaType: .video)

                    if metadata.capturedAt == nil { metadata.capturedAt = candidate.modifiedAt }

                    // Named now, from the file's own position. An upload is
                    // named by its metadata job, but an import is queued for
                    // thumbnails only, and the pass that would name it later
                    // waits behind every thumbnail in the library. Until then
                    // its day can't name the place, or split by it — a
                    // Synology Shared Space photo taken in Ohio sat in a day
                    // headed "Reston, Virginia".
                    let placeName = metadata.latitude.flatMap { latitude in
                        metadata.longitude.flatMap { longitude in
                            app.geocoder?.label(latitude: latitude, longitude: longitude)
                        }
                    }

                    // Another library may hold the same bytes, such as a photo
                    // someone also backed up from their phone. Its row is
                    // copied rather than shared, as sharing does, so an edit in
                    // one library never changes another person's photo.
                    let original = try await assetWithBytes(sha: sha, on: app.sql)
                    let blobExtension = BlobStore.fileExtension(for: candidate.url.lastPathComponent)
                    // Always, because a row doesn't prove the blob store has
                    // the bytes (a rebuilt library keeps them in homes). A
                    // no-op when it does.
                    try await place(
                        candidate, sha: sha, ext: blobExtension, mode: mode,
                        store: app.blobStore, route: route
                    )

                    let assetID = try await insert(
                        candidate: candidate,
                        sha: sha,
                        blobExtension: blobExtension,
                        metadata: metadata,
                        placeName: placeName,
                        liveGroupID: liveGroups[candidate.url.path],
                        spaceID: spaceID,
                        userID: userID,
                        copying: original,
                        app: app
                    )

                    if original == nil { imported += 1 } else { reused += 1 }
                    bytesDone += candidate.byteSize
                    try? await record(candidate, sha: sha, assetID: assetID,
                                      outcome: original == nil ? "imported" : "deduplicated",
                                      error: nil, on: app.sql)
                } catch {
                    failed += 1
                    app.logger.error("import failed for \(candidate.url.path): \(error)")
                    try? await record(candidate, sha: sha, assetID: nil, outcome: "failed",
                                      error: String(describing: error), on: app.sql)
                }
            }

            let done = imported + reused + present + failed
            let elapsed = Date().timeIntervalSince(started)
            let rate = elapsed > 0 ? Double(done) / elapsed : 0
            let remaining = rate > 0 ? Double(pending.count - done) / rate : 0
            console.info(
                "  \(done)/\(pending.count)  "
                + "\(Self.humanBytes(bytesDone))  "
                + String(format: "%.1f files/s  ", rate)
                + "eta \(Self.humanDuration(remaining))"
            )
        }

        let elapsed = Date().timeIntervalSince(started)
        console.info("")
        console.info("  Imported:            \(imported)")
        console.info("  Stored once already: \(reused)  (bytes shared, row of its own)")
        console.info("  Already in library:  \(present)  (skipped)")
        console.info("  Failed:              \(failed)")
        console.info("  Elapsed:      \(Self.humanDuration(elapsed))")
        console.info("")
        console.info("Thumbnails are queued; the derivation worker drains them in the background.")
        if failed > 0 {
            console.warning("Re-run to retry failures — successful files are skipped automatically.")
        }
    }

    // MARK: - Steps

    /// Whether the library already holds these bytes in any state: live, in
    /// Recently Deleted, or purged.
    private func alreadyInSpace(sha: String, spaceID: UUID, on sql: any SQLDatabase) async throws -> Bool {
        try await sql.raw("""
            SELECT sa.id FROM space_assets sa
            JOIN assets a ON a.id = sa.asset_id
            WHERE sa.space_id = \(bind: spaceID) AND a.sha256 = \(bind: sha)
            LIMIT 1
            """).first(decoding: IDRow.self) != nil
    }

    /// The oldest row over these bytes, anywhere, to copy rather than probe
    /// the file again.
    private func assetWithBytes(sha: String, on sql: any SQLDatabase) async throws -> UUID? {
        try await sql.raw("""
            SELECT id FROM assets WHERE sha256 = \(bind: sha) ORDER BY created_at LIMIT 1
            """).first(decoding: IDRow.self)?.id
    }

    /// Makes one reflink from the library into the blob store and removes it
    /// again, so a filesystem that can't clone between them stops the import
    /// before it starts.
    static func checkReflink(from source: URL, store: BlobStore, route: CloneRoute) async throws {
        let probe = store.root.appendingPathComponent(".reflink-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: probe) }
        guard await reflink(source, to: probe, route: route) else {
            throw ImportError.cannotReflink(source.path)
        }
    }

    /// A clone through `route`, with whatever a failed `cp` left behind
    /// removed again.
    static func reflink(_ source: URL, to destination: URL, route: CloneRoute) async -> Bool {
        guard await route.clone(source.path, to: destination.path) else {
            try? FileManager.default.removeItem(at: destination)
            return false
        }
        return true
    }

    private func place(
        _ candidate: LibraryScanner.Candidate,
        sha: String,
        ext: String,
        mode: Mode,
        store: BlobStore,
        route: CloneRoute
    ) async throws {
        let fm = FileManager.default
        let destination = store.blobPath(sha256: sha, fileExtension: ext)
        guard !fm.fileExists(atPath: destination.path) else { return }
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        switch mode {
        case .reflink:
            guard await Self.reflink(candidate.url, to: destination, route: route) else {
                throw ImportError.cannotReflink(candidate.url.path)
            }
        case .hardlink:
            do {
                try fm.linkItem(at: candidate.url, to: destination)
            } catch {
                // Different volume — hardlinks can't cross filesystems.
                try fm.copyItem(at: candidate.url, to: destination)
            }
        case .copy:
            try fm.copyItem(at: candidate.url, to: destination)
        }
    }

    private func insert(
        candidate: LibraryScanner.Candidate,
        sha: String,
        blobExtension: String,
        metadata: MediaProbe.Metadata,
        placeName: String?,
        liveGroupID: UUID?,
        spaceID: UUID,
        userID: UUID,
        copying original: UUID?,
        app: Application
    ) async throws -> UUID {
        try await app.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                // A row of its own, always, the way sharing does it (migration
                // 0014): two libraries holding the same bytes is two
                // placements over two rows, never one row in both. Otherwise a
                // date or location fixed in Family Shared would quietly change
                // someone's personal copy. The bytes are still stored once:
                // the blob store is content-addressed.
                let asset: IDRow
                if let original {
                    // Copied from the row that already has these bytes, so
                    // nothing is probed or rendered twice: derivatives are kept
                    // under the content hash, and derived_at comes along. The
                    // Live Photo pairing found in this walk wins over the old
                    // row's, so a still and its motion half imported together
                    // stay together.
                    guard let copied = try await sql.raw("""
                        INSERT INTO assets
                            (sha256, byte_size, media_type, mime, blob_ext, width, height, duration_ms,
                             captured_at, captured_tz_off, tz_off_fallback, local_captured_at,
                             lat, lon, place_name, destination, destination_version,
                             camera_make, camera_model, lens, iso, aperture,
                             shutter, focal_len, exposure_bias, dynamic_range, orientation,
                             is_raw, live_group_id, burst_id, burst_pick, media_subtypes, thumbhash, exif,
                             thumb_version, derived_at, storage_path)
                        SELECT sha256, byte_size, media_type, mime, blob_ext, width, height, duration_ms,
                               captured_at, captured_tz_off, tz_off_fallback, local_captured_at,
                               lat, lon, COALESCE(place_name, \(bind: placeName)),
                               destination, destination_version,
                               camera_make, camera_model, lens, iso, aperture,
                               shutter, focal_len, exposure_bias, dynamic_range, orientation,
                               is_raw, COALESCE(\(bind: liveGroupID), live_group_id), burst_id, burst_pick,
                               media_subtypes, thumbhash, exif, thumb_version, derived_at, NULL
                        FROM assets WHERE id = \(bind: original)
                        RETURNING id
                        """).first(decoding: IDRow.self) else {
                        throw Abort(.internalServerError, reason: "asset copy returned nothing")
                    }
                    asset = copied
                } else {
                guard let inserted = try await sql.raw("""
                    INSERT INTO assets
                        (sha256, byte_size, media_type, mime, blob_ext, width, height,
                         duration_ms, captured_at, captured_tz_off, local_captured_at,
                         lat, lon, place_name, destination, destination_version,
                         camera_make, camera_model, lens, iso, aperture, shutter,
                         focal_len, exposure_bias, dynamic_range, orientation, is_raw,
                         live_group_id)
                    VALUES
                        (\(bind: sha), \(bind: candidate.byteSize), \(bind: candidate.mediaType.rawValue),
                         \(bind: metadata.mime ?? candidate.mime), \(bind: blobExtension),
                         \(bind: metadata.width), \(bind: metadata.height), \(bind: metadata.durationMs),
                         \(bind: metadata.capturedAt), \(bind: metadata.capturedTZOffset),
                         (\(bind: metadata.capturedAt)
                            + COALESCE(\(bind: metadata.capturedTZOffset), 0) * interval '1 second')
                            AT TIME ZONE 'UTC',
                         \(bind: metadata.latitude), \(bind: metadata.longitude), \(bind: placeName),
                         \(bind: Destinations.label(latitude: metadata.latitude, longitude: metadata.longitude)),
                         \(bind: Destinations.version),
                         \(bind: metadata.cameraMake), \(bind: metadata.cameraModel), \(bind: metadata.lens),
                         \(bind: metadata.iso), \(bind: metadata.aperture), \(bind: metadata.shutter),
                         \(bind: metadata.focalLength), \(bind: metadata.exposureBias),
                         \(bind: metadata.dynamicRange), \(bind: metadata.orientation),
                         \(bind: metadata.isRaw), \(bind: liveGroupID))
                    RETURNING id
                    """).first(decoding: IDRow.self) else {
                    throw Abort(.internalServerError, reason: "asset insert returned nothing")
                }
                asset = inserted
                }

                // The original name, so the File Station tree shows
                // `IMG_1234.jpg` rather than a hash, and the filename-based
                // backfills (dates, screenshots) have something to read.
                guard let placement = try await sql.raw("""
                    INSERT INTO space_assets
                        (space_id, asset_id, uploaded_by_user_id, on_device, filename)
                    VALUES (\(bind: spaceID), \(bind: asset.id), \(bind: userID), false,
                            \(bind: candidate.url.lastPathComponent))
                    ON CONFLICT (space_id, asset_id) DO UPDATE SET deleted_at = NULL
                    RETURNING id
                    """).first(decoding: IDRow.self) else {
                    throw Abort(.internalServerError, reason: "placement insert returned nothing")
                }

                _ = try await ChangeLog.append(
                    spaceID: spaceID, entity: "space_asset",
                    entityID: placement.id, op: "insert", on: sql
                )

                // Imports are bulk by definition — one summary push, not 100,000.
                try await sql.raw("""
                    INSERT INTO activity_sessions (space_id, user_id, photo_count, video_count, is_bulk)
                    VALUES (\(bind: spaceID), \(bind: userID),
                            \(bind: candidate.mediaType == .photo ? 1 : 0),
                            \(bind: candidate.mediaType == .video ? 1 : 0), true)
                    ON CONFLICT (space_id, user_id) WHERE closed_at IS NULL
                    DO UPDATE SET
                        photo_count = activity_sessions.photo_count + EXCLUDED.photo_count,
                        video_count = activity_sessions.video_count + EXCLUDED.video_count,
                        last_at = now(), is_bulk = true
                    """).run()

                // The jobs an upload queues, so an imported photo ends up with
                // everything an uploaded one has: the full metadata dump the
                // Information panel shows (metadata), its tiles (thumbnails),
                // and for a video the cellular rendition (playback, which
                // no-ops for a photo). This used to queue thumbnails alone,
                // which left the rest to catch-up passes that run only when the
                // server starts, 5,000 photos and 500 videos at a time — fine
                // for the Shared Space, and many restarts for a 67,000-photo
                // library. Thumbnails still go first: the worker takes them
                // ahead of everything else.
                //
                // A copied row brought all of it with it, from the row it copies.
                if original == nil {
                    for kind in ["thumbnails", "metadata", Derivatives.playbackJobKind] {
                        try await DerivationWorker.enqueue(assetID: asset.id, kind: kind, on: sql)
                    }
                }

                try await sql.raw("COMMIT").run()
                return asset.id
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
    }

    private func record(
        _ candidate: LibraryScanner.Candidate,
        sha: String?,
        assetID: UUID?,
        outcome: String,
        error: String?,
        on sql: any SQLDatabase
    ) async throws {
        try await sql.raw("""
            INSERT INTO import_records
                (source_path, sha256, asset_id, byte_size, modified_at, outcome, error)
            VALUES (\(bind: candidate.url.path), \(bind: sha), \(bind: assetID),
                    \(bind: candidate.byteSize), \(bind: candidate.modifiedAt),
                    \(bind: outcome), \(bind: error))
            ON CONFLICT (source_path) DO UPDATE SET
                sha256 = EXCLUDED.sha256, asset_id = EXCLUDED.asset_id,
                byte_size = EXCLUDED.byte_size, modified_at = EXCLUDED.modified_at,
                outcome = EXCLUDED.outcome, error = EXCLUDED.error,
                imported_at = now()
            """).run()
    }

    // MARK: - Formatting

    static func humanBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
        return String(format: unit == 0 ? "%.0f %@" : "%.1f %@", value, units[unit])
    }

    static func humanDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds)
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }
}
