import Foundation
import FrameStationAPI
import SQLKit
import Vapor

/// Deleting your own account, from the app — which the App Store requires of
/// any app where an account can be made, and invite codes make them.
///
/// What goes: the account itself, every device signed in to it, the person's
/// own library and their own albums. What stays: photos they added to a shared
/// library, which are the family's now — the way a message stays in a group
/// chat after someone leaves it. Those keep pointing at the account's row,
/// which is why the row itself stays, emptied of anything personal: named
/// "Former member", unlinked from DSM, with no device left that could sign
/// in to it.
///
/// Photos go the way any removed photo goes. They leave every screen and every
/// File Station folder at once, and their files are deleted from the NAS when
/// the retention window closes, `Retention.days` days on. Not sooner: two taps
/// on an unlocked phone in the wrong hands shouldn't be the end of a library
/// with nothing left to recover from.
struct AccountController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(DeviceTokenAuthenticator())
            .grouped(AuthenticatedDevice.guardMiddleware())

        protected.delete("me", use: deleteAccount)
    }

    private struct Owned: Decodable {
        let spaceID: UUID
        /// Who it's handed to: whoever has been in it longest, a contributor
        /// before a viewer. Nil when no one else is in it.
        let heir: UUID?
    }

    @Sendable
    func deleteAccount(req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let userID = device.userID

        try await req.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                // Shared libraries they own: handed on to the family, or — with
                // no one else in them — gone with them, like their own library.
                let owned = try await sql.raw("""
                    SELECT s.id AS "spaceID",
                           (SELECT other.user_id FROM space_members other
                            WHERE other.space_id = s.id AND other.user_id <> \(bind: userID)
                            ORDER BY (other.role = 'viewer'), other.joined_at
                            LIMIT 1) AS heir
                    FROM spaces s
                    JOIN space_members m ON m.space_id = s.id
                    WHERE m.user_id = \(bind: userID) AND m.role = 'owner'
                      AND s.kind = 'shared'
                    """).all(decoding: Owned.self)

                var departing: [UUID] = []
                for library in owned {
                    if let heir = library.heir {
                        try await sql.raw("""
                            UPDATE space_members SET role = 'owner'
                            WHERE space_id = \(bind: library.spaceID) AND user_id = \(bind: heir)
                            """).run()
                    } else {
                        departing.append(library.spaceID)
                    }
                }

                // Their own library, and any shared one no one else is left in:
                // every photo removed, to be deleted from the NAS when the window
                // closes. Ones already in Recently Deleted keep their own clock.
                try await sql.raw("""
                    UPDATE space_assets
                    SET deleted_at = now(), deleted_by = \(bind: userID)
                    WHERE deleted_at IS NULL
                      AND (space_id = ANY(\(bind: departing))
                           OR space_id IN (SELECT id FROM spaces
                                           WHERE kind = 'personal'
                                             AND created_by = \(bind: userID)))
                    """).run()

                // Their own albums, and the albums of the libraries going with
                // them. Shared albums in a library the family keeps stay with it.
                try await sql.raw("""
                    DELETE FROM albums
                    WHERE (space_id IS NULL AND owner_user_id = \(bind: userID))
                       OR space_id = ANY(\(bind: departing))
                    """).run()

                // Out of every library. This is also what takes their copies out
                // of File Station: the browse tree withdraws a member's copies
                // from a library they're no longer in on its next pass.
                try await sql.raw("""
                    DELETE FROM space_members WHERE user_id = \(bind: userID)
                    """).run()

                // Everything else that was theirs alone.
                for statement: SQLQueryString in [
                    "DELETE FROM space_asset_favorites WHERE user_id = \(bind: userID)",
                    "DELETE FROM occasion_names WHERE user_id = \(bind: userID)",
                    "DELETE FROM media_observations WHERE user_id = \(bind: userID)",
                    "DELETE FROM curated_albums WHERE user_id = \(bind: userID)",
                    "DELETE FROM content_reports WHERE reporter_id = \(bind: userID)",
                    """
                    DELETE FROM user_blocks
                    WHERE blocker_id = \(bind: userID) OR blocked_id = \(bind: userID)
                    """,
                    "DELETE FROM upload_sessions WHERE user_id = \(bind: userID)",
                    "DELETE FROM activity_sessions WHERE user_id = \(bind: userID)",
                    // Signed out everywhere: a token is only good while its
                    // device row is.
                    "DELETE FROM devices WHERE user_id = \(bind: userID)",
                ] {
                    try await sql.raw(statement).run()
                }

                // The row stays for what the family keeps, with nothing of the
                // person left in it. The DSM link goes too, so signing in with
                // the same NAS account later starts a new, empty account rather
                // than reopening this one.
                try await sql.raw("""
                    UPDATE users
                    SET display_name = 'Former member', avatar_sha256 = NULL,
                        dsm_username = NULL, dsm_uid = NULL, dsm_home = NULL,
                        activity_read_at = NULL, deleted_at = now()
                    WHERE id = \(bind: userID)
                    """).run()

                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }

        req.logger.notice("account \(userID) deleted at its owner's request")
        return .noContent
    }
}
