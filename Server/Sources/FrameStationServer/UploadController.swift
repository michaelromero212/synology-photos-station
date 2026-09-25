import Foundation
import NIOCore
import FrameStationAPI
import SQLKit
import Vapor

extension UploadProbeRequest: @retroactive Content {}
extension UploadProbeResponse: @retroactive Content {}
extension ChunkAcceptedResponse: @retroactive Content {}
extension CommitUploadRequest: @retroactive Content {}
extension CommitUploadResponse: @retroactive Content {}
extension LinkAssetRequest: @retroactive Content {}

struct UploadController: RouteCollection {
    /// Uniform 16 MB chunks. Small photos land in a single chunk, so there's no
    /// need for a separate single-shot path.
    static let chunkSize = 16 * 1024 * 1024

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(DeviceTokenAuthenticator())
            .grouped(AuthenticatedDevice.guardMiddleware())

        protected.post("uploads", "probe", use: probe)
        protected.on(.PUT, "uploads", ":uploadID", "chunk", ":index",
                     body: .collect(maxSize: "20mb"), use: uploadChunk)
        protected.post("uploads", ":uploadID", "commit", use: commit)
        protected.post("spaces", ":spaceID", "assets", ":assetID", use: link)
    }

    // MARK: - Row types

    private struct IDRow: Decodable { let id: UUID }
    private struct IndexRow: Decodable { let idx: Int }
    private struct SessionRow: Decodable {
        let id: UUID
        let userID: UUID
        let spaceID: UUID
        let sha256: String
        let byteSize: Int64
        let filename: String
        let chunkCount: Int
        let committed: Bool
    }

    // MARK: - Probe

    @Sendable
    func probe(req: Request) async throws -> UploadProbeResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let input = try req.content.decode(UploadProbeRequest.self)

        let sha = input.sha256.lowercased()
        guard sha.count == 64, sha.allSatisfy(\.isHexDigit) else {
            throw Abort(.badRequest, reason: "sha256 must be 64 hex characters.")
        }
        guard input.byteSize > 0 else {
            throw Abort(.badRequest, reason: "byteSize must be positive.")
        }

        try await SpaceAccess.requireContributor(
            spaceID: input.spaceID, userID: device.userID, on: req.sql
        )

        // Removed on purpose, and this is the backup engine sweeping rather than
        // the user asking. Declining here is what stops a deleted photo coming
        // straight back on the next run while it still sits in the camera roll.
        //
        // Only for automatic backup: a deliberate re-add is allowed to undo a
        // deletion, which is what someone means when they pick the photo again.
        if input.isAutomaticBackup {
            struct RemovedRow: Decodable { let id: UUID }
            let removed = try await req.sql.raw("""
                SELECT sa.id FROM space_assets sa
                JOIN assets a ON a.id = sa.asset_id
                WHERE sa.space_id = \(bind: input.spaceID)
                  AND sa.uploaded_by_user_id = \(bind: device.userID)
                  AND sa.deleted_at IS NOT NULL
                  AND a.sha256 = \(bind: sha)
                LIMIT 1
                """).first(decoding: RemovedRow.self)
            if removed != nil {
                return UploadProbeResponse(
                    status: .removed, assetID: nil, uploadID: nil,
                    chunkSize: Self.chunkSize, chunkCount: 0, missingChunks: []
                )
            }
        }

        // Already stored *and already visible to this user* — skip the transfer.
        // This is what makes re-uploads and interrupted retries nearly free.
        //
        // Scoped to the caller's own spaces deliberately. A global lookup is a
        // "does this exact file exist on this NAS?" oracle: anyone holding a
        // copy of a photo could confirm a family member also has it, and the
        // returned asset id was enough to link it into their own library.
        // Storage dedup is unaffected — commit's ON CONFLICT (sha256) still
        // collapses identical bytes onto one asset row and one blob. Only the
        // transfer saving is lost, and only across users.
        if let existing = try await req.sql.raw("""
            SELECT a.id FROM assets a
            WHERE a.sha256 = \(bind: sha)
              AND EXISTS (
                  SELECT 1 FROM space_assets sa
                  JOIN space_members m ON m.space_id = sa.space_id
                  WHERE sa.asset_id = a.id AND sa.deleted_at IS NULL
                    AND m.user_id = \(bind: device.userID)
              )
            """).first(decoding: IDRow.self) {
            return UploadProbeResponse(
                status: .have,
                assetID: existing.id,
                uploadID: nil,
                chunkSize: Self.chunkSize,
                chunkCount: 0,
                missingChunks: []
            )
        }

        let chunkCount = Int(
            (input.byteSize + Int64(Self.chunkSize) - 1) / Int64(Self.chunkSize)
        )
        // Bound as bytea directly rather than built in SQL: Swift Ints bind as
        // bigint and Postgres has no repeat(text, bigint) overload. It must be a
        // ByteBuffer — [UInt8] binds as a Postgres array, not bytea.
        let emptyMask = ByteBuffer(bytes: [UInt8](repeating: 0, count: (chunkCount + 7) / 8))

        guard let session = try await req.sql.raw("""
            INSERT INTO upload_sessions
                (user_id, space_id, device_id, sha256, byte_size, filename,
                 chunk_size, chunk_count, received_mask)
            VALUES
                (\(bind: device.userID), \(bind: input.spaceID), \(bind: device.deviceID),
                 \(bind: sha), \(bind: input.byteSize), \(bind: input.filename),
                 \(bind: Self.chunkSize), \(bind: chunkCount),
                 \(bind: emptyMask))
            ON CONFLICT (user_id, sha256) WHERE committed_at IS NULL
            DO UPDATE SET updated_at = now(), space_id = EXCLUDED.space_id
            RETURNING id
            """).first(decoding: IDRow.self) else {
            throw Abort(.internalServerError, reason: "Could not open upload session.")
        }

        let missing = try await missingChunks(uploadID: session.id, chunkCount: chunkCount, on: req.sql)

        return UploadProbeResponse(
            status: missing.count == chunkCount ? .need : .partial,
            assetID: nil,
            uploadID: session.id,
            chunkSize: Self.chunkSize,
            chunkCount: chunkCount,
            missingChunks: missing
        )
    }

    // MARK: - Chunk

    @Sendable
    func uploadChunk(req: Request) async throws -> ChunkAcceptedResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let uploadID = try req.parameters.require("uploadID", as: UUID.self)
        let index = try req.parameters.require("index", as: Int.self)

        let session = try await loadSession(uploadID: uploadID, userID: device.userID, on: req.sql)
        guard !session.committed else {
            throw Abort(.conflict, reason: "This upload was already committed.")
        }
        guard index >= 0, index < session.chunkCount else {
            throw Abort(.badRequest, reason: "Chunk index out of range.")
        }

        guard let buffer = req.body.data, buffer.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "Empty chunk body.")
        }

        // Catch a truncated transfer here rather than at hash verification, so
        // the client learns which specific chunk to retry.
        let isLast = index == session.chunkCount - 1
        let expected = isLast
            ? Int(session.byteSize) - index * Self.chunkSize
            : Self.chunkSize
        guard buffer.readableBytes == expected else {
            throw Abort(.badRequest,
                        reason: "Chunk \(index) should be \(expected) bytes, got \(buffer.readableBytes).")
        }

        // On the thread pool, not the task running this handler. Sixteen
        // megabytes to a busy disk can take a while, and Swift's concurrency
        // pool has one thread per core — four on the NAS — so a few chunk writes
        // at once were enough to leave every other request waiting for a thread.
        let store = req.blobStore
        let bytes = Data(buffer.readableBytesView)
        try await req.application.threadPool.runIfActive {
            try store.writeChunk(uploadID: uploadID, index: index, bytes: bytes)
        }

        // Without waiting for the disk to confirm it. This is only a note of
        // which chunks have arrived, and it is the one write here that can be
        // lost without harm: after a power cut the chunk simply reads as
        // missing, the phone sends it again, and the file is still checked
        // against its SHA-256 before it is kept. Waiting cost every chunk — and
        // so every photo — a trip to hard drives that were busy writing
        // thumbnails. The commit that records the photo still waits, as it must.
        try await req.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                try await sql.raw("SET LOCAL synchronous_commit TO OFF").run()
                try await sql.raw("""
                    UPDATE upload_sessions
                    SET received_mask = set_bit(received_mask, \(bind: index), 1),
                        updated_at = now()
                    WHERE id = \(bind: uploadID)
                    """).run()
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }

        let missing = try await missingChunks(
            uploadID: uploadID, chunkCount: session.chunkCount, on: req.sql
        )

        return ChunkAcceptedResponse(
            receivedChunks: session.chunkCount - missing.count,
            chunkCount: session.chunkCount,
            missingChunks: missing
        )
    }

    // MARK: - Commit

    @Sendable
    func commit(req: Request) async throws -> CommitUploadResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let uploadID = try req.parameters.require("uploadID", as: UUID.self)
        let input = try req.content.decode(CommitUploadRequest.self)
        // Where a commit's time goes, for the log line at the end. A phone saw
        // commits of one to two seconds and nothing said which part was slow.
        var timing = CommitTiming()

        let session = try await loadSession(uploadID: uploadID, userID: device.userID, on: req.sql)
        guard !session.committed else {
            throw Abort(.conflict, reason: "This upload was already committed.")
        }

        try await SpaceAccess.requireContributor(
            spaceID: input.spaceID, userID: device.userID, on: req.sql
        )

        let missing = try await missingChunks(
            uploadID: uploadID, chunkCount: session.chunkCount, on: req.sql
        )
        guard missing.isEmpty else {
            throw Abort(.badRequest, reason: "Still missing chunks: \(missing.prefix(10)).")
        }

        timing.mark("checks")

        let fileExtension = BlobStore.fileExtension(for: session.filename)
        let blob: URL
        do {
            // On the thread pool — see `uploadChunk`. This reads every chunk
            // back, hashes the whole file and writes it out again: for a large
            // video, seconds of disk that used to hold one of the four threads
            // every other request was waiting on.
            let store = req.blobStore
            let chunkCount = session.chunkCount
            let sha256 = session.sha256
            blob = try await req.application.threadPool.runIfActive {
                try store.assemble(
                    uploadID: uploadID,
                    chunkCount: chunkCount,
                    expectedSHA256: sha256,
                    fileExtension: fileExtension
                )
            }
        } catch let error as BlobStoreError {
            // Staging is already discarded; clear the session so the client can
            // start clean rather than resuming into the same failure.
            try? await req.sql.raw("DELETE FROM upload_sessions WHERE id = \(bind: uploadID)").run()
            req.logger.error("upload \(uploadID) failed to assemble: \(error)")
            throw Abort(.unprocessableEntity, reason: String(describing: error))
        }

        timing.mark("assemble")

        // Read before the photo is recorded rather than after, so that what it
        // finds is recorded with it — see the transaction below. Lean on
        // purpose — `dumpExif: false`. The timeline needs captured_at and
        // dimensions at once (a Mac upload sends no dimensions, so the grid
        // can't lay it out until this fills them), but the full exif dump is a
        // second exiftool run whose only reader is the Information panel; it
        // goes to the queue.
        //
        // A read that fails costs the photo nothing: it is recorded with what
        // the phone said about it, and the queued metadata job reads it again.
        var metadata: MediaProbe.Metadata?
        do {
            metadata = try await MediaProbe.probe(
                url: blob, mediaType: input.mediaType, dumpExif: false
            )
        } catch {
            req.logger.warning("inline metadata probe failed for \(session.filename): \(error)")
        }
        let probed = metadata

        timing.mark("probe")

        // The blob store is where the file lives; the browsable tree is a
        // mirror, and `BrowseTreeWorker` is now the only thing that writes it.
        //
        // Placing eagerly here used to save the twenty seconds until the next
        // sweep, and it was worth it while a photo went to exactly one folder.
        // A shared photograph now goes to one folder per member, and that set
        // changes as people join and leave — so there is a reconciler for it,
        // and a second implementation racing the reconciler at commit time
        // would only be a way for the two to disagree.
        let storagePath: String? = nil

        // To the millisecond when the phone sent it that finely, so photos
        // taken within one second keep the order they were taken in.
        let capturedAt = input.preciseCapturedAt
        let geocoder = req.application.geocoder
        let logger = req.logger

        // Everything the upload writes, in one transaction and so one wait for
        // the disk.
        //
        // It used to be six: the photo, then two statements of metadata, then
        // three jobs for the background worker, each its own commit — and
        // Postgres holds every commit until the disk confirms it. On the NAS's
        // hard drives, busy writing thumbnails at the same time, each of those
        // waits ran from a few hundredths of a second to over one, and a
        // phone's log showed commits of one and a half to four seconds, almost
        // all of it waiting. One commit waits once.
        //
        // It is also the right shape. A photo is never on the timeline without
        // its capture time and place, or without the job that makes its
        // thumbnails: all of it becomes visible at the same moment, or none.
        let result = try await req.withPinnedConnection { sql -> CommitUploadResponse in
            try await sql.raw("BEGIN").run()
            do {
                let alreadyStored = try await sql.raw("""
                    SELECT id FROM assets WHERE sha256 = \(bind: session.sha256)
                    """).first(decoding: IDRow.self) != nil

                guard let asset = try await sql.raw("""
                    INSERT INTO assets
                        (sha256, byte_size, media_type, mime, blob_ext, width, height, duration_ms,
                         captured_at, captured_tz_off, tz_off_fallback, captured_at_fallback,
                         local_captured_at, lat, lon, is_raw,
                         live_group_id, burst_id, burst_pick, media_subtypes, storage_path)
                    VALUES
                        (\(bind: session.sha256), \(bind: session.byteSize),
                         \(bind: input.mediaType.rawValue), \(bind: input.mime),
                         \(bind: fileExtension),
                         \(bind: input.width), \(bind: input.height), \(bind: input.durationMs),
                         \(bind: capturedAt), \(bind: input.capturedTZOffset),
                         \(bind: input.capturedTZOffsetFallback), \(bind: input.capturedAtFallback),
                         (\(bind: capturedAt)
                            + COALESCE(\(bind: input.capturedTZOffset), 0) * interval '1 second')
                            AT TIME ZONE 'UTC',
                         \(bind: input.latitude), \(bind: input.longitude), \(bind: input.isRaw),
                         \(bind: input.liveGroupID), \(bind: input.burstID),
                         \(bind: input.burstPick),
                         \(bind: input.subtypes.map(\.rawValue)), \(bind: storagePath))
                    RETURNING id
                    """).first(decoding: IDRow.self) else {
                    throw Abort(.internalServerError, reason: "Could not record asset.")
                }

                guard let placement = try await sql.raw("""
                    INSERT INTO space_assets
                        (space_id, asset_id, uploaded_by_user_id, source_device_id,
                         source_local_id, filename)
                    VALUES
                        (\(bind: input.spaceID), \(bind: asset.id), \(bind: device.userID),
                         \(bind: device.deviceID), \(bind: input.sourceLocalID),
                         \(bind: session.filename))
                    ON CONFLICT (space_id, asset_id)
                    DO UPDATE SET deleted_at = NULL
                    RETURNING id
                    """).first(decoding: IDRow.self) else {
                    throw Abort(.internalServerError, reason: "Could not place asset in space.")
                }

                let seq = try await ChangeLog.append(
                    spaceID: input.spaceID,
                    entity: "space_asset",
                    entityID: placement.id,
                    op: "insert",
                    on: sql
                )

                try await ActivityTracker.record(
                    spaceID: input.spaceID,
                    userID: device.userID,
                    mediaType: input.mediaType,
                    on: sql
                )

                // What the file itself says, filling what the phone didn't.
                if let probed {
                    try await Self.bestEffort("metadata", on: sql, logger: logger) {
                        try await DerivationWorker.applyMetadata(
                            probed, assetID: asset.id, on: sql, geocoder: geocoder
                        )
                    }
                }

                // Derivation is keyed on what this row actually has, not on the
                // dedup flag. `deduplicated` means the *bytes* were seen before —
                // not that the thumbnails still exist (purge deletes
                // content-addressed derivatives while leaving the asset row) and
                // never that this fresh row carries its own derived_at/thumbhash.
                // Keying the work on dedup left a re-upload of purged content gray
                // forever, with no derivation job at all. So this runs for every
                // commit; a genuine duplicate just regenerates identical
                // thumbnails, which is rare because the .have fast path links
                // instead.
                //
                // The exif dump and the thumbnails. Thumbnails outrank metadata in
                // the worker's claim, so the tiles a person is watching fill
                // before the deep metadata does. The thumbnails are not optional:
                // a photo recorded without the job that makes them would stay
                // gray, so if queuing them fails, the whole commit does.
                try await Self.bestEffort("metadata_job", on: sql, logger: logger) {
                    try await DerivationWorker.enqueue(
                        assetID: asset.id, kind: "metadata", on: sql
                    )
                }
                try await DerivationWorker.enqueue(
                    assetID: asset.id, kind: "thumbnails", on: sql
                )
                // And, for a video, the cellular rendition. Queued at upload
                // rather than built on demand: a 4K transcode takes minutes on
                // this box, so waiting until someone presses play on mobile data
                // would mean waiting through it. The job no-ops for photos and
                // for clips already lean enough to stream as they are. It sits
                // behind thumbnails in the worker's order, which is right —
                // nobody is watching a transcode, but they are watching the grid
                // fill.
                //
                // Non-fatal, but *logged*. This was once a bare `try?`, and when
                // the job kind turned out to violate a CHECK constraint the
                // failure went nowhere at all: uploads succeeded, no rendition
                // was ever queued, and the only way to find out was to read the
                // queue by hand.
                try await Self.bestEffort("playback_job", on: sql, logger: logger) {
                    try await DerivationWorker.enqueue(
                        assetID: asset.id, kind: Derivatives.playbackJobKind, on: sql
                    )
                }

                try await sql.raw("""
                    UPDATE upload_sessions SET committed_at = now() WHERE id = \(bind: uploadID)
                    """).run()

                try await sql.raw("COMMIT").run()

                return CommitUploadResponse(
                    assetID: asset.id,
                    spaceAssetID: placement.id,
                    deduplicated: alreadyStored,
                    changeSeq: seq
                )
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }

        timing.mark("record")

        // Best-effort and deliberately outside the transaction: the browse tree
        // is a convenience mirror, rebuildable from the database, and must never
        // fail an upload.
        req.blobStore.linkIntoBrowseTree(
            blob: blob,
            userSlug: BlobStore.slug(device.displayName),
            capturedAt: input.capturedAt,
            filename: session.filename,
            logger: req.logger
        )
        timing.mark("tree")

        let summary = timing.summary
        req.logger.info(
            "committed \(session.filename) (\(session.byteSize) bytes, dedup: \(result.deduplicated)) in \(summary)"
        )
        return result
    }

    /// Runs `body` inside a savepoint, so a failure in it undoes only its own
    /// statements and the transaction around it carries on.
    ///
    /// What a write that is allowed to fail needs once it shares a transaction
    /// with ones that aren't: in Postgres a failed statement otherwise aborts
    /// the whole transaction, and a job that couldn't be queued would take the
    /// photo down with it. Logged, because a failure nobody hears about is how
    /// the playback queue once went empty for weeks.
    private static func bestEffort(
        _ name: String,
        on sql: any SQLDatabase,
        logger: Logger,
        _ body: () async throws -> Void
    ) async throws {
        try await sql.raw("SAVEPOINT \(unsafeRaw: name)").run()
        do {
            try await body()
            try await sql.raw("RELEASE SAVEPOINT \(unsafeRaw: name)").run()
        } catch {
            logger.warning("commit went on without \(name): \(String(reflecting: error))")
            try await sql.raw("ROLLBACK TO SAVEPOINT \(unsafeRaw: name)").run()
        }
    }

    /// Split times for one commit, logged with it: "1.84s — checks 0.03s,
    /// assemble 0.12s, record 0.20s, …". Wall-clock from the handler's start,
    /// so waiting for the CPU or a disk shows up in whichever step waited.
    struct CommitTiming {
        private let start = ContinuousClock.now
        private var last = ContinuousClock.now
        private var steps: [(String, Duration)] = []

        mutating func mark(_ step: String) {
            let now = ContinuousClock.now
            steps.append((step, now - last))
            last = now
        }

        var summary: String {
            let total = Self.seconds(ContinuousClock.now - start)
            let parts = steps.map { "\($0.0) \(Self.seconds($0.1))" }
            return "\(total) — " + parts.joined(separator: ", ")
        }

        private static func seconds(_ duration: Duration) -> String {
            let (whole, fraction) = duration.components
            let value = Double(whole) + Double(fraction) / 1e18
            return String(format: "%.2fs", value)
        }
    }


    /// Copies a photo into a space and returns the new asset row's id.
    ///
    /// Adding to a shared library copies the file, the way Synology Photos
    /// copies into its Shared Space. A row pointing at someone else's file
    /// would mean the shared library's contents live inside a personal home
    /// directory — the folder would look right in File Station and be a lie.
    ///
    /// Metadata and `derived_at` are copied with it, and derivatives are keyed
    /// by content hash, so the copy needs no re-probe and no new thumbnails.
    ///
    /// Returns nil when the library layout is off, in which case the caller
    /// falls back to sharing the asset row — the pre-§3a behavior.
    /// Internal rather than private: the batch share endpoint in
    /// `MediaEditController` is the same operation done fifty times, and two
    /// implementations of "copy a photo into a space" would drift.
    static func copyIntoSpace(
        assetID: UUID, spaceID: UUID, device: AuthenticatedDevice, req: Request
    ) async throws -> UUID? {
        let configuration = BrowseTree.Configuration.fromEnvironment()
        guard configuration.enabled else { return nil }

        struct SourceRow: Decodable {
            let sha256: String
            let blobExt: String
            let storagePath: String?
            let capturedAt: Date?
            let filename: String?
        }
        struct TargetRow: Decodable {
            let spaceKind: String
            let spaceName: String
            let dsmUsername: String?
            let dsmUID: Int?
        }

        guard let source = try await req.sql.raw("""
            SELECT a.sha256, a.blob_ext AS "blobExt", a.storage_path AS "storagePath",
                   a.captured_at AS "capturedAt",
                   (SELECT sa.filename FROM space_assets sa
                    WHERE sa.asset_id = a.id AND sa.filename IS NOT NULL LIMIT 1) AS filename
            FROM assets a WHERE a.id = \(bind: assetID)
            """).first(decoding: SourceRow.self),
            let target = try await req.sql.raw("""
            SELECT s.kind AS "spaceKind", s.name AS "spaceName",
                   u.dsm_username AS "dsmUsername", u.dsm_uid AS "dsmUID"
            FROM spaces s JOIN users u ON u.id = \(bind: device.userID)
            WHERE s.id = \(bind: spaceID)
            """).first(decoding: TargetRow.self)
        else { return nil }

        // Nothing to copy from: this row still lives in the blob store.
        guard let sourcePath = source.storagePath,
              FileManager.default.fileExists(atPath: sourcePath)
        else { return nil }
        _ = sourcePath

        // A copy of the row to go with the copy of the file. derived_at comes
        // along so the worker doesn't redo work whose output is already on disk
        // under the shared content hash.
        struct NewID: Decodable { let id: UUID }
        guard let created = try await req.sql.raw("""
            INSERT INTO assets
                (sha256, byte_size, media_type, mime, blob_ext, width, height, duration_ms,
                 captured_at, captured_tz_off, tz_off_fallback, local_captured_at,
                 lat, lon, place_name, camera_make, camera_model, lens, iso, aperture,
                 shutter, focal_len, exposure_bias, dynamic_range, orientation,
                 is_raw, live_group_id, burst_id, burst_pick, media_subtypes, thumbhash, exif,
                 thumb_version, derived_at, storage_path)
            SELECT sha256, byte_size, media_type, mime, blob_ext, width, height, duration_ms,
                   captured_at, captured_tz_off, tz_off_fallback, local_captured_at,
                   lat, lon, place_name, camera_make, camera_model, lens, iso, aperture,
                   shutter, focal_len, exposure_bias, dynamic_range, orientation,
                   is_raw, live_group_id, burst_id, burst_pick, media_subtypes, thumbhash, exif,
                   thumb_version, derived_at, NULL
            FROM assets WHERE id = \(bind: assetID)
            RETURNING id
            """).first(decoding: NewID.self) else { return nil }
        return created.id
    }

    // MARK: - Link an existing blob into a space

    /// The `.have` path, and how a photo moves from Personal to Family Shared:
    /// a row, not a copy.
    @Sendable
    func link(req: Request) async throws -> CommitUploadResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let assetID = try req.parameters.require("assetID", as: UUID.self)
        let input = try req.content.decode(LinkAssetRequest.self)

        try await SpaceAccess.requireContributor(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )

        // Linking is a read of the source as much as a write to the target: you
        // may only place an asset you can already see. Without this, holding an
        // asset id is enough to pull any file in the household into your own
        // library — and ids leak far more easily than blobs do.
        //
        // 404 rather than 403, so this doesn't confirm the asset exists.
        struct MediaRow: Decodable { let mediaType: String }
        guard let media = try await req.sql.raw("""
            SELECT a.media_type AS "mediaType" FROM assets a
            WHERE a.id = \(bind: assetID)
              AND EXISTS (
                  SELECT 1 FROM space_assets sa
                  JOIN space_members m ON m.space_id = sa.space_id
                  WHERE sa.asset_id = a.id AND sa.deleted_at IS NULL
                    AND m.user_id = \(bind: device.userID)
              )
            """).first(decoding: MediaRow.self) else {
            throw Abort(.notFound, reason: "No such asset.")
        }

        // Already here: nothing to copy, nothing to insert.
        let alreadyPlaced = try await req.sql.raw("""
            SELECT id FROM space_assets
            WHERE space_id = \(bind: spaceID) AND asset_id = \(bind: assetID)
              AND deleted_at IS NULL
            """).first(decoding: IDRow.self)

        // Sharing copies the file. Falls back to sharing the row when the
        // library layout is off, which is the pre-§3a behavior.
        let targetAssetID: UUID
        if alreadyPlaced != nil {
            targetAssetID = assetID
        } else {
            targetAssetID = try await Self.copyIntoSpace(
                assetID: assetID, spaceID: spaceID, device: device, req: req
            ) ?? assetID
        }

        return try await req.withPinnedConnection { sql -> CommitUploadResponse in
            try await sql.raw("BEGIN").run()
            do {
                let existing = alreadyPlaced

                guard let placement = try await sql.raw("""
                    INSERT INTO space_assets
                        (space_id, asset_id, uploaded_by_user_id, source_device_id, source_local_id)
                    VALUES
                        (\(bind: spaceID), \(bind: targetAssetID), \(bind: device.userID),
                         \(bind: device.deviceID), \(bind: input.sourceLocalID))
                    ON CONFLICT (space_id, asset_id)
                    DO UPDATE SET deleted_at = NULL
                    RETURNING id
                    """).first(decoding: IDRow.self) else {
                    throw Abort(.internalServerError, reason: "Could not place asset in space.")
                }

                var seq: Int64 = 0
                if existing == nil {
                    seq = try await ChangeLog.append(
                        spaceID: spaceID,
                        entity: "space_asset",
                        entityID: placement.id,
                        op: "insert",
                        on: sql
                    )
                    try await ActivityTracker.record(
                        spaceID: spaceID,
                        userID: device.userID,
                        mediaType: MediaType(rawValue: media.mediaType) ?? .photo,
                        on: sql
                    )
                }

                try await sql.raw("COMMIT").run()

                return CommitUploadResponse(
                    assetID: targetAssetID,
                    spaceAssetID: placement.id,
                    deduplicated: true,
                    changeSeq: seq
                )
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
    }

    // MARK: - Helpers

    private func loadSession(
        uploadID: UUID,
        userID: UUID,
        on sql: any SQLDatabase
    ) async throws -> SessionRow {
        guard let session = try await sql.raw("""
            SELECT id,
                   user_id     AS "userID",
                   space_id    AS "spaceID",
                   sha256,
                   byte_size   AS "byteSize",
                   filename,
                   chunk_count AS "chunkCount",
                   (committed_at IS NOT NULL) AS committed
            FROM upload_sessions
            WHERE id = \(bind: uploadID)
            """).first(decoding: SessionRow.self) else {
            throw Abort(.notFound, reason: "No such upload session.")
        }
        // 404 rather than 403 — another user's session shouldn't be discoverable.
        guard session.userID == userID else {
            throw Abort(.notFound, reason: "No such upload session.")
        }
        return session
    }

    private func missingChunks(
        uploadID: UUID,
        chunkCount: Int,
        on sql: any SQLDatabase
    ) async throws -> [Int] {
        try await sql.raw("""
            SELECT i::int AS idx
            FROM upload_sessions s, generate_series(0, \(bind: chunkCount - 1)) AS i
            WHERE s.id = \(bind: uploadID) AND get_bit(s.received_mask, i) = 0
            ORDER BY i
            """).all(decoding: IndexRow.self).map(\.idx)
    }
}
