import FrameStationAPI
import Foundation
import SQLKit
import Vapor

/// `FrameStationServer analysis status | enroll <person> | remove <person>`.
///
/// Shadow mode starts one library at a time, from here: nobody's photos are
/// read by the NAS's analyzer until they're enrolled, and nobody but the NAS
/// owner is enrolled until the People switch is in the apps. See
/// NAS-ANALYSIS.md §6–7. A person is named by their display name, their DSM
/// account name, or their id.
///
/// On the NAS:
///
///     sudo docker compose exec server ./FrameStationServer analysis status
struct AnalysisCommand: AsyncCommandGroup {
    var help: String { "Show NAS analysis progress, or start or stop it for one person's library." }

    var commands: [String: any AnyAsyncCommand] {
        [
            "status": Status(), "enroll": Enroll(), "remove": Remove(), "verify": Verify(),
            "time-grouping": TimeGrouping(), "people-matches": PeopleMatches(),
        ]
    }

    struct Status: AsyncCommand {
        struct Signature: CommandSignature {}
        var help: String { "Who is analyzed, how far along, and the analyzer's models." }

        func run(using context: CommandContext, signature: Signature) async throws {
            try await AnalysisCommand.status(context: context, sql: context.application.sql)
        }
    }

    struct Enroll: AsyncCommand {
        struct Signature: CommandSignature {
            @Argument(name: "person", help: "Display name, DSM account name or id")
            var person: String
        }
        var help: String { "Start shadow-mode analysis of one person's library." }

        func run(using context: CommandContext, signature: Signature) async throws {
            let sql = context.application.sql
            let person = try await AnalysisCommand.find(signature.person, sql: sql)
            try await sql.raw("""
                UPDATE users SET nas_analysis = 'shadow'
                WHERE id = \(bind: person.id) AND nas_analysis = 'off'
                """).run()
            context.console.info("\(person.name): analyzed by the NAS in shadow mode. Nothing anyone sees changes.")
            context.console.info("The server starts within a minute; `analysis status` shows progress.")
        }
    }

    struct Remove: AsyncCommand {
        struct Signature: CommandSignature {
            @Argument(name: "person", help: "Display name, DSM account name or id")
            var person: String
        }
        var help: String { "Stop analyzing one person's library and delete what was stored, faces included." }

        func run(using context: CommandContext, signature: Signature) async throws {
            let sql = context.application.sql
            let person = try await AnalysisCommand.find(signature.person, sql: sql)
            try await sql.raw("UPDATE users SET nas_analysis = 'off', nas_preview = false WHERE id = \(bind: person.id)").run()
            struct Count: Decodable { let count: Int }
            let removed = try await sql.raw("""
                WITH gone AS (DELETE FROM nas_analysis WHERE user_id = \(bind: person.id) RETURNING 1)
                SELECT count(*)::int AS count FROM gone
                """).first(decoding: Count.self)?.count ?? 0
            try await sql.raw("DELETE FROM people WHERE user_id = \(bind: person.id)").run()
            context.console.info("\(person.name): no longer analyzed by the NAS; \(removed) analyses deleted, faces and people included.")
        }
    }

    /// Opens every sealed face embedding of one person with this server's key.
    /// After restoring a database, or moving one, this says whether the key
    /// in secrets/ is the one the faces were sealed with. Prints counts only.
    struct Verify: AsyncCommand {
        struct Signature: CommandSignature {
            @Argument(name: "person", help: "Display name, DSM account name or id")
            var person: String
        }
        var help: String { "Check that one person's stored faces open with this server's key." }

        func run(using context: CommandContext, signature: Signature) async throws {
            let sql = context.application.sql
            let person = try await AnalysisCommand.find(signature.person, sql: sql)
            let blobRoot = Environment.get("FRAMESTATION_BLOB_ROOT") ?? "/data"
            let seal = try FaceSeal.existing(secretsDirectory: (blobRoot as NSString).appendingPathComponent("secrets"))
            struct Row: Decodable {
                let sha256: String
                let ordinal: Int
                let embedding: Data
            }
            let rows = try await sql.raw("""
                SELECT sha256, ordinal, embedding FROM nas_faces
                WHERE user_id = \(bind: person.id) AND embedding IS NOT NULL
                """).all(decoding: Row.self)
            let opened = rows.filter { row in
                (try? seal.open(row.embedding, userID: person.id, sha256: row.sha256, ordinal: row.ordinal))?
                    .count == AnalyzerClient.faceDimensions * 4
            }.count
            context.console.info("\(person.name): \(opened) of \(rows.count) faces open with this server's key.")
        }
    }

