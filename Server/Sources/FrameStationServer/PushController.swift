import FrameStationAPI
import Foundation
import SQLKit
import Vapor

/// APNs token registration.
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
}
