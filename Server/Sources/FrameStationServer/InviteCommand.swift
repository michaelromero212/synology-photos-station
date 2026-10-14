import Foundation
import FrameStationAPI
import Vapor

/// `FrameStationServer invite` — the NAS owner mints a code, reads it to a
/// family member, and they redeem it from the app's onboarding screen. Single
/// use unless `--uses` says otherwise.
struct InviteCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "expires-hours", short: "e", help: "Hours until the code expires (default 168 / one week)")
        var expiresHours: Int?

        @Option(name: "space", short: "s", help: "A shared library's id: whoever redeems the code joins it as a contributor")
        var space: String?

        @Option(name: "uses", short: "u", help: "How many people can redeem it (default 1). More than one is for a demo or App Review server, never a family member's code")
        var uses: Int?
    }

    var help: String { "Create an invite code for a family member." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let hours = signature.expiresHours ?? 168
        guard hours > 0 else {
            throw Abort(.badRequest, reason: "expires-hours must be positive.")
        }
        // Capped: a code is a key to the library, and one that opens it for
        // everyone who ever reads it is not an invite.
        let uses = signature.uses ?? 1
        guard (1...50).contains(uses) else {
            throw Abort(.badRequest, reason: "uses must be between 1 and 50.")
        }

        // Checked now rather than at redemption, so a mistyped id is an error
        // here and not a code that quietly joins nothing.
        var spaceID: UUID?
        if let raw = signature.space {
            guard let id = UUID(uuidString: raw) else {
                throw Abort(.badRequest, reason: "--space must be a library's id.")
            }
            struct Kind: Decodable { let kind: String }
            let found = try await context.application.sql.raw("""
                SELECT kind FROM spaces WHERE id = \(bind: id)
                """).first(decoding: Kind.self)
            guard found?.kind == SpaceKind.shared.rawValue else {
                throw Abort(.badRequest, reason: "--space must name a shared library.")
            }
            spaceID = id
        }

        let code = InviteCode.generate()
        let expiresAt = Date().addingTimeInterval(Double(hours) * 3600)

        try await context.application.sql.raw("""
            INSERT INTO invites (code, expires_at, space_id, uses_left)
            VALUES (\(bind: code), \(bind: expiresAt), \(bind: spaceID), \(bind: uses))
            """).run()

        // Spelled out rather than left to the locale: the container has none,
        // and the default it falls back to printed "12 Jan 2027". The zone is
        // the container's, usually UTC, so it's said.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a zzz"

        context.console.info("")
        context.console.info("  Invite code:  \(code)")
        context.console.info("  Expires:      \(formatter.string(from: expiresAt))")
        context.console.info("")
        context.console.info(uses == 1
            ? "  Single use. Enter it on the app's onboarding screen."
            : "  Good for \(uses) people. Enter it on the app's onboarding screen.")
        context.console.info("")
    }
}
