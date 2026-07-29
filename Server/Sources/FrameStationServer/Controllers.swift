import Foundation
import FrameStationAPI
import SQLKit
import Vapor

// Wire types are defined in FrameStationAPI, which knows nothing about Vapor.
// Content conformance is added here, server-side only.
extension HealthResponse: @retroactive Content {}
extension RedeemInviteRequest: @retroactive Content {}
extension RedeemInviteResponse: @retroactive Content {}
extension MeResponse: @retroactive Content {}
extension RegisterPushTokenRequest: @retroactive Content {}

// MARK: - Health

struct HealthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("health", use: health)
    }

    private struct CountRow: Decodable { let count: Int }

    @Sendable
    func health(req: Request) async throws -> HealthResponse {
        var database = "up"
        var migrations = 0
        do {
            let row = try await req.sql
                .raw("SELECT count(*)::int AS count FROM schema_migrations")
                .first(decoding: CountRow.self)
            migrations = row?.count ?? 0
        } catch {
            req.logger.error("health check database probe failed: \(error)")
            database = "down"
        }

        return HealthResponse(
            status: database == "up" ? "ok" : "degraded",
            version: Build.version,
            database: database,
            migrationsApplied: migrations
        )
    }
}

// MARK: - Auth

struct AuthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.post("auth", "redeem", use: redeem)
    }

    private struct IDRow: Decodable { let id: UUID }

    @Sendable
    func redeem(req: Request) async throws -> RedeemInviteResponse {
        let input = try req.content.decode(RedeemInviteRequest.self)

        let displayName = input.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceName = input.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty, !deviceName.isEmpty else {
            throw Abort(.badRequest, reason: "displayName and deviceName are required.")
        }

        let code = input.code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let token = DeviceToken.generate()
        let tokenHash = DeviceToken.hash(token)

        // Pinned to one connection so BEGIN/COMMIT actually bracket the work —
        // a pooled SQLDatabase would scatter these across connections.
        return try await req.application.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                // FOR UPDATE closes the race where two devices redeem the same
                // code simultaneously.
                let invite = try await sql.raw("""
                    SELECT code AS id FROM invites
                    WHERE code = \(bind: code)
                      AND redeemed_at IS NULL
                      AND expires_at > now()
                    FOR UPDATE
                    """).first()

                guard invite != nil else {
                    try await sql.raw("ROLLBACK").run()
                    throw Abort(.unauthorized, reason: "That invite code is invalid, expired, or already used.")
                }

                guard let user = try await sql.raw("""
                    INSERT INTO users (display_name) VALUES (\(bind: displayName))
                    RETURNING id
                    """).first(decoding: IDRow.self) else {
                    throw Abort(.internalServerError, reason: "Could not create user.")
                }

                guard let space = try await sql.raw("""
                    INSERT INTO spaces (kind, name, created_by)
                    VALUES ('personal', 'Personal Space', \(bind: user.id))
                    RETURNING id
                    """).first(decoding: IDRow.self) else {
                    throw Abort(.internalServerError, reason: "Could not create personal space.")
                }

                try await sql.raw("""
                    INSERT INTO space_members (space_id, user_id, role)
                    VALUES (\(bind: space.id), \(bind: user.id), 'owner')
                    """).run()

                guard let device = try await sql.raw("""
                    INSERT INTO devices (user_id, name, platform, token_hash)
                    VALUES (\(bind: user.id), \(bind: deviceName),
                            \(bind: input.platform.rawValue), \(bind: tokenHash))
                    RETURNING id
                    """).first(decoding: IDRow.self) else {
                    throw Abort(.internalServerError, reason: "Could not register device.")
                }

                try await sql.raw("""
                    UPDATE invites
                    SET redeemed_at = now(), redeemed_by = \(bind: user.id)
                    WHERE code = \(bind: code)
                    """).run()

                try await sql.raw("COMMIT").run()

                req.logger.info("invite redeemed by \(displayName) on \(deviceName)")

                return RedeemInviteResponse(
                    token: token,
                    user: UserDTO(id: user.id, displayName: displayName),
                    deviceID: device.id,
                    personalSpace: SpaceDTO(
                        id: space.id,
                        kind: .personal,
                        name: "Personal Space",
                        role: .owner,
                        memberCount: 1
                    )
                )
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
    }
}

// MARK: - Session

struct SessionController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(DeviceTokenAuthenticator())
            .grouped(AuthenticatedDevice.guardMiddleware())

        protected.get("me", use: me)
        protected.post("devices", "push-token", use: registerPushToken)
    }

    private struct SpaceRow: Decodable {
        let id: UUID
        let kind: String
        let name: String
        let role: String
        let memberCount: Int
    }

    @Sendable
    func me(req: Request) async throws -> MeResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)

        let rows = try await req.sql.raw("""
            SELECT s.id,
                   s.kind,
                   s.name,
                   m.role,
                   (SELECT count(*)::int FROM space_members WHERE space_id = s.id) AS "memberCount"
            FROM spaces s
            JOIN space_members m ON m.space_id = s.id
            WHERE m.user_id = \(bind: device.userID)
            ORDER BY s.kind, s.name
            """).all(decoding: SpaceRow.self)

        let spaces = rows.map {
            SpaceDTO(
                id: $0.id,
                kind: SpaceKind(rawValue: $0.kind) ?? .shared,
                name: $0.name,
                role: SpaceRole(rawValue: $0.role) ?? .contributor,
                memberCount: $0.memberCount
            )
        }

        return MeResponse(user: device.user, deviceID: device.deviceID, spaces: spaces)
    }

    @Sendable
    func registerPushToken(req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let input = try req.content.decode(RegisterPushTokenRequest.self)

        try await req.sql.raw("""
            UPDATE devices
            SET apns_token = \(bind: input.apnsToken),
                apns_env   = \(bind: input.environment.rawValue)
            WHERE id = \(bind: device.deviceID)
            """).run()

        return .noContent
    }
}
