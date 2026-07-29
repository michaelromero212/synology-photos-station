import FrameStationAPI
import Foundation
import SQLKit
import Vapor

/// Serves originals and derivatives.
///
/// Access is by *membership*, not ownership: you may read an asset if it is
/// placed in any space you belong to. That is what makes Family Shared work
/// without duplicating a byte.
struct AssetController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(DeviceTokenAuthenticator())
            .grouped(AuthenticatedDevice.guardMiddleware())

        protected.get("assets", ":assetID", "thumb", use: thumbnail)
        protected.get("assets", ":assetID", "preview", use: preview)
        protected.get("assets", ":assetID", "original", use: original)
    }

    private struct AssetRow: Decodable {
        let id: UUID
        let sha256: String
        let mediaType: String
        let blobExt: String
        let mime: String
    }

    // MARK: - Endpoints

    @Sendable
    func thumbnail(req: Request) async throws -> Response {
        let asset = try await requireReadableAsset(req)
        let size = req.query[Int.self, at: "size"] ?? 256
        guard Derivatives.eagerSizes.contains(size) else {
            throw Abort(.badRequest,
                        reason: "size must be one of \(Derivatives.eagerSizes.map(String.init).joined(separator: ", ")).")
        }

        let path = req.blobStore.derivativePath(sha256: asset.sha256, name: "thumb-\(size).jpg")
        guard FileManager.default.fileExists(atPath: path.path) else {
            // Still queued, or the queue failed. 202 rather than 404 so the
            // client knows to keep the ThumbHash placeholder and retry, instead
            // of caching a miss forever.
            throw Abort(.accepted, reason: "Thumbnail not generated yet.")
        }
        return try await streamFile(req, at: path, contentType: "image/jpeg", immutable: true)
    }

    /// Full-screen preview, rendered on first request.
    ///
    /// Generating all 100k of these eagerly would cost ~40 GB and turn the
    /// import into a multi-day job; most photos are never opened full screen.
    @Sendable
    func preview(req: Request) async throws -> Response {
        let asset = try await requireReadableAsset(req)
        let blob = req.blobStore.blobPath(sha256: asset.sha256, fileExtension: asset.blobExt)
        guard FileManager.default.fileExists(atPath: blob.path) else {
            throw Abort(.notFound, reason: "Original is missing from storage.")
        }

        let path = try await Derivatives.makePreview(
            blob: blob,
            sha256: asset.sha256,
            mediaType: MediaType(rawValue: asset.mediaType) ?? .photo,
            store: req.blobStore
        )
        return try await streamFile(req, at: path, contentType: "image/jpeg", immutable: true)
    }

    /// Byte-exact original. Range-capable so video scrubbing works.
    @Sendable
    func original(req: Request) async throws -> Response {
        let asset = try await requireReadableAsset(req)
        let blob = req.blobStore.blobPath(sha256: asset.sha256, fileExtension: asset.blobExt)
        guard FileManager.default.fileExists(atPath: blob.path) else {
            throw Abort(.notFound, reason: "Original is missing from storage.")
        }
        return try await streamFile(req, at: blob, contentType: asset.mime, immutable: true)
    }

    // MARK: - Helpers

    private func requireReadableAsset(_ req: Request) async throws -> AssetRow {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let assetID = try req.parameters.require("assetID", as: UUID.self)

        // 404 rather than 403 on a non-member: the existence of an asset is
        // itself information someone outside the space shouldn't get.
        guard let asset = try await req.sql.raw("""
            SELECT a.id,
                   a.sha256,
                   a.media_type AS "mediaType",
                   a.blob_ext   AS "blobExt",
                   a.mime
            FROM assets a
            WHERE a.id = \(bind: assetID)
              AND EXISTS (
                  SELECT 1
                  FROM space_assets sa
                  JOIN space_members m ON m.space_id = sa.space_id
                  WHERE sa.asset_id = a.id
                    AND sa.deleted_at IS NULL
                    AND m.user_id = \(bind: device.userID)
              )
            """).first(decoding: AssetRow.self) else {
            throw Abort(.notFound, reason: "No such asset.")
        }
        return asset
    }

    private func streamFile(
        _ req: Request,
        at path: URL,
        contentType: String,
        immutable: Bool
    ) async throws -> Response {
        let response = try await req.fileio.asyncStreamFile(at: path.path)
        response.headers.replaceOrAdd(name: .contentType, value: contentType)
        if immutable {
            // Everything here is content-addressed, so a given URL's bytes can
            // never change. Cache hard — this is most of what makes scrolling
            // back through the timeline feel instant.
            response.headers.replaceOrAdd(
                name: .cacheControl, value: "private, max-age=31536000, immutable"
            )
        }
        return response
    }
}
