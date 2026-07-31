import FrameStationAPI
import Foundation
import SQLKit
import Vapor

extension AlbumListResponse: @retroactive Content {}
extension AlbumDTO: @retroactive Content {}
extension CreateAlbumRequest: @retroactive Content {}
extension UpdateAlbumRequest: @retroactive Content {}
extension AlbumAssetsRequest: @retroactive Content {}

/// Albums: collections you build by hand, cutting across dates.
///
/// Access is derived entirely from the album's space. There is no album-level
/// permission to keep in step with space membership — the one that would
/// inevitably drift and become the hole.
struct AlbumController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(DeviceTokenAuthenticator())
            .grouped(AuthenticatedDevice.guardMiddleware())

        protected.get("albums", use: list)
        protected.post("albums", use: create)
        protected.get("albums", ":albumID", use: detail)
        protected.patch("albums", ":albumID", use: update)
        protected.delete("albums", ":albumID", use: delete)
        protected.post("albums", ":albumID", "assets", use: addAssets)
        protected.delete("albums", ":albumID", "assets", ":spaceAssetID", use: removeAsset)
    }

    private struct IDRow: Decodable { let id: UUID }

    private struct AlbumRow: Decodable {
        let id: UUID
        let spaceID: UUID
        let spaceName: String
        let name: String
        let itemCount: Int
        let coverAssetID: UUID?
        let createdAt: Date
        let updatedAt: Date
    }

    private func dto(_ row: AlbumRow) -> AlbumDTO {
        AlbumDTO(
            id: row.id, spaceID: row.spaceID, spaceName: row.spaceName, name: row.name,
            itemCount: row.itemCount, coverAssetID: row.coverAssetID,
            createdAt: row.createdAt, updatedAt: row.updatedAt
        )
    }

    // MARK: - Reading

    /// Every album in every space the caller belongs to.
    private func list(_ req: Request) async throws -> AlbumListResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let rows = try await req.sql.raw("""
            \(raw: Self.albumSelect)
            WHERE EXISTS (
                SELECT 1 FROM space_members m
                WHERE m.space_id = a.space_id AND m.user_id = \(bind: device.userID)
            )
            ORDER BY a.updated_at DESC
            """).all(decoding: AlbumRow.self)
        return AlbumListResponse(albums: rows.map(dto))
    }

    private func detail(_ req: Request) async throws -> AlbumDTO {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let albumID = try req.parameters.require("albumID", as: UUID.self)
        return dto(try await requireReadable(albumID, device: device, on: req.sql))
    }

    // MARK: - Writing

    private func create(_ req: Request) async throws -> AlbumDTO {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let input = try req.content.decode(CreateAlbumRequest.self)

        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else {
            throw Abort(.badRequest, reason: "An album needs a name.")
        }
        // Contributor, not merely member: a viewer can look at a shared space
        // but must not reorganise it.
        try await SpaceAccess.requireContributor(
            spaceID: input.spaceID, userID: device.userID, on: req.sql
        )

        guard let created = try await req.sql.raw("""
            INSERT INTO albums (space_id, name, created_by)
            VALUES (\(bind: input.spaceID), \(bind: name), \(bind: device.userID))
            RETURNING id
            """).first(decoding: IDRow.self) else {
            throw Abort(.internalServerError, reason: "Could not create the album.")
        }

        if !input.spaceAssetIDs.isEmpty {
            try await attach(
                input.spaceAssetIDs, to: created.id, spaceID: input.spaceID,
                by: device.userID, on: req.sql
            )
        }
        return dto(try await requireReadable(created.id, device: device, on: req.sql))
    }

    private func update(_ req: Request) async throws -> AlbumDTO {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let albumID = try req.parameters.require("albumID", as: UUID.self)
        let input = try req.content.decode(UpdateAlbumRequest.self)

        let album = try await requireWritable(albumID, device: device, on: req.sql)

        if let raw = input.name {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 120 else {
                throw Abort(.badRequest, reason: "An album needs a name.")
            }
            try await req.sql.raw("""
                UPDATE albums SET name = \(bind: name), updated_at = now()
                WHERE id = \(bind: albumID)
                """).run()
        }

        if let cover = input.coverAssetID {
            // The cover has to be something the album actually contains,
            // otherwise it becomes a way to display an arbitrary asset.
            guard try await req.sql.raw("""
                SELECT sa.id FROM album_assets aa
                JOIN space_assets sa ON sa.id = aa.space_asset_id
                WHERE aa.album_id = \(bind: albumID) AND sa.asset_id = \(bind: cover)
                """).first(decoding: IDRow.self) != nil else {
                throw Abort(.badRequest, reason: "That photo isn't in this album.")
            }
            try await req.sql.raw("""
                UPDATE albums SET cover_asset_id = \(bind: cover), updated_at = now()
                WHERE id = \(bind: albumID)
                """).run()
        }
        _ = album
        return dto(try await requireReadable(albumID, device: device, on: req.sql))
    }

    private func delete(_ req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let albumID = try req.parameters.require("albumID", as: UUID.self)
        _ = try await requireWritable(albumID, device: device, on: req.sql)
        // Only the album row goes; album_assets cascades and the photos
        // themselves are untouched. Deleting a collection must never delete
        // the things collected.
        try await req.sql.raw("DELETE FROM albums WHERE id = \(bind: albumID)").run()
        return .noContent
    }

    private func addAssets(_ req: Request) async throws -> AlbumDTO {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let albumID = try req.parameters.require("albumID", as: UUID.self)
        let input = try req.content.decode(AlbumAssetsRequest.self)

        let album = try await requireWritable(albumID, device: device, on: req.sql)
        try await attach(
            input.spaceAssetIDs, to: albumID, spaceID: album.spaceID,
            by: device.userID, on: req.sql
        )
        return dto(try await requireReadable(albumID, device: device, on: req.sql))
    }

    private func removeAsset(_ req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let albumID = try req.parameters.require("albumID", as: UUID.self)
        let placementID = try req.parameters.require("spaceAssetID", as: UUID.self)

        _ = try await requireWritable(albumID, device: device, on: req.sql)
        try await req.sql.raw("""
            DELETE FROM album_assets
            WHERE album_id = \(bind: albumID) AND space_asset_id = \(bind: placementID)
            """).run()
        try await refreshCover(albumID, on: req.sql)
        return .noContent
    }

    // MARK: - Helpers

    /// Adds placements, ignoring any that don't belong to this album's space.
    ///
    /// That filter is the whole security story for albums: because
    /// `album_assets` points at a placement, and a placement is only ever
    /// visible to members of its space, an album physically cannot contain a
    /// photo the space's members couldn't already see.
    private func attach(
        _ placementIDs: [UUID], to albumID: UUID, spaceID: UUID,
        by userID: UUID, on sql: any SQLDatabase
    ) async throws {
        guard !placementIDs.isEmpty else { return }
        guard placementIDs.count <= 500 else {
            throw Abort(.badRequest, reason: "Add at most 500 photos at a time.")
        }

        for placementID in placementIDs {
            try await sql.raw("""
                INSERT INTO album_assets (album_id, space_asset_id, added_by, position)
                SELECT \(bind: albumID), sa.id, \(bind: userID),
                       COALESCE(
                           (SELECT MAX(position) + 1 FROM album_assets WHERE album_id = \(bind: albumID)),
                           0
                       )
                FROM space_assets sa
                WHERE sa.id = \(bind: placementID)
                  AND sa.space_id = \(bind: spaceID)
                  AND sa.deleted_at IS NULL
                ON CONFLICT (album_id, space_asset_id) DO NOTHING
                """).run()
        }
        try await refreshCover(albumID, on: sql)
        try await sql.raw("""
            UPDATE albums SET updated_at = now() WHERE id = \(bind: albumID)
            """).run()
    }

    /// Keeps the cover pointing at something that is still in the album.
    private func refreshCover(_ albumID: UUID, on sql: any SQLDatabase) async throws {
        try await sql.raw("""
            UPDATE albums SET cover_asset_id = (
                SELECT sa.asset_id
                FROM album_assets aa
                JOIN space_assets sa ON sa.id = aa.space_asset_id
                WHERE aa.album_id = \(bind: albumID) AND sa.deleted_at IS NULL
                ORDER BY aa.position, aa.added_at
                LIMIT 1
            )
            WHERE id = \(bind: albumID)
              AND (
                  cover_asset_id IS NULL
                  OR NOT EXISTS (
                      SELECT 1 FROM album_assets aa2
                      JOIN space_assets sa2 ON sa2.id = aa2.space_asset_id
                      WHERE aa2.album_id = \(bind: albumID)
                        AND sa2.asset_id = albums.cover_asset_id
                  )
              )
            """).run()
    }

    /// 404 rather than 403 throughout: a refused album must not confirm one
    /// with that id exists.
    private func requireReadable(
        _ albumID: UUID, device: AuthenticatedDevice, on sql: any SQLDatabase
    ) async throws -> AlbumRow {
        guard let row = try await sql.raw("""
            \(raw: Self.albumSelect)
            WHERE a.id = \(bind: albumID)
              AND EXISTS (
                  SELECT 1 FROM space_members m
                  WHERE m.space_id = a.space_id AND m.user_id = \(bind: device.userID)
              )
            """).first(decoding: AlbumRow.self) else {
            throw Abort(.notFound, reason: "No such album.")
        }
        return row
    }

    private func requireWritable(
        _ albumID: UUID, device: AuthenticatedDevice, on sql: any SQLDatabase
    ) async throws -> AlbumRow {
        let album = try await requireReadable(albumID, device: device, on: sql)
        try await SpaceAccess.requireContributor(
            spaceID: album.spaceID, userID: device.userID, on: sql
        )
        return album
    }

    private static let albumSelect = """
        SELECT a.id, a.space_id AS "spaceID", s.name AS "spaceName", a.name,
               a.cover_asset_id AS "coverAssetID",
               a.created_at AS "createdAt", a.updated_at AS "updatedAt",
               (SELECT count(*) FROM album_assets aa
                JOIN space_assets sa ON sa.id = aa.space_asset_id
                WHERE aa.album_id = a.id AND sa.deleted_at IS NULL)::int AS "itemCount"
        FROM albums a
        JOIN spaces s ON s.id = a.space_id
        """
}
