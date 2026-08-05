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

        try req.blobStore.writeChunk(
            uploadID: uploadID, index: index, bytes: Data(buffer.readableBytesView)
        )

        try await req.sql.raw("""
            UPDATE upload_sessions
            SET received_mask = set_bit(received_mask, \(bind: index), 1),
                updated_at = now()
            WHERE id = \(bind: uploadID)
            """).run()

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

        let fileExtension = BlobStore.fileExtension(for: session.filename)
        let blob: URL
        do {
            blob = try req.blobStore.assemble(
                uploadID: uploadID,
                chunkCount: session.chunkCount,
                expectedSHA256: session.sha256,
                fileExtension: fileExtension
            )
        } catch let error as BlobStoreError {
            // Staging is already discarded; clear the session so the client can
            // start clean rather than resuming into the same failure.
            try? await req.sql.raw("DELETE FROM upload_sessions WHERE id = \(bind: uploadID)").run()
            req.logger.error("upload \(uploadID) failed to assemble: \(error)")
            throw Abort(.unprocessableEntity, reason: String(describing: error))
        }

        // Move the assembled file to where a person would look for it. Best
        // effort by design: if the library layout is off, or this account has no
        // DSM home, the file stays in the content-addressed store and
        // storage_path stays NULL. Both models read the same way.
        let storagePath = try await Self.placeInLibrary(
            blob: blob, session: session, input: input, device: device, req: req
        )

        let result = try await req.withPinnedConnection { sql -> CommitUploadResponse in
            try await sql.raw("BEGIN").run()
            do {
                let alreadyStored = try await sql.raw("""
                    SELECT id FROM assets WHERE sha256 = \(bind: session.sha256)
                    """).first(decoding: IDRow.self) != nil

                guard let asset = try await sql.raw("""
                    INSERT INTO assets
                        (sha256, byte_size, media_type, mime, blob_ext, width, height, duration_ms,
                         captured_at, captured_tz_off, tz_off_fallback,
                         local_captured_at, lat, lon, is_raw,
                         live_group_id, burst_id, burst_pick, storage_path)
                    VALUES
                        (\(bind: session.sha256), \(bind: session.byteSize),
                         \(bind: input.mediaType.rawValue), \(bind: input.mime),
                         \(bind: fileExtension),
                         \(bind: input.width), \(bind: input.height), \(bind: input.durationMs),
                         \(bind: input.capturedAt), \(bind: input.capturedTZOffset),
                         \(bind: input.capturedTZOffsetFallback),
                         (\(bind: input.capturedAt)
                            + COALESCE(\(bind: input.capturedTZOffset), 0) * interval '1 second')
                            AT TIME ZONE 'UTC',
                         \(bind: input.latitude), \(bind: input.longitude), \(bind: input.isRaw),
                         \(bind: input.liveGroupID), \(bind: input.burstID),
                         \(bind: input.burstPick), \(bind: storagePath))
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

        // Derivatives already exist for content we've seen before.
        if !result.deduplicated {
            // Metadata inline: it's ~50 ms and the timeline needs captured_at
            // and dimensions immediately. Thumbnails are the slow part, so they
            // go to the queue — an import of 100k assets has to be resumable.
            do {
                let metadata = try await MediaProbe.probe(url: blob, mediaType: input.mediaType)
                try await DerivationWorker.applyMetadata(
                    metadata, assetID: result.assetID, on: req.sql,
                    geocoder: req.application.geocoder
                )
            } catch {
                req.logger.warning("inline metadata probe failed for \(session.filename): \(error)")
                try? await DerivationWorker.enqueue(
                    assetID: result.assetID, kind: "metadata", on: req.sql
                )
            }
            try await DerivationWorker.enqueue(
                assetID: result.assetID, kind: "thumbnails", on: req.sql
            )
        }

        req.logger.info(
            "committed \(session.filename) (\(session.byteSize) bytes, dedup: \(result.deduplicated))"
        )
        return result
    }


    /// Puts the committed file where File Station will show it, and returns the
    /// path recorded on the asset.
    ///
    /// Returns nil rather than throwing when the layout can't place the file:
    /// an upload must never fail because a folder couldn't be chosen.
    private static func placeInLibrary(
        blob: URL,
        session: SessionRow,
        input: CommitUploadRequest,
        device: AuthenticatedDevice,
        req: Request
    ) async throws -> String? {
        let configuration = BrowseTree.Configuration.fromEnvironment()
        guard configuration.enabled else { return nil }

        struct ContextRow: Decodable {
            let spaceKind: String
            let spaceName: String
            let dsmUsername: String?
            let dsmUID: Int?
        }
        guard let context = try? await req.sql.raw("""
            SELECT s.kind AS "spaceKind", s.name AS "spaceName",
                   u.dsm_username AS "dsmUsername", u.dsm_uid AS "dsmUID"
            FROM spaces s
            JOIN users u ON u.id = \(bind: device.userID)
            WHERE s.id = \(bind: input.spaceID)
            """).first(decoding: ContextRow.self) else { return nil }

        let placement = BrowseTree.Placement(
            id: UUID(), sha256: session.sha256,
            blobExt: BlobStore.fileExtension(for: session.filename),
            filename: session.filename, capturedAt: input.capturedAt,
            spaceKind: context.spaceKind, spaceName: context.spaceName,
            dsmUsername: context.dsmUsername, dsmUID: context.dsmUID
        )
        guard let intended = BrowseTree.destination(
            for: placement, configuration: configuration
        ) else { return nil }

        // Two photos can share a name -- every phone starts at IMG_0001 -- so a
        // collision suffixes rather than overwrites.
        let destination = BrowseTreeWorker.deduplicated(intended, sha256: session.sha256)
        do {
            let kind = try await BrowseTree.link(
                from: blob.path, to: destination, logger: req.logger
            )
            if let uid = context.dsmUID {
                await BrowseTree.chown(destination, uid: uid, logger: req.logger)
            }
            req.logger.debug("library: \(kind.rawValue) \(destination)")
            return destination
        } catch {
            req.logger.warning("library placement failed, keeping blob: \(error)")
            return nil
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
    /// falls back to sharing the asset row — the pre-§3a behaviour.
    private static func copyIntoSpace(
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

        let placement = BrowseTree.Placement(
            id: UUID(), sha256: source.sha256, blobExt: source.blobExt,
            filename: source.filename, capturedAt: source.capturedAt,
            spaceKind: target.spaceKind, spaceName: target.spaceName,
            dsmUsername: target.dsmUsername, dsmUID: target.dsmUID
        )
        guard let intended = BrowseTree.destination(
            for: placement, configuration: configuration
        ) else { return nil }

        let destination = BrowseTreeWorker.deduplicated(intended, sha256: source.sha256)
        _ = try await BrowseTree.link(
            from: sourcePath, to: destination, logger: req.logger
        )
        if let uid = target.dsmUID {
            await BrowseTree.chown(destination, uid: uid, logger: req.logger)
        }

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
                 is_raw, live_group_id, burst_id, burst_pick, thumbhash, exif,
                 derived_at, storage_path)
            SELECT sha256, byte_size, media_type, mime, blob_ext, width, height, duration_ms,
                   captured_at, captured_tz_off, tz_off_fallback, local_captured_at,
                   lat, lon, place_name, camera_make, camera_model, lens, iso, aperture,
                   shutter, focal_len, exposure_bias, dynamic_range, orientation,
                   is_raw, live_group_id, burst_id, burst_pick, thumbhash, exif,
                   derived_at, \(bind: destination)
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
        // library layout is off, which is the pre-§3a behaviour.
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