    /// Times People's grouping on this machine, on made-up faces: a first
    /// pass, when nobody is known yet, and a second, once the first pass's
    /// people are. Reads nothing and writes nothing.
    ///
    ///     sudo docker compose exec server ./FrameStationServer analysis time-grouping 30000
    struct TimeGrouping: AsyncCommand {
        struct Signature: CommandSignature {
            @Argument(name: "faces", help: "How many faces, such as 30000")
            var faces: Int
        }
        var help: String { "Time People's grouping on made-up faces. Reads and writes nothing." }

        func run(using context: CommandContext, signature: Signature) async throws {
            guard signature.faces > 0, signature.faces <= 500_000 else {
                throw Abort(.badRequest, reason: "Between 1 and 500,000 faces.")
            }
            var library = PeopleClusterer.standIn(faces: signature.faces)
            let first = ContinuousClock.now
            let plan = PeopleClusterer.plan(library)
            let firstTook = ContinuousClock.now - first
            // The second pass starts from the people the first one found.
            library.people = plan.created.map(\.id).sorted { $0.uuidString < $1.uuidString }
            let index = Dictionary(uniqueKeysWithValues: library.people.enumerated().map { ($1, $0) })
            library.members = plan.created.flatMap { id, faces in faces.map { ($0, index[id]!) } }
            let second = ContinuousClock.now
            let again = PeopleClusterer.plan(library)
            let secondTook = ContinuousClock.now - second
            context.console.info(
                "\(signature.faces) faces: the first pass found \(plan.created.count) people in \(firstTook); "
                + "the next placed \(again.newAuto.count) more faces in \(secondTook)."
            )
        }
    }

    /// What folding unnamed people into the people someone named would do,
    /// before anything does it. For each unnamed person with a circle: where
    /// they are on the People page, the named person they look most like and
    /// how much, the runner-up, and what each would get under the proposed
    /// thresholds. Then, for scale, how alike the named people are to each
    /// other: siblings set the floor for anything done without asking.
    /// Reads only; writes and logs nothing.
    ///
    ///     sudo docker compose exec server ./FrameStationServer analysis people-matches "Michael Romero"
    struct PeopleMatches: AsyncCommand {
        struct Signature: CommandSignature {
            @Argument(name: "person", help: "Display name, DSM account name or id")
            var person: String
        }
        var help: String { "Report which unnamed people look like someone named. Changes nothing." }

        /// Proposed, to be set from what this prints.
        static let fold: Float = 0.62
        static let foldMargin: Float = 0.08
        static let ask: Float = 0.45

