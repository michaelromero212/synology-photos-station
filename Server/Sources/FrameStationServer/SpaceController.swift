import FrameStationAPI
import Foundation
import SQLKit
import Vapor

extension CreateSpaceRequest: @retroactive Content {}
extension RenameSpaceRequest: @retroactive Content {}
extension SpaceMembersResponse: @retroactive Content {}
extension HouseholdResponse: @retroactive Content {}
extension AddMemberRequest: @retroactive Content {}
extension SpaceDTO: @retroactive Content {}

/// Creating and managing shared spaces.
///
/// Personal spaces are created once at invite redemption and are not manageable
/// here — you cannot rename, share, or leave your own library.
struct SpaceController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(DeviceTokenAuthenticator())
            .grouped(AuthenticatedDevice.guardMiddleware())

        protected.get("household", use: household)
        protected.post("spaces", use: create)
        protected.patch("spaces", ":spaceID", use: rename)
        protected.get("spaces", ":spaceID", "members", use: members)
        protected.put("spaces", ":spaceID", "members", ":userID", use: addMember)
        protected.delete("spaces", ":spaceID", "members", ":userID", use: removeMember)
    }

    private struct IDRow: Decodable { let id: UUID }
    private struct UserRow: Decodable { let id: UUID; let displayName: String }
    private struct SpaceRow: Decodable { let id: UUID; let name: String; let kind: String }
    private struct MemberRow: Decodable {
        let userID: UUID
        let displayName: String
        let role: String
        let joinedAt: Date
        let contributedCount: Int
    }

    // MARK: - Household

    @Sendable
    func household(req: Request) async throws -> HouseholdResponse {
        _ = try req.auth.require(AuthenticatedDevice.self)
        let rows = try await req.sql.raw("""
            SELECT id, display_name AS "displayName" FROM users ORDER BY display_name
            """).all(decoding: UserRow.self)
        return HouseholdResponse(
            users: rows.map { UserDTO(id: $0.id, displayName: $0.displayName) }
        )
    }

    // MARK: - Create

    @Sendable
    func create(req: Request) async throws -> SpaceDTO {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let input = try req.content.decode(CreateSpaceRequest.self)

        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else {
            throw Abort(.badRequest, reason: "Give the space a name of 1–60 characters.")
        }

        // Creator plus whoever was picked, de-duplicated so passing yourself in
        // the member list doesn't violate the primary key.
        let others = Set(input.memberIDs).subtracting([device.userID])

        return try await req.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                guard let space = try await sql.raw("""
                    INSERT INTO spaces (kind, name, created_by)
                    VALUES ('shared', \(bind: name), \(bind: device.userID))
                    RETURNING id
                    """).first(decoding: IDRow.self) else {
                    throw Abort(.internalServerError, reason: "Could not create the space.")
                }

                try await sql.raw("""
                    INSERT INTO space_members (space_id, user_id, role)
                    VALUES (\(bind: space.id), \(bind: device.userID), 'owner')
                    """).run()

                for userID in others {
                    try await sql.raw("""
                        INSERT INTO space_members (space_id, user_id, role)
                        VALUES (\(bind: space.id), \(bind: userID), 'contributor')
                        ON CONFLICT DO NOTHING
                        """).run()
                }

                try await sql.raw("COMMIT").run()

                return SpaceDTO(
                    id: space.id, kind: .shared, name: name,
                    role: .owner, memberCount: others.count + 1
                )
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
    }

    // MARK: - Rename

    @Sendable
    func rename(req: Request) async throws -> SpaceDTO {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let input = try req.content.decode(RenameSpaceRequest.self)

        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else {
            throw Abort(.badRequest, reason: "Give the space a name of 1–60 characters.")
        }

        let space = try await requireSpace(spaceID, req)
        guard space.kind == "shared" else {
            throw Abort(.forbidden, reason: "Your personal library can't be renamed.")
        }
        try await requireOwner(spaceID: spaceID, userID: device.userID, on: req.sql)

        try await req.sql.raw("""
            UPDATE spaces SET name = \(bind: name) WHERE id = \(bind: spaceID)
            """).run()

        struct CountRow: Decodable { let count: Int }
        let count = try await req.sql.raw("""
            SELECT count(*)::int AS count FROM space_members WHERE space_id = \(bind: spaceID)
            """).first(decoding: CountRow.self)?.count ?? 1

        return SpaceDTO(id: spaceID, kind: .shared, name: name, role: .owner, memberCount: count)
    }

    // MARK: - Members

    @Sendable
    func members(req: Request) async throws -> SpaceMembersResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)

        let role = try await SpaceAccess.requireMembership(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )
        let space = try await requireSpace(spaceID, req)

        let rows = try await req.sql.raw("""
            SELECT u.id AS "userID",
                   u.display_name AS "displayName",
                   m.role,
                   m.joined_at AS "joinedAt",
                   (SELECT count(*)::int FROM space_assets sa
                    WHERE sa.space_id = m.space_id
                      AND sa.uploaded_by_user_id = u.id
                      AND sa.deleted_at IS NULL) AS "contributedCount"
            FROM space_members m
            JOIN users u ON u.id = m.user_id
            WHERE m.space_id = \(bind: spaceID)
            ORDER BY (m.role = 'owner') DESC, u.display_name
            """).all(decoding: MemberRow.self)

        return SpaceMembersResponse(
            spaceID: spaceID,
            name: space.name,
            kind: SpaceKind(rawValue: space.kind) ?? .shared,
            callerIsOwner: role == .owner,
            members: rows.map {
                SpaceMemberDTO(
                    user: UserDTO(id: $0.userID, displayName: $0.displayName),
                    role: SpaceRole(rawValue: $0.role) ?? .contributor,
                    joinedAt: $0.joinedAt,
                    contributedCount: $0.contributedCount
                )
            }
        )
    }

    @Sendable
    func addMember(req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let userID = try req.parameters.require("userID", as: UUID.self)
        let input = (try? req.content.decode(AddMemberRequest.self)) ?? AddMemberRequest()

        let space = try await requireSpace(spaceID, req)
        guard space.kind == "shared" else {
            throw Abort(.forbidden, reason: "Your personal library can't be shared.")
        }
        try await requireOwner(spaceID: spaceID, userID: device.userID, on: req.sql)

        guard try await req.sql.raw("SELECT id FROM users WHERE id = \(bind: userID)")
            .first(decoding: IDRow.self) != nil else {
            throw Abort(.notFound, reason: "No such user.")
        }
        // Owners are never demoted by an add; that would be a way to lock
        // yourself out of your own space.
        guard input.role != .owner else {
            throw Abort(.badRequest, reason: "A space has one owner.")
        }

        try await req.sql.raw("""
            INSERT INTO space_members (space_id, user_id, role)
            VALUES (\(bind: spaceID), \(bind: userID), \(bind: input.role.rawValue))
            ON CONFLICT (space_id, user_id) DO UPDATE SET role = EXCLUDED.role
            WHERE space_members.role <> 'owner'
            """).run()

        return .noContent
    }

    @Sendable
    func removeMember(req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let userID = try req.parameters.require("userID", as: UUID.self)

        let space = try await requireSpace(spaceID, req)
        guard space.kind == "shared" else {
            throw Abort(.forbidden, reason: "You can't leave your personal library.")
        }

        // Owner can remove anyone; anyone can remove themselves (leaving).
        if userID != device.userID {
            try await requireOwner(spaceID: spaceID, userID: device.userID, on: req.sql)
        }

        struct RoleRow: Decodable { let role: String }
        let target = try await req.sql.raw("""
            SELECT role FROM space_members
            WHERE space_id = \(bind: spaceID) AND user_id = \(bind: userID)
            """).first(decoding: RoleRow.self)
        guard let target else {
            throw Abort(.notFound, reason: "That person isn't in this space.")
        }
        // Removing the owner would orphan the space and everything in it.
        guard target.role != "owner" else {
            throw Abort(.forbidden, reason: "The owner can't be removed. Delete the space instead.")
        }

        try await req.sql.raw("""
            DELETE FROM space_members
            WHERE space_id = \(bind: spaceID) AND user_id = \(bind: userID)
            """).run()

        return .noContent
    }

    // MARK: - Helpers

    private func requireSpace(_ spaceID: UUID, _ req: Request) async throws -> SpaceRow {
        guard let space = try await req.sql.raw("""
            SELECT id, name, kind FROM spaces WHERE id = \(bind: spaceID)
            """).first(decoding: SpaceRow.self) else {
            throw Abort(.notFound, reason: "No such space.")
        }
        return space
    }

    private func requireOwner(spaceID: UUID, userID: UUID, on sql: any SQLDatabase) async throws {
        let role = try await SpaceAccess.requireMembership(
            spaceID: spaceID, userID: userID, on: sql
        )
        guard role == .owner else {
            throw Abort(.forbidden, reason: "Only the space owner can do that.")
        }
    }
}
