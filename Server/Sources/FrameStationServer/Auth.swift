import Crypto
import Foundation
import FrameStationAPI
import Vapor

/// The authenticated caller: a specific device belonging to a specific user.
struct AuthenticatedDevice: Authenticatable {
    let deviceID: UUID
    let userID: UUID
    let displayName: String

    var user: UserDTO { UserDTO(id: userID, displayName: displayName) }
}

/// Opaque bearer tokens. The database stores only a SHA-256 hash, so a dump of
/// `devices` cannot be replayed against the API.
enum DeviceToken {
    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Short, human-typable, single-use. Alphabet excludes 0/O/1/I/L so a code read
/// aloud across the kitchen survives the trip.
enum InviteCode {
    private static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        let characters = (0..<8).map { _ in alphabet.randomElement(using: &generator)! }
        return String(characters[0..<4]) + "-" + String(characters[4..<8])
    }
}

struct DeviceTokenAuthenticator: AsyncBearerAuthenticator {
    private struct Row: Decodable {
        let deviceID: UUID
        let userID: UUID
        let displayName: String
    }

    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        let hash = DeviceToken.hash(bearer.token)

        guard let row = try await request.sql.raw("""
            SELECT d.id AS "deviceID", d.user_id AS "userID", u.display_name AS "displayName"
            FROM devices d
            JOIN users u ON u.id = d.user_id
            WHERE d.token_hash = \(bind: hash)
            """).first(decoding: Row.self)
        else {
            return  // Unauthenticated; the guard middleware turns this into a 401.
        }

        // Liveness stamp, throttled to one write per device per five minutes so
        // a scrolling client doesn't generate a write per request.
        try await request.sql.raw("""
            UPDATE devices SET last_seen_at = now()
            WHERE id = \(bind: row.deviceID)
              AND (last_seen_at IS NULL OR last_seen_at < now() - interval '5 minutes')
            """).run()

        request.auth.login(
            AuthenticatedDevice(
                deviceID: row.deviceID,
                userID: row.userID,
                displayName: row.displayName
            )
        )
    }
}
