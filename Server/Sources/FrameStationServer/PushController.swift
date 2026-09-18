import FrameStationAPI
import Foundation
import SQLKit
import Vapor

/// What the server needs in order to reach a device: its APNs token, and
/// whether there is anything worth reaching it about.
///
/// The token belongs to the *device* row, not the user: one person's phone,
/// iPad and Mac each get their own, and a token is only ever valid for the
/// install that produced it.
struct PushController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(DeviceTokenAuthenticator())
            .grouped(AuthenticatedDevice.guardMiddleware())

        protected.put("devices", "push-token", use: register)
        protected.delete("devices", "push-token", use: unregister)
        protected.put("devices", "backup-state", use: reportBackupState)
    }

    private func register(_ req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let input = try req.content.decode(RegisterPushTokenRequest.self)

        let token = input.apnsToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw Abort(.badRequest, reason: "Empty APNs token.")
        }

        // A token can move between installs; clear it anywhere else first so two
        // rows never claim the same one and the family gets doubled pushes.
        try await req.sql.raw("""
            UPDATE devices SET apns_token = NULL, apns_env = NULL
            WHERE apns_token = \(bind: token) AND id <> \(bind: device.deviceID)
            """).run()

        try await req.sql.raw("""
            UPDATE devices
            SET apns_token = \(bind: token),
                apns_env = \(bind: input.environment.rawValue),
                last_seen_at = now()
            WHERE id = \(bind: device.deviceID)
            """).run()

        return .noContent
    }

    private func unregister(_ req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        try await req.sql.raw("""
            UPDATE devices SET apns_token = NULL, apns_env = NULL
            WHERE id = \(bind: device.deviceID)
            """).run()
        return .noContent
    }

    /// "I still have this many photographs to send."
    ///
    /// Resets `backup_nudges` on every report, including a report of zero, and
    /// that reset is the whole rate-limiting scheme. A device that is being
    /// woken and is getting on with it keeps re-arming its own budget; a device
    /// that never answers spends its handful of pushes and is left alone until
    /// it speaks for itself. See `BackupNudger`.
    private func reportBackupState(_ req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let input = try req.content.decode(ReportBackupStateRequest.self)

        // Clamped rather than rejected. This number only decides whether to
        // spend a push, so a client that reports nonsense should be ignored,
        // not given an error to handle in the middle of a backup.
        let pending = max(0, input.pending)

        try await req.sql.raw("""
            UPDATE devices
            SET backup_pending = \(bind: pending),
                backup_reported_at = now(),
                backup_nudges = 0
            WHERE id = \(bind: device.deviceID)
            """).run()

        return .noContent
    }
}