        func run(using context: CommandContext, signature: Signature) async throws {
            let app = context.application
            let sql = app.sql
            let console = context.console
            let person = try await AnalysisCommand.find(signature.person, sql: sql)
            struct Space: Decodable { let id: UUID }
            guard let space = try await sql.raw("""
                SELECT s.id FROM spaces s
                JOIN space_members m ON m.space_id = s.id AND m.user_id = \(bind: person.id)
                WHERE s.kind = 'personal' LIMIT 1
                """).first(decoding: Space.self)
            else { throw Abort(.notFound, reason: "\(person.name) has no personal library.") }

            let blobRoot = Environment.get("FRAMESTATION_BLOB_ROOT") ?? "/data"
            let seal = try FaceSeal.existing(secretsDirectory: (blobRoot as NSString).appendingPathComponent("secrets"))
            let clusterer = PeopleClusterer(app: app, seal: seal)
            let (library, _) = try await clusterer.load(person.id)
            let likeness = PeopleClusterer.likenesses(library)

            // The page as the app draws it, so each one can be found there.
            let page = try await PeopleController.summaries(
                userID: person.id, spaceID: space.id, limit: PeopleController.listLimit, on: sql
            )
            let names = Dictionary(uniqueKeysWithValues: page.compactMap { p in p.name.map { (p.id, $0) } })
            var position: [UUID: String] = [:]
            var counts: [PersonTier: Int] = [:]
            for p in page {
                counts[p.place, default: 0] += 1
                switch p.place {
                case .named: position[p.id] = "named"
                case .suggested: position[p.id] = "Suggested #\(counts[p.place]!)"
                case .more: position[p.id] = "More People #\(counts[p.place]!)"
                }
            }
            func pct(_ s: Float) -> String { String(format: "%.2f", s) }
            func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

            console.info("\(person.name): \(library.faces.count) faces, \(names.count) named, "
                + "\(counts[.suggested] ?? 0) suggested, \(counts[.more] ?? 0) under More People.")
            console.info("Proposed: fold in at \(pct(Self.fold))+ and \(pct(Self.foldMargin)) clear of the runner-up; ask at \(pct(Self.ask))+.")
            console.info("")
            console.info(pad("Where", 18) + pad("Photos", 8) + pad("Looks most like", 26) + pad("Runner-up", 26) + "Would")
            var tally: [String: Int] = [:]
            for p in page where p.place != .named {
                // Never someone they're in a photo with, or someone the owner
                // already said a face of theirs isn't.
                let list = (likeness[p.id] ?? []).filter { !$0.together && $0.rejected == 0 }
                guard let best = list.first else {
                    tally["-", default: 0] += 1
                    continue
                }
                let second = list.dropFirst().first
                let margin = best.similarity - (second?.similarity ?? -1)
                let would = best.similarity >= Self.fold && margin >= Self.foldMargin ? "fold in"
                    : best.similarity >= Self.ask ? "ask" : "-"
                tally[would, default: 0] += 1
                guard would != "-" else { continue }
                console.info(pad(position[p.id] ?? "?", 18) + pad("\(p.photoCount)", 8)
                    + pad("\(names[best.person] ?? "?") \(pct(best.similarity))", 26)
                    + pad(second.map { "\(names[$0.person] ?? "?") \(pct($0.similarity))" } ?? "", 26) + would)
            }
            console.info("")
            console.info("Would fold in \(tally["fold in"] ?? 0), ask about \(tally["ask"] ?? 0), leave \(tally["-"] ?? 0).")
            console.info("")
            console.info("Named people and the other named person they look most like (siblings set the floor):")
            for p in page where p.place == .named {
                guard let best = likeness[p.id]?.first(where: { !$0.together }) ?? likeness[p.id]?.first else { continue }
                console.info("  " + pad(p.name ?? "?", 24) + "\(names[best.person] ?? "?") \(pct(best.similarity))"
                    + (best.together ? " (in photos together)" : ""))
            }
        }
    }

    fileprivate struct Person: Decodable {
        let id: UUID
        let name: String
    }

    fileprivate static func find(_ who: String, sql: any SQLDatabase) async throws -> Person {
        guard !who.isEmpty else {
            throw Abort(.badRequest, reason: "Name the person: display name, DSM account name or id.")
        }
        let matches = try await sql.raw("""
            SELECT id, display_name AS name FROM users
            WHERE deleted_at IS NULL
              AND (id::text = \(bind: who.lowercased())
                   OR display_name = \(bind: who)
                   OR dsm_username = \(bind: who))
            """).all(decoding: Person.self)
        guard matches.count == 1, let person = matches.first else {
            throw Abort(.badRequest, reason: matches.isEmpty
                ? "No one is called '\(who)'."
                : "More than one person matches '\(who)'; use their id.")
        }
        return person
    }

