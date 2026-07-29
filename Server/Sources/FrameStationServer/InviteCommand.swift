import Foundation
import Vapor

/// `FrameStationServer invite` — the NAS owner mints a single-use code, reads it
/// to a family member, and they redeem it from the app's onboarding screen.
struct InviteCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "expires-hours", short: "e", help: "Hours until the code expires (default 168 / one week)")
        var expiresHours: Int?
    }

    var help: String { "Create a single-use invite code for a family member." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let hours = signature.expiresHours ?? 168
        guard hours > 0 else {
            throw Abort(.badRequest, reason: "expires-hours must be positive.")
        }

        let code = InviteCode.generate()
        let expiresAt = Date().addingTimeInterval(Double(hours) * 3600)

        try await context.application.sql.raw("""
            INSERT INTO invites (code, expires_at)
            VALUES (\(bind: code), \(bind: expiresAt))
            """).run()

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        context.console.info("")
        context.console.info("  Invite code:  \(code)")
        context.console.info("  Expires:      \(formatter.string(from: expiresAt))")
        context.console.info("")
        context.console.info("  Single use. Enter it on the app's onboarding screen.")
        context.console.info("")
    }
}
