import FrameStationAPI
import Foundation
import SQLKit
import Vapor

/// Per-user favourites.
///
/// Stored in `space_asset_favorites` keyed on (placement, user) rather than as a
/// boolean column, because in a shared space "Mom favourited this" and "I
/// favourited this" are different facts and a single column can only hold one.
struct FavoriteController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(DeviceTokenAuthenticator())
            .grouped(AuthenticatedDevice.guardMiddleware())

        protected.put("spaces", ":spaceID", "assets", ":assetID", "favorite", use: set)
        protected.delete("spaces", ":spaceID", "assets", ":assetID", "favorite", use: clear)
    }

    private struct IDRow: Decodable { let id: UUID }

    private func placement(_ req: Request) async throws -> (id: UUID, spaceID: UUID) {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let assetID = try req.parameters.require("assetID", as: UUID.self)

        try await SpaceAccess.requireMembership(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )

        guard let row = try await req.sql.raw("""
            SELECT id FROM space_assets
            WHERE space_id = \(bind: spaceID) AND asset_id = \(bind: assetID)
              AND deleted_at IS NULL
            """).first(decoding: IDRow.self) else {
            throw Abort(.notFound, reason: "No such asset in this space.")
        }
        return (row.id, spaceID)
    }

    @Sendable
    func set(req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let target = try await placement(req)

        try await req.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                try await sql.raw("""
                    INSERT INTO space_asset_favorites (space_asset_id, user_id)
                    VALUES (\(bind: target.id), \(bind: device.userID))
                    ON CONFLICT DO NOTHING
                    """).run()
                // Other devices belonging to this user need to see the change,
                // so it goes through the same delta-sync path as everything else.
                _ = try await ChangeLog.append(
                    spaceID: target.spaceID, entity: "space_asset",
                    entityID: target.id, op: "update", on: sql
                )
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
        return .noContent
    }

    @Sendable
    func clear(req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let target = try await placement(req)

        try await req.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                try await sql.raw("""
                    DELETE FROM space_asset_favorites
                    WHERE space_asset_id = \(bind: target.id) AND user_id = \(bind: device.userID)
                    """).run()
                _ = try await ChangeLog.append(
                    spaceID: target.spaceID, entity: "space_asset",
                    entityID: target.id, op: "update", on: sql
                )
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
        return .noContent
    }
}
