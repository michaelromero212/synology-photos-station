import Foundation
import SQLKit
import Vapor

/// `FrameStationServer credit-uploaders` — credits photos imported from a
/// Synology Photos Shared Space to the people who shared them there.
///
/// Synology files every Shared Space photo under the shared library itself,
/// not under whoever added it. But sharing a photo there copies it out of the
/// sharer's own library, so the person whose own Synology library holds the
/// same photo (by Synology's content fingerprint) is who shared it.
/// `Scripts/credit-synology-uploaders.sh` exports that match from Synology's
/// database, one tab-separated line per photo: the path the import read it
/// from, the person's Synology uid, and their Synology login. This applies it,
/// through the credit that "Added by" already prefers (migration 0016).
///
/// Someone with no FrameStation account yet gets one, tied to their Synology
/// login, exactly as signing in creates it: an account and an empty personal
/// library, no devices. Signing in with that login later lands in it, already
/// credited. Nobody is added to the shared library. Membership would put a
/// copy of every shared photo in their home folder, which Synology Photos would
/// then show them twice.
///
/// A photo someone has credited by hand keeps that credit, and one already
/// shown as the person's needs nothing, so running it again changes nothing.
struct CreditUploadersCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "from", help: "Tab-separated lines: import source path, Synology uid, Synology login")
        var from: String?

        @Option(name: "space", short: "s", help: "The library the photos were imported into (see `spaces`)")
        var space: String?

        @Flag(name: "dry-run", help: "Report what would change without changing anything")
        var dryRun: Bool
    }

    var help: String { "Credit imported Synology Shared Space photos to the people who shared them." }

    private struct Line {
        let path: String
        let uid: Int
        let login: String
    }

    private struct Placement: Decodable {
        let path: String
        let id: UUID
        let uploadedBy: UUID
        let creditedTo: UUID?
    }

    private struct IDRow: Decodable { let id: UUID }
    private struct OwnerRow: Decodable { let owner: UUID }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let console = context.console

        guard let from = signature.from else {
            throw Abort(.badRequest, reason: "--from is required: the file credit-synology-uploaders.sh writes.")
        }
        guard let spaceString = signature.space, let spaceID = UUID(uuidString: spaceString) else {
            throw Abort(.badRequest, reason: "--space is required. Run `FrameStationServer spaces`.")
        }
        guard let owner = try await app.sql.raw("""
            SELECT created_by AS owner FROM spaces WHERE id = \(bind: spaceID)
            """).first(decoding: OwnerRow.self)?.owner else {
            throw Abort(.badRequest, reason: "No library with id \(spaceID). Run `FrameStationServer spaces`.")
        }
        guard let text = try? String(contentsOfFile: from, encoding: .utf8) else {
            throw Abort(.badRequest, reason: "Can't read \(from).")
        }

        var lines: [Line] = []
        var malformed = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = raw.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, let uid = Int(fields[1]),
                  !fields[0].isEmpty, !fields[2].isEmpty else {
                malformed += 1
                continue
            }
            lines.append(Line(path: String(fields[0]), uid: uid, login: String(fields[2])))
        }

        // Every photo the import brought into this library, by the path it was
        // read from. A photo the library already held has no row of its own
        // from the import, and isn't the import's to credit.
        let placements = try await app.sql.raw("""
            SELECT r.source_path AS path, sa.id, sa.uploaded_by_user_id AS "uploadedBy",
                   sa.credited_to_user_id AS "creditedTo"
            FROM import_records r
            JOIN space_assets sa ON sa.asset_id = r.asset_id
            WHERE sa.space_id = \(bind: spaceID) AND sa.deleted_at IS NULL
            """).all(decoding: Placement.self)
        var byPath: [String: Placement] = [:]
        for placement in placements { byPath[placement.path] = placement }

        // Existing accounts, by Synology login. Case-insensitive, as signing in
        // matches them.
        var accounts: [String: UUID] = [:]
        for login in Set(lines.map { $0.login.lowercased() }) {
            if let row = try await app.sql.raw("""
                SELECT id FROM users WHERE lower(dsm_username) = \(bind: login)
                """).first(decoding: IDRow.self) {
                accounts[login] = row.id
            }
        }

        var toCredit: [(placement: UUID, line: Line)] = []
        var alreadyTheirs = 0, keptByHand = 0, notImported = 0
        for line in lines {
            guard let placement = byPath[line.path] else {
                notImported += 1
                continue
            }
            let account = accounts[line.login.lowercased()]
            let shownAs = placement.creditedTo ?? placement.uploadedBy
            if let account, shownAs == account {
                alreadyTheirs += 1
            } else if placement.creditedTo != nil {
                keptByHand += 1
            } else {
                toCredit.append((placement.id, line))
            }
        }

        var perPerson: [String: (count: Int, line: Line)] = [:]
        for (_, line) in toCredit {
            let entry = perPerson[line.login] ?? (0, line)
            perPerson[line.login] = (entry.count + 1, entry.line)
        }
        let newAccounts = perPerson.values.map(\.line)
            .filter { accounts[$0.login.lowercased()] == nil }
            .sorted { $0.login < $1.login }

        console.info("")
        for (login, entry) in perPerson.sorted(by: { $0.key < $1.key }) {
            let note = accounts[login.lowercased()] == nil ? "  (new account)" : ""
            console.info("  Credit to \(login): \(entry.count)\(note)")
        }
        console.info("  Already shown as theirs:   \(alreadyTheirs)")
        console.info("  Credited by hand, kept:    \(keptByHand)")
        console.info("  Not imported here:         \(notImported)")
        if malformed > 0 { console.info("  Unreadable lines:          \(malformed)") }
        console.info("")

        if signature.dryRun {
            console.info("Dry run — nothing changed.")
            return
        }
        guard !toCredit.isEmpty else {
            console.info("Nothing to do.")
            return
        }

        try await app.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                var created: [String: UUID] = [:]
                for person in newAccounts {
                    // As `DSMAuthController` creates an account on first sign-in:
                    // the login as the name, and a personal library they own.
                    guard let user = try await sql.raw("""
                        INSERT INTO users (display_name, dsm_username, dsm_uid)
                        VALUES (\(bind: person.login), \(bind: person.login), \(bind: person.uid))
                        RETURNING id
                        """).first(decoding: IDRow.self),
                          let library = try await sql.raw("""
                        INSERT INTO spaces (kind, name, created_by)
                        VALUES ('personal', 'Personal Space', \(bind: user.id))
                        RETURNING id
                        """).first(decoding: IDRow.self) else {
                        throw Abort(.internalServerError, reason: "Could not create an account for \(person.login).")
                    }
                    try await sql.raw("""
                        INSERT INTO space_members (space_id, user_id, role)
                        VALUES (\(bind: library.id), \(bind: user.id), 'owner')
                        """).run()
                    created[person.login.lowercased()] = user.id
                }

                for (placement, line) in toCredit {
                    guard let person = accounts[line.login.lowercased()] ?? created[line.login.lowercased()]
                    else { continue }
                    // Credited by the library's owner, who ran this, as a credit
                    // set in the app is by whoever set it. Never over one set by
                    // hand in the meantime.
                    try await sql.raw("""
                        UPDATE space_assets
                        SET credited_to_user_id = \(bind: person),
                            credited_by_user_id = \(bind: owner),
                            credited_at         = now()
                        WHERE id = \(bind: placement) AND credited_to_user_id IS NULL
                        """).run()
                    _ = try await ChangeLog.append(
                        spaceID: spaceID, entity: "space_asset",
                        entityID: placement, op: "update", on: sql
                    )
                }
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }

        for person in newAccounts {
            console.info("Created an account for \(person.login). Signing in with that Synology login opens it.")
        }
        console.info("Credited \(toCredit.count) photos.")
    }
}
