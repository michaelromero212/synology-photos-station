import FrameStationAPI
import Foundation
import SQLKit
import Vapor

extension DSMLoginRequest: @retroactive Content {}
extension DSMLoginResponse: @retroactive Content {}

/// `POST /v1/auth/dsm` — sign in with a Synology DSM account.
///
/// Creates the FrameStation user and their personal space on first sign-in, so
/// there is no separate account to set up. Sits alongside the invite flow, which
/// stays for anyone without a DSM account.
struct DSMAuthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.post("auth", "dsm", use: login)
    }

    private struct UserRow: Decodable {
        let id: UUID
        let displayName: String
    }
    private struct IDRow: Decodable { let id: UUID }
    private struct SpaceRow: Decodable {
        let id: UUID
        let name: String
        let kind: String
        let role: String
        let memberCount: Int
    }

    @Sendable
    func login(req: Request) async throws -> DSMLoginResponse {
        let input = try req.content.decode(DSMLoginRequest.self)

        let username = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceName = input.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !input.password.isEmpty, !deviceName.isEmpty else {
            throw Abort(.badRequest, reason: "Username, password, and device name are required.")
        }

        guard let dsmURL = Environment.get("FRAMESTATION_DSM_URL") else {
            throw Abort(.notImplemented, reason: """
                DSM sign-in isn't configured. Set FRAMESTATION_DSM_URL to the NAS's \
                DSM address, or use an invite code.
                """)
        }

        let identity: DSMAuth.Identity
        do {
            identity = try await DSMAuth(
                baseURL: dsmURL, client: req.client, logger: req.logger
            ).authenticate(username: username, password: input.password)
        } catch let failure as DSMAuth.Failure {
            throw Abort(failure.status, reason: failure.description)
        }

        let token = DeviceToken.generate()
        let tokenHash = DeviceToken.hash(token)

        return try await req.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                // Case-insensitive: DSM treats usernames that way, and matching
                // case-sensitively here would silently create a second account
                // for the same person.
                let existing = try await sql.raw("""
                    SELECT id, display_name AS "displayName" FROM users
                    WHERE lower(dsm_username) = lower(\(bind: username))
                    """).first(decoding: UserRow.self)

                let user: UserRow
                let isNew: Bool
                if let existing {
                    user = existing
                    isNew = false
                    // Refresh uid and home — a DSM rebuild or a home-service
                    // toggle can change them under us.
                    try await sql.raw("""
                        UPDATE users
                        SET dsm_uid = \(bind: identity.uid), dsm_home = \(bind: identity.homeDirectory)
                        WHERE id = \(bind: existing.id)
                        """).run()
                } else {
                    guard let created = try await sql.raw("""
                        INSERT INTO users (display_name, dsm_username, dsm_uid, dsm_home)
                        VALUES (\(bind: username), \(bind: username),
                                \(bind: identity.uid), \(bind: identity.homeDirectory))
                        RETURNING id, display_name AS "displayName"
                        """).first(decoding: UserRow.self) else {
                        throw Abort(.internalServerError, reason: "Could not create the account.")
                    }
                    user = created
                    isNew = true

                    guard let space = try await sql.raw("""
                        INSERT INTO spaces (kind, name, created_by)
                        VALUES ('personal', 'Personal Space', \(bind: created.id))
                        RETURNING id
                        """).first(decoding: IDRow.self) else {
                        throw Abort(.internalServerError, reason: "Could not create the library.")
                    }
                    try await sql.raw("""
                        INSERT INTO space_members (space_id, user_id, role)
                        VALUES (\(bind: space.id), \(bind: created.id), 'owner')
                        """).run()
                }

                guard let device = try await sql.raw("""
                    INSERT INTO devices (user_id, name, platform, token_hash)
                    VALUES (\(bind: user.id), \(bind: deviceName),
                            \(bind: input.platform.rawValue), \(bind: tokenHash))
                    RETURNING id
                    """).first(decoding: IDRow.self) else {
                    throw Abort(.internalServerError, reason: "Could not register the device.")
                }

                let spaceRows = try await sql.raw("""
                    SELECT s.id, s.name, s.kind, m.role,
                           (SELECT count(*)::int FROM space_members WHERE space_id = s.id) AS "memberCount"
                    FROM spaces s
                    JOIN space_members m ON m.space_id = s.id
                    WHERE m.user_id = \(bind: user.id)
                    ORDER BY s.kind, s.name
                    """).all(decoding: SpaceRow.self)

                try await sql.raw("COMMIT").run()

                req.logger.info("DSM sign-in: \(username)\(isNew ? " (new account)" : "") on \(deviceName)")

                return DSMLoginResponse(
                    token: token,
                    user: UserDTO(id: user.id, displayName: user.displayName),
                    deviceID: device.id,
                    spaces: spaceRows.map {
                        SpaceDTO(
                            id: $0.id,
                            kind: SpaceKind(rawValue: $0.kind) ?? .personal,
                            name: $0.name,
                            role: SpaceRole(rawValue: $0.role) ?? .contributor,
                            memberCount: $0.memberCount
                        )
                    },
                    isNewAccount: isNew
                )
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
    }
}