    fileprivate static func status(context: CommandContext, sql: any SQLDatabase) async throws {
        let console = context.console
        if let socket = Environment.get("FRAMESTATION_ANALYZER_SOCKET"), !socket.isEmpty {
            let client = AnalyzerClient(socketPath: socket, http: context.application.http.client.shared)
            do {
                let health = try await client.health()
                console.info("Analyzer: ready, version \(health.analyzer), protocol \(health.protocol), \(health.threads) threads")
                console.info("  \(health.modelSummary)")
            } catch {
                console.warning("Analyzer: not answering at its socket (\(error))")
            }
        } else {
            console.warning("Analyzer: FRAMESTATION_ANALYZER_SOCKET is not set, so the server doesn't analyze")
        }

        struct Row: Decodable {
            let name: String
            let state: String
            let curation: Bool
            let done: Int
            let skipped: Int
            let failed: Int
            let faces: Int
            let library: Int
            /// "decode 2, unsupported 1": the codes behind skips and failures.
            let reasons: String
        }
        let rows = try await sql.raw("""
            SELECT u.display_name AS name, u.nas_analysis AS state, u.curation_enabled AS curation,
                   (SELECT count(*)::int FROM nas_analysis n WHERE n.user_id = u.id AND n.status = 'done') AS done,
                   (SELECT count(*)::int FROM nas_analysis n WHERE n.user_id = u.id AND n.status = 'skipped') AS skipped,
                   (SELECT count(*)::int FROM nas_analysis n WHERE n.user_id = u.id AND n.status = 'failed') AS failed,
                   (SELECT count(*)::int FROM nas_faces f WHERE f.user_id = u.id) AS faces,
                   (SELECT count(DISTINCT a.sha256)::int
                    FROM space_members m
                    JOIN spaces s ON s.id = m.space_id AND s.kind = 'personal'
                    JOIN space_assets sa ON sa.space_id = s.id AND sa.deleted_at IS NULL
                    JOIN assets a ON a.id = sa.asset_id
                    WHERE m.user_id = u.id AND a.derived_at IS NOT NULL
                      AND \(unsafeRaw: TimelineController.visible)) AS library,
                   COALESCE((SELECT string_agg(e.error || ' ' || e.n, ', ' ORDER BY e.n DESC, e.error)
                             FROM (SELECT error, count(*) AS n FROM nas_analysis n
                                   WHERE n.user_id = u.id AND n.status <> 'done' AND n.error IS NOT NULL
                                   GROUP BY error) e), '') AS reasons
            FROM users u
            WHERE u.deleted_at IS NULL
              AND (u.nas_analysis <> 'off' OR EXISTS (SELECT 1 FROM nas_analysis n WHERE n.user_id = u.id))
            ORDER BY u.display_name
            """).all(decoding: Row.self)

        // What the scenes mean: how much is scored, and how many labels are
        // calibrated against what the phones found. Counts only.
        struct Scoring: Decodable { let scored: Int; let calibrated: Int; let overlap: Int?; let previewing: Int }
        if let scoring = try await sql.raw("""
            SELECT (SELECT count(*)::int FROM nas_observations) AS scored,
                   (SELECT count(*)::int FROM nas_calibration) AS calibrated,
                   (SELECT max(overlap)::int FROM nas_calibration) AS overlap,
                   (SELECT count(*)::int FROM users WHERE nas_preview AND deleted_at IS NULL) AS previewing
            """).first(decoding: Scoring.self) {
            let against = scoring.overlap.map { " against \($0) photos a phone also analyzed" } ?? ", none yet (it needs 300 photos a phone also analyzed)"
            console.info("Scenes: \(scoring.scored) files scored; \(scoring.calibrated) labels calibrated\(against); \(scoring.previewing) previewing")
        }

        console.info("")
        if rows.isEmpty {
            console.info("Nobody's library is analyzed by the NAS. Start one with `analysis enroll <person>`.")
            return
        }
        for row in rows {
            let state = row.curation ? row.state : "\(row.state), curation off so paused"
            let handled = row.done + row.skipped
            let percent = row.library > 0 ? Int((Double(handled) / Double(row.library) * 100).rounded(.down)) : 0
            console.info("\(row.name) (\(state)): \(handled) of \(row.library) files (\(percent)%), \(row.skipped) skipped, \(row.failed) failed, \(row.faces) faces")
            if !row.reasons.isEmpty {
                console.info("  why: \(row.reasons)")
            }
        }
    }
}
