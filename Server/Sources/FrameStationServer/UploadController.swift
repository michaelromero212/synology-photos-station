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

        // Already stored — skip the transfer entirely. This is what makes
        // duplicate family photos and interrupted retries nearly free.
        if let existing = try await req.sql.raw("""
            SELECT id FROM assets WHERE sha256 = \(bind: sha)
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
                         live_group_id, burst_id, burst_pick)
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
                         \(bind: input.liveGroupID), \(bind: input.burstID), \(bind: input.burstPick))
                    ON CONFLICT (sha256) DO UPDATE SET sha256 = EXCLUDED.sha256
                    RETURNING id
                    """).first(decoding: IDRow.self) else {
                    throw Abort(.internalServerError, reason: "Could not record asset.")
                }

                guard let placement = try await sql.raw("""
                    INSERT INTO space_assets
                        (space_id, asset_id, uploaded_by_user_id, source_device_id, source_local_id)
                    VALUES
                        (\(bind: input.spaceID), \(bind: asset.id), \(bind: device.userID),
                         \(bind: device.deviceID), \(bind: input.sourceLocalID))
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

        struct MediaRow: Decodable { let mediaType: String }
        guard let media = try await req.sql.raw("""
            SELECT media_type AS "mediaType" FROM assets WHERE id = \(bind: assetID)
            """).first(decoding: MediaRow.self) else {
            throw Abort(.notFound, reason: "No such asset.")
        }

        return try await req.withPinnedConnection { sql -> CommitUploadResponse in
            try await sql.raw("BEGIN").run()
            do {
                let existing = try await sql.raw("""
                    SELECT id FROM space_assets
                    WHERE space_id = \(bind: spaceID) AND asset_id = \(bind: assetID)
                      AND deleted_at IS NULL
                    """).first(decoding: IDRow.self)

                guard let placement = try await sql.raw("""
                    INSERT INTO space_assets
                        (space_id, asset_id, uploaded_by_user_id, source_device_id, source_local_id)
                    VALUES
                        (\(bind: spaceID), \(bind: assetID), \(bind: device.userID),
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
                    assetID: assetID,
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
