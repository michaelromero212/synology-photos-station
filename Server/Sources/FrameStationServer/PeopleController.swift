import FrameStationAPI
import Foundation
import SQLKit
import Vapor

extension PeopleResponse: @retroactive Content {}
extension PersonSummary: @retroactive Content {}
extension PersonSuggestionsResponse: @retroactive Content {}
extension PhotoPeopleResponse: @retroactive Content {}

/// The people in a person's own library: who they are, naming them, and the
/// person's say over the NAS's grouping. See NAS-ANALYSIS.md §6 and
/// `PeopleClusterer`.
///
/// Only the library's owner, only in their own personal library, and only
/// when the NAS analyzes it. Anyone else gets a 404, which says nothing about
/// whether there was anyone to find. Nothing here returns a face's numbers.
/// Pictures of faces are cropped from the owner's own photos.
struct PeopleController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(DeviceTokenAuthenticator())
            .grouped(AuthenticatedDevice.guardMiddleware())
        let people = protected.grouped("spaces", ":spaceID", "people")
        people.get(use: list)
        people.put(":personID", use: name)
        people.post(":personID", "merge", use: merge)
        people.post(":personID", "remove", use: remove)
        people.get(":personID", "suggestions", use: suggestions)
        people.post(":personID", "suggestions", use: answer)
        people.get(":personID", "face", use: personFace)
        people.put(":personID", "relation", use: relation)
        people.put(":personID", "me", use: isMe)
        protected.get("spaces", ":spaceID", "assets", ":assetID", "faces", ":ordinal", use: assetFace)
        protected.get("spaces", ":spaceID", "assets", ":assetID", "people", use: photoPeople)
        protected.put("spaces", ":spaceID", "assets", ":assetID", "faces", ":ordinal", "person", use: assignFace)
    }

    static let pageLimit = 20
    static let listLimit = 500

    /// Which of someone's faces stands for them: one they confirmed, then one
    /// that's level (eyes side by side, the right eye on the left, so not
    /// sideways or upside down), then from a photo rather than a video, then
    /// the biggest and clearest. Expects their faces as `c` and the NAS's
    /// rows as `f`.
    static let coverOrder = """
        (c.state = 'confirmed') DESC,
        (f.landmarks[3] - f.landmarks[1] > abs(f.landmarks[4] - f.landmarks[2])) DESC,
        (f.frame_ms IS NULL) DESC, f.size_px * f.score DESC
        """

    // MARK: - Who can ask

    /// 404 unless the space is the caller's own personal library, the NAS
    /// analyzes it, and People is on.
    static func requireOwnLibrary(_ req: Request) async throws -> (userID: UUID, spaceID: UUID) {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let context = try await CurationController.context(userID: device.userID, spaceID: spaceID, on: req.sql)
        guard context.showsPeople else { throw Abort(.notFound) }
        return (device.userID, spaceID)
    }

    /// 404 unless the person is the caller's.
    private static func requirePerson(_ req: Request, userID: UUID) async throws -> UUID {
        let personID = try req.parameters.require("personID", as: UUID.self)
        struct Row: Decodable { let id: UUID }
        guard try await req.sql.raw("""
            SELECT id FROM people WHERE id = \(bind: personID) AND user_id = \(bind: userID)
            """).first(decoding: Row.self) != nil
        else { throw Abort(.notFound) }
        return personID
    }

    // MARK: - Summaries

    /// The people to show, named first and then by how many photos they're
    /// in. Someone unnamed needs three photos to be shown; a stranger in one
    /// background isn't anyone.
    static func summaries(
        userID: UUID, spaceID: UUID, limit: Int, only: UUID? = nil, on sql: any SQLDatabase
    ) async throws -> [PersonSummary] {
        struct Row: Decodable {
            let id: UUID
            let name: String?
            let relation: String?
            let isMe: Bool
            let photos: Int
            let questions: Int
        }
        let filter: SQLQueryString = only.map { "AND p.id = \(bind: $0)" } ?? ""
        let rows = try await sql.raw("""
            SELECT p.id, p.name, p.relation, p.is_me AS "isMe", count(DISTINCT pf.sha256)::int AS photos,
                   (SELECT count(*)::int FROM person_faces q
                    WHERE q.person_id = p.id AND q.state = 'suggested') AS questions
            FROM people p
            JOIN person_faces pf ON pf.person_id = p.id AND pf.state IN ('auto', 'confirmed')
            JOIN assets a ON a.sha256 = pf.sha256
            JOIN space_assets sa ON sa.asset_id = a.id AND sa.space_id = \(bind: spaceID)
                                AND sa.deleted_at IS NULL
            WHERE p.user_id = \(bind: userID) AND NOT p.hidden
              AND \(unsafeRaw: TimelineController.visible)
              \(filter)
            GROUP BY p.id, p.name, p.relation, p.is_me
            HAVING count(DISTINCT pf.sha256) >= CASE WHEN p.name IS NULL THEN 3 ELSE 1 END
            -- Family and the owner first, then everyone else named, then the
            -- rest; the most photographed first in each.
            ORDER BY (p.is_me OR (p.relation IS NOT NULL AND p.relation <> 'friend')) DESC,
                     (p.name IS NOT NULL) DESC, photos DESC, p.id
            LIMIT \(bind: limit)
            """).all(decoding: Row.self)
        guard !rows.isEmpty else { return [] }

        // The face that stands for each: one they confirmed, from a photo
        // rather than a video, the biggest and clearest.
        struct Cover: Decodable { let personID: UUID; let sha256: String; let ordinal: Int }
        let covers = try await sql.raw("""
            SELECT DISTINCT ON (c.person_id) c.person_id AS "personID", c.sha256, c.ordinal::int AS ordinal
            FROM person_faces c
            JOIN nas_faces f ON f.user_id = c.user_id AND f.sha256 = c.sha256 AND f.ordinal = c.ordinal
            WHERE c.person_id = ANY(\(bind: rows.map(\.id))::uuid[]) AND c.state IN ('auto', 'confirmed')
            ORDER BY c.person_id, \(unsafeRaw: Self.coverOrder), c.sha256, c.ordinal
            """).all(decoding: Cover.self)
        let cover = Dictionary(uniqueKeysWithValues: covers.map {
            ($0.personID, "\($0.sha256.prefix(12))-\($0.ordinal)-v\(FaceCrop.version)")
        })
        return rows.map {
            PersonSummary(id: $0.id, name: $0.name, photoCount: $0.photos,
                          face: cover[$0.id] ?? "none", questions: $0.name == nil ? 0 : $0.questions,
                          relation: $0.relation, isMe: $0.isMe)
        }
    }

    @Sendable
    func list(req: Request) async throws -> PeopleResponse {
        let (userID, spaceID) = try await Self.requireOwnLibrary(req)
        return PeopleResponse(people: try await Self.summaries(
            userID: userID, spaceID: spaceID, limit: Self.listLimit, on: req.sql
        ))
    }

    private func summary(_ req: Request, userID: UUID, spaceID: UUID, personID: UUID) async throws -> PersonSummary {
        if let found = try await Self.summaries(
            userID: userID, spaceID: spaceID, limit: 1, only: personID, on: req.sql
        ).first {
            return found
        }
        // Shown or not, they're still someone.
        struct Row: Decodable { let name: String?; let relation: String?; let isMe: Bool }
        let row = try await req.sql.raw("""
            SELECT name, relation, is_me AS "isMe" FROM people WHERE id = \(bind: personID)
            """).first(decoding: Row.self)
        return PersonSummary(id: personID, name: row?.name, photoCount: 0, face: "none",
                             relation: row?.relation, isMe: row?.isMe ?? false)
    }

    // MARK: - The owner's say

    @Sendable
    func name(req: Request) async throws -> PersonSummary {
        let (userID, spaceID) = try await Self.requireOwnLibrary(req)
        let personID = try await Self.requirePerson(req, userID: userID)
        let body = try req.content.decode(NamePersonRequest.self)
        let trimmed = body.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.count <= 80 else { throw Abort(.badRequest, reason: "That name is too long.") }
        let name: String? = trimmed.isEmpty ? nil : trimmed
        try await req.sql.raw("""
            UPDATE people
            SET name = \(bind: name), named_at = CASE WHEN \(bind: name)::text IS NULL THEN NULL ELSE now() END,
                updated_at = now()
            WHERE id = \(bind: personID) AND user_id = \(bind: userID)
            """).run()
        // Their faces that were only close may now be worth asking about.
        await req.application.storage[PeopleClustererKey.self]?.touch(userID)
        return try await summary(req, userID: userID, spaceID: spaceID, personID: personID)
    }

    @Sendable
    func merge(req: Request) async throws -> PersonSummary {
        let (userID, spaceID) = try await Self.requireOwnLibrary(req)
        let personID = try await Self.requirePerson(req, userID: userID)
        let body = try req.content.decode(MergePeopleRequest.self)
        guard body.otherID != personID else { throw Abort(.badRequest, reason: "That's the same person.") }
        struct Row: Decodable { let id: UUID }
        guard try await req.sql.raw("""
            SELECT id FROM people WHERE id = \(bind: body.otherID) AND user_id = \(bind: userID)
            """).first(decoding: Row.self) != nil
        else { throw Abort(.notFound) }
        let other = body.otherID
        try await req.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                // What the owner decided about the other person comes along;
                // where both have a decision about one face, this person's
                // stands.
                try await sql.raw("""
                    INSERT INTO person_faces (user_id, sha256, ordinal, person_id, state, similarity, box, decided_at)
                    SELECT user_id, sha256, ordinal, \(bind: personID),
                           CASE WHEN state = 'suggested' THEN 'suggested' ELSE state END,
                           similarity, box, decided_at
                    FROM person_faces WHERE person_id = \(bind: other)
                    ON CONFLICT DO NOTHING
                    """).run()
                try await sql.raw("""
                    UPDATE people SET name = COALESCE(name, (SELECT name FROM people WHERE id = \(bind: other))),
                                      updated_at = now()
                    WHERE id = \(bind: personID)
                    """).run()
                try await sql.raw("DELETE FROM people WHERE id = \(bind: other) AND user_id = \(bind: userID)").run()
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
        await req.application.storage[PeopleClustererKey.self]?.touch(userID)
        return try await summary(req, userID: userID, spaceID: spaceID, personID: personID)
    }

    /// "Not this person." The faces they're in, in these photos, leave this
    /// person and never come back to them.
    @Sendable
    func remove(req: Request) async throws -> PersonSummary {
        let (userID, spaceID) = try await Self.requireOwnLibrary(req)
        let personID = try await Self.requirePerson(req, userID: userID)
        let body = try req.content.decode(PersonPhotosRequest.self)
        guard !body.assetIDs.isEmpty, body.assetIDs.count <= 500 else { throw Abort(.badRequest) }
        try await req.sql.raw("""
            UPDATE person_faces pf
            SET state = 'rejected', similarity = NULL, decided_at = now()
            FROM assets a
            JOIN space_assets sa ON sa.asset_id = a.id AND sa.space_id = \(bind: spaceID)
            WHERE a.id = ANY(\(bind: body.assetIDs)::uuid[])
              AND pf.sha256 = a.sha256 AND pf.user_id = \(bind: userID)
              AND pf.person_id = \(bind: personID) AND pf.state IN ('auto', 'confirmed', 'suggested')
            """).run()
        await req.application.storage[PeopleClustererKey.self]?.touch(userID)
        return try await summary(req, userID: userID, spaceID: spaceID, personID: personID)
    }

    /// Who someone is to the owner: one of `Relationship`'s words, or nil.
    @Sendable
    func relation(req: Request) async throws -> PersonSummary {
        let (userID, spaceID) = try await Self.requireOwnLibrary(req)
        let personID = try await Self.requirePerson(req, userID: userID)
        let body = try req.content.decode(PersonRelationRequest.self)
        let relation = body.relation.flatMap { $0.isEmpty ? nil : $0 }
        if let relation, Relationship(rawValue: relation) == nil {
            throw Abort(.badRequest, reason: "That isn't a relationship this server knows.")
        }
        try await req.sql.raw("""
            UPDATE people SET relation = \(bind: relation), updated_at = now()
            WHERE id = \(bind: personID) AND user_id = \(bind: userID)
            """).run()
        return try await summary(req, userID: userID, spaceID: spaceID, personID: personID)
    }

    /// "This is me." Only one person is; saying so of someone moves it to
    /// them. The owner isn't their own relation, so that goes.
    @Sendable
    func isMe(req: Request) async throws -> PersonSummary {
        let (userID, spaceID) = try await Self.requireOwnLibrary(req)
        let personID = try await Self.requirePerson(req, userID: userID)
        let body = try req.content.decode(PersonIsMeRequest.self)
        try await req.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                if body.isMe {
                    try await sql.raw("""
                        UPDATE people SET is_me = false, updated_at = now()
                        WHERE user_id = \(bind: userID) AND is_me AND id <> \(bind: personID)
                        """).run()
                }
                try await sql.raw("""
                    UPDATE people
                    SET is_me = \(bind: body.isMe),
                        relation = CASE WHEN \(bind: body.isMe) THEN NULL ELSE relation END,
                        updated_at = now()
                    WHERE id = \(bind: personID) AND user_id = \(bind: userID)
                    """).run()
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
        return try await summary(req, userID: userID, spaceID: spaceID, personID: personID)
    }

    @Sendable
    func suggestions(req: Request) async throws -> PersonSuggestionsResponse {
        let (userID, spaceID) = try await Self.requireOwnLibrary(req)
        let personID = try await Self.requirePerson(req, userID: userID)
        struct Row: Decodable { let assetID: UUID; let ordinal: Int }
        // One photo per face, the closest first.
        let rows = try await req.sql.raw("""
            SELECT "assetID", ordinal FROM (
                SELECT DISTINCT ON (pf.sha256, pf.ordinal) a.id AS "assetID", pf.ordinal::int AS ordinal,
                       pf.similarity, pf.sha256
                FROM person_faces pf
                JOIN assets a ON a.sha256 = pf.sha256
                JOIN space_assets sa ON sa.asset_id = a.id AND sa.space_id = \(bind: spaceID)
                                    AND sa.deleted_at IS NULL
                WHERE pf.person_id = \(bind: personID) AND pf.user_id = \(bind: userID)
                  AND pf.state = 'suggested' AND \(unsafeRaw: TimelineController.visible)
                ORDER BY pf.sha256, pf.ordinal, a.id
            ) faces
            ORDER BY similarity DESC NULLS LAST, sha256, ordinal
            """).all(decoding: Row.self)
        return PersonSuggestionsResponse(
            person: try await summary(req, userID: userID, spaceID: spaceID, personID: personID),
            suggestions: rows.map { PersonSuggestion(assetID: $0.assetID, ordinal: $0.ordinal) }
        )
    }

    @Sendable
    func answer(req: Request) async throws -> PersonSummary {
        let (userID, spaceID) = try await Self.requireOwnLibrary(req)
        let personID = try await Self.requirePerson(req, userID: userID)
        let body = try req.content.decode(AnswerSuggestionRequest.self)
        struct Face: Decodable { let sha256: String; let box: [Float] }
        guard let face = try await req.sql.raw("""
            SELECT f.sha256, f.box
            FROM nas_faces f
            JOIN assets a ON a.sha256 = f.sha256
            JOIN space_assets sa ON sa.asset_id = a.id AND sa.space_id = \(bind: spaceID)
            WHERE a.id = \(bind: body.assetID) AND f.user_id = \(bind: userID)
              AND f.ordinal = \(bind: body.ordinal)
            LIMIT 1
            """).first(decoding: Face.self)
        else { throw Abort(.notFound) }
        let state = body.isPerson ? "confirmed" : "rejected"
        try await req.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                if body.isPerson {
                    // One face is one person.
                    try await sql.raw("""
                        DELETE FROM person_faces
                        WHERE user_id = \(bind: userID) AND sha256 = \(bind: face.sha256)
                          AND ordinal = \(bind: body.ordinal) AND state IN ('auto', 'suggested')
                          AND person_id <> \(bind: personID)
                        """).run()
                }
                try await sql.raw("""
                    INSERT INTO person_faces (user_id, sha256, ordinal, person_id, state, box)
                    VALUES (\(bind: userID), \(bind: face.sha256), \(bind: body.ordinal), \(bind: personID),
                            \(bind: state), \(bind: AnalysisWorker.realArray(face.box))::real[])
                    ON CONFLICT (user_id, sha256, ordinal, person_id)
                    DO UPDATE SET state = EXCLUDED.state, similarity = NULL, decided_at = now()
                    """).run()
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
        await req.application.storage[PeopleClustererKey.self]?.touch(userID)
        return try await summary(req, userID: userID, spaceID: spaceID, personID: personID)
    }

    // MARK: - The people in one photo

    /// The file behind an asset in the caller's own library. 404 otherwise.
    private static func requireFile(_ req: Request, spaceID: UUID) async throws -> String {
        let assetID = try req.parameters.require("assetID", as: UUID.self)
        struct Row: Decodable { let sha256: String }
        guard let row = try await req.sql.raw("""
            SELECT a.sha256 FROM assets a
            JOIN space_assets sa ON sa.asset_id = a.id AND sa.space_id = \(bind: spaceID) AND sa.deleted_at IS NULL
            WHERE a.id = \(bind: assetID)
            """).first(decoding: Row.self)
        else { throw Abort(.notFound) }
        return row.sha256
    }

    /// Who the NAS found in a photo or video, for its Information panel:
    /// each person once, left to right, then faces that aren't anyone yet
    /// (in photos only, and big enough to be someone rather than a crowd).
    static func photoPeople(userID: UUID, sha256: String, on sql: any SQLDatabase) async throws -> PhotoPeopleResponse {
        struct Row: Decodable {
            let ordinal: Int
            let frameMS: Int?
            let box: [Float]
            let pixels: Int
            let personID: UUID?
            let name: String?
            let relation: String?
            let isMe: Bool?
            let state: String?
        }
        let rows = try await sql.raw("""
            SELECT f.ordinal::int AS ordinal, f.frame_ms AS "frameMS", f.box, f.size_px::int AS pixels,
                   p.id AS "personID", p.name, p.relation, p.is_me AS "isMe", pf.state
            FROM nas_faces f
            LEFT JOIN person_faces pf ON pf.user_id = f.user_id AND pf.sha256 = f.sha256
                                     AND pf.ordinal = f.ordinal AND pf.state IN ('auto', 'confirmed')
            LEFT JOIN people p ON p.id = pf.person_id AND NOT p.hidden
            WHERE f.user_id = \(bind: userID) AND f.sha256 = \(bind: sha256)
              AND f.score >= \(bind: PeopleClusterer.minScore) AND f.size_px >= \(bind: PeopleClusterer.minPixels)
            ORDER BY (pf.state = 'confirmed') DESC NULLS LAST, f.size_px DESC, f.ordinal
            """).all(decoding: Row.self)
        var seen = Set<UUID>()
        var faces: [(row: Row, order: (Int, Float))] = []
        for row in rows {
            if let person = row.personID {
                guard seen.insert(person).inserted else { continue }
            } else if row.frameMS != nil || row.pixels < PeopleClusterer.seedPixels {
                continue
            }
            faces.append((row, (row.frameMS ?? 0, row.box.first ?? 0)))
        }
        let known = faces.filter { $0.row.personID != nil }.sorted { $0.order < $1.order }
        let unknown = faces.filter { $0.row.personID == nil }.sorted { $0.order < $1.order }.prefix(8)
        return PhotoPeopleResponse(faces: (known + unknown).map { face in
            PhotoFace(
                ordinal: face.row.ordinal, personID: face.row.personID, name: face.row.name,
                relation: face.row.relation, isMe: face.row.isMe ?? false,
                isConfirmed: face.row.state == "confirmed"
            )
        })
    }

    @Sendable
    func photoPeople(req: Request) async throws -> PhotoPeopleResponse {
        let (userID, spaceID) = try await Self.requireOwnLibrary(req)
        let sha256 = try await Self.requireFile(req, spaceID: spaceID)
        return try await Self.photoPeople(userID: userID, sha256: sha256, on: req.sql)
    }

    /// The owner says who a face is: someone in People, someone new by name,
    /// or nobody the NAS had it with ("Not Emma"). In a video, the NAS keeps
    /// one person's faces in every frame together, so they all move.
    ///
    /// Kept for good, and learned from: the faces become part of who the
    /// person is to the NAS, and the one they left never takes them back.
    @Sendable
    func assignFace(req: Request) async throws -> PhotoPeopleResponse {
        let (userID, spaceID) = try await Self.requireOwnLibrary(req)
        let sha256 = try await Self.requireFile(req, spaceID: spaceID)
        let ordinal = try req.parameters.require("ordinal", as: Int.self)
        let body = try req.content.decode(AssignFaceRequest.self)

        struct Face: Decodable { let box: [Float] }
        guard try await req.sql.raw("""
            SELECT box FROM nas_faces
            WHERE user_id = \(bind: userID) AND sha256 = \(bind: sha256) AND ordinal = \(bind: ordinal)
            """).first(decoding: Face.self) != nil
        else { throw Abort(.notFound) }

        // Who it's with now, and every face of theirs in this file.
        struct Owner: Decodable { let personID: UUID }
        let current = try await req.sql.raw("""
            SELECT person_id AS "personID" FROM person_faces
            WHERE user_id = \(bind: userID) AND sha256 = \(bind: sha256) AND ordinal = \(bind: ordinal)
              AND state IN ('auto', 'confirmed')
            LIMIT 1
            """).first(decoding: Owner.self)?.personID
        struct Moving: Decodable { let ordinal: Int; let box: [Float] }
        let moving: [Moving]
        if let current {
            moving = try await req.sql.raw("""
                SELECT pf.ordinal::int AS ordinal, f.box
                FROM person_faces pf
                JOIN nas_faces f ON f.user_id = pf.user_id AND f.sha256 = pf.sha256 AND f.ordinal = pf.ordinal
                WHERE pf.user_id = \(bind: userID) AND pf.sha256 = \(bind: sha256)
                  AND pf.person_id = \(bind: current) AND pf.state IN ('auto', 'confirmed')
                """).all(decoding: Moving.self)
        } else {
            moving = try await req.sql.raw("""
                SELECT ordinal::int AS ordinal, box FROM nas_faces
                WHERE user_id = \(bind: userID) AND sha256 = \(bind: sha256) AND ordinal = \(bind: ordinal)
                """).all(decoding: Moving.self)
        }

        // Who it is: someone already there, or someone new by name.
        let newName = body.newName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard newName.count <= 80 else { throw Abort(.badRequest, reason: "That name is too long.") }
        if let personID = body.personID {
            struct Row: Decodable { let id: UUID }
            guard try await req.sql.raw("""
                SELECT id FROM people WHERE id = \(bind: personID) AND user_id = \(bind: userID)
                """).first(decoding: Row.self) != nil
            else { throw Abort(.notFound) }
        }
        let newPerson: UUID? = body.personID == nil && !newName.isEmpty ? UUID() : nil
        let target = body.personID ?? newPerson

        try await req.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                if let newPerson {
                    try await sql.raw("""
                        INSERT INTO people (id, user_id, name, named_at)
                        VALUES (\(bind: newPerson), \(bind: userID), \(bind: newName), now())
                        """).run()
                }
                for face in moving {
                    // Not who the NAS had it with, unless that's who it is.
                    if let current, current != target {
                        try await sql.raw("""
                            UPDATE person_faces SET state = 'rejected', similarity = NULL, decided_at = now()
                            WHERE user_id = \(bind: userID) AND sha256 = \(bind: sha256)
                              AND ordinal = \(bind: face.ordinal) AND person_id = \(bind: current)
                            """).run()
                    }
                    // Questions about it are answered now.
                    try await sql.raw("""
                        DELETE FROM person_faces
                        WHERE user_id = \(bind: userID) AND sha256 = \(bind: sha256)
                          AND ordinal = \(bind: face.ordinal) AND state = 'suggested'
                        """).run()
                    if let target {
                        try await sql.raw("""
                            INSERT INTO person_faces (user_id, sha256, ordinal, person_id, state, box)
                            VALUES (\(bind: userID), \(bind: sha256), \(bind: face.ordinal), \(bind: target),
                                    'confirmed', \(bind: AnalysisWorker.realArray(face.box))::real[])
                            ON CONFLICT (user_id, sha256, ordinal, person_id)
                            DO UPDATE SET state = 'confirmed', similarity = NULL, decided_at = now()
                            """).run()
                    }
                }
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
        await req.application.storage[PeopleClustererKey.self]?.touch(userID)
        return try await Self.photoPeople(userID: userID, sha256: sha256, on: req.sql)
    }

    // MARK: - Together

    /// Two named people often in the same photos, the most first: at least
    /// `togetherMinimum` of them.
    static func together(
        userID: UUID, spaceID: UUID, limit: Int, on sql: any SQLDatabase
    ) async throws -> [PeopleTogether] {
        struct Row: Decodable { let first: UUID; let second: UUID; let photos: Int }
        let rows = try await sql.raw("""
            SELECT one.person_id AS first, two.person_id AS second, count(DISTINCT one.sha256)::int AS photos
            FROM person_faces one
            JOIN person_faces two ON two.user_id = one.user_id AND two.sha256 = one.sha256
                                 AND two.person_id > one.person_id AND two.state IN ('auto', 'confirmed')
            JOIN people p1 ON p1.id = one.person_id AND p1.name IS NOT NULL AND NOT p1.hidden
            JOIN people p2 ON p2.id = two.person_id AND p2.name IS NOT NULL AND NOT p2.hidden
            JOIN assets a ON a.sha256 = one.sha256
            JOIN space_assets sa ON sa.asset_id = a.id AND sa.space_id = \(bind: spaceID) AND sa.deleted_at IS NULL
            WHERE one.user_id = \(bind: userID) AND one.state IN ('auto', 'confirmed')
              AND \(unsafeRaw: TimelineController.visible)
            GROUP BY one.person_id, two.person_id
            HAVING count(DISTINCT one.sha256) >= \(bind: Self.togetherMinimum)
            ORDER BY photos DESC, first, second
            LIMIT \(bind: limit)
            """).all(decoding: Row.self)
        return rows.map { PeopleTogether(people: [$0.first, $0.second], photoCount: $0.photos) }
    }

    /// How many photos two people need together to have an album of them.
    /// Fewer in the smoke tests.
    static let togetherMinimum = Environment.get("FRAMESTATION_TOGETHER_MINIMUM").flatMap(Int.init) ?? 5
    static let togetherLimit = 6

    // MARK: - Faces

    @Sendable
    func personFace(req: Request) async throws -> Response {
        let (userID, spaceID) = try await Self.requireOwnLibrary(req)
        let personID = try await Self.requirePerson(req, userID: userID)
        struct Row: Decodable { let sha256: String; let ordinal: Int }
        guard let cover = try await req.sql.raw("""
            SELECT c.sha256, c.ordinal::int AS ordinal
            FROM person_faces c
            JOIN nas_faces f ON f.user_id = c.user_id AND f.sha256 = c.sha256 AND f.ordinal = c.ordinal
            JOIN assets a ON a.sha256 = c.sha256
            JOIN space_assets sa ON sa.asset_id = a.id AND sa.space_id = \(bind: spaceID) AND sa.deleted_at IS NULL
            WHERE c.person_id = \(bind: personID) AND c.state IN ('auto', 'confirmed')
            ORDER BY \(unsafeRaw: Self.coverOrder), c.sha256, c.ordinal
            LIMIT 1
            """).first(decoding: Row.self)
        else { throw Abort(.notFound) }
        return try await FaceCrop.serve(req, userID: userID, sha256: cover.sha256, ordinal: cover.ordinal)
    }

    @Sendable
    func assetFace(req: Request) async throws -> Response {
        let (userID, spaceID) = try await Self.requireOwnLibrary(req)
        let assetID = try req.parameters.require("assetID", as: UUID.self)
        let ordinal = try req.parameters.require("ordinal", as: Int.self)
        struct Row: Decodable { let sha256: String }
        guard let row = try await req.sql.raw("""
            SELECT a.sha256 FROM assets a
            JOIN space_assets sa ON sa.asset_id = a.id AND sa.space_id = \(bind: spaceID) AND sa.deleted_at IS NULL
            WHERE a.id = \(bind: assetID)
            """).first(decoding: Row.self)
        else { throw Abort(.notFound) }
        return try await FaceCrop.serve(req, userID: userID, sha256: row.sha256, ordinal: ordinal)
    }
}

/// A square picture of one face, cropped from the owner's own photo or video
/// frame, made once and kept beside the file's thumbnails.
enum FaceCrop {
    static let size = 256
    /// How much of the head and shoulders around the face is kept.
    static let margin: Float = 1.8
    /// Part of every crop's file name and of `PersonSummary.face`: moved
    /// when crops are made differently, so neither the NAS nor a device's
    /// cache goes on serving the old ones. 2: leveled by the eyes. 3: a
    /// photo's rotation tag applied once, not twice (see the last step).
    static let version = 3

    static func serve(_ req: Request, userID: UUID, sha256: String, ordinal: Int) async throws -> Response {
        let path = try await crop(app: req.application, userID: userID, sha256: sha256, ordinal: ordinal)
        let response = try await req.fileio.asyncStreamFile(at: path.path)
        response.headers.replaceOrAdd(name: .contentType, value: "image/jpeg")
        response.headers.replaceOrAdd(name: .cacheControl, value: "private, max-age=86400")
        return response
    }

    static func crop(app: Application, userID: UUID, sha256: String, ordinal: Int) async throws -> URL {
        struct Face: Decodable { let box: [Float]; let landmarks: [Float]; let frameMS: Int? }
        guard let face = try await app.sql.raw("""
            SELECT box, landmarks, frame_ms AS "frameMS" FROM nas_faces
            WHERE user_id = \(bind: userID) AND sha256 = \(bind: sha256) AND ordinal = \(bind: ordinal)
            """).first(decoding: Face.self), face.box.count == 4
        else { throw Abort(.notFound) }
        let directory = app.blobStore.derivativeDirectory(sha256: sha256)
        let boxKey = face.box.map { String(Int(($0 * 10_000).rounded())) }.joined(separator: "-")
        let target = directory.appendingPathComponent("face\(version)-\(ordinal)-\(boxKey).jpg")
        if FileManager.default.fileExists(atPath: target.path) { return target }

        struct File: Decodable { let storagePath: String?; let blobExt: String; let mediaType: String }
        guard let file = try await app.sql.raw("""
            SELECT storage_path AS "storagePath", blob_ext AS "blobExt", media_type AS "mediaType"
            FROM assets WHERE sha256 = \(bind: sha256) LIMIT 1
            """).first(decoding: File.self)
        else { throw Abort(.notFound) }
        let source: URL
        if let library = file.storagePath, FileManager.default.fileExists(atPath: library) {
            source = URL(fileURLWithPath: library)
        } else {
            source = app.blobStore.blobPath(sha256: sha256, fileExtension: file.blobExt)
        }
        guard FileManager.default.fileExists(atPath: source.path) else { throw Abort(.notFound) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let work = directory.appendingPathComponent(".face-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // Upright, as the analyzer saw it: vips turns photos by their EXIF,
        // ffmpeg turns video frames by their rotation.
        var still = source
        if file.mediaType == MediaType.video.rawValue {
            let frame = work.appendingPathComponent("frame.png")
            let seconds = String(format: "%.3f", Double(face.frameMS ?? 0) / 1000)
            try await Shell.runChecked("ffmpeg", ["-nostdin", "-loglevel", "error", "-ss", seconds,
                                                  "-i", source.path, "-frames:v", "1", "-y", frame.path], timeout: 120)
            still = frame
        }
        let upright = work.appendingPathComponent("upright.v")
        try await Shell.runChecked("vips", ["thumbnail", still.path, upright.path, "1600"], timeout: 120)
        let width = try await dimension("width", of: upright)
        let height = try await dimension("height", of: upright)
        let (x, y, w, h) = (face.box[0], face.box[1], face.box[2], face.box[3])
        let side = min(max(w * Float(width), h * Float(height)) * margin, Float(min(width, height)))
        let cx = (x + w / 2) * Float(width), cy = (y + h / 2) * Float(height)
        let left = Int(min(max(cx - side / 2, 0), Float(width) - side))
        let top = Int(min(max(cy - side / 2, 0), Float(height) - side))
        var square = work.appendingPathComponent("square.v")
        try await Shell.runChecked("vips", ["extract_area", upright.path, square.path,
                                            "\(left)", "\(top)", "\(Int(side))", "\(Int(side))"], timeout: 60)
        // A face can be tilted in the picture itself: someone lying down, a
        // baby held, a selfie from above. Turned upright by its eyes, to the
        // nearest quarter turn, as Photos draws its People.
        if let turn = uprightTurn(landmarks: face.landmarks, width: width, height: height) {
            let level = work.appendingPathComponent("level.v")
            try await Shell.runChecked("vips", ["rot", square.path, level.path, turn], timeout: 60)
            square = level
        }
        // Never by the photo's rotation tag again: the first step stood the
        // picture up, but the NAS's vips (8.12) leaves the tag on what it
        // made, and a second thumbnail turned every tagged photo's face a
        // second time. That was the sideways and upside-down circles.
        // `Scripts/smoke-image.sh` checks it in the image that ships.
        let partial = work.appendingPathComponent("face.jpg")
        try await Shell.runChecked(
            "vips", ["thumbnail", square.path, partial.path + "[Q=85,strip]", "\(size)", "--no-rotate"],
            timeout: 60
        )
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: partial, to: target)
        return target
    }

    /// The clockwise quarter turn (`vips rot`'s `d90`, `d180` or `d270`) that
    /// stands a face up, or nil when it's upright already. From the line
    /// between its eyes, in pixels: YuNet lists the subject's right eye
    /// first, which is on the left of an upright face, so in an upright face
    /// that line points right.
    static func uprightTurn(landmarks: [Float], width: Int, height: Int) -> String? {
        guard landmarks.count >= 4 else { return nil }
        let dx = Double(landmarks[2] - landmarks[0]) * Double(width)
        let dy = Double(landmarks[3] - landmarks[1]) * Double(height)
        guard dx != 0 || dy != 0 else { return nil }
        // Clockwise from pointing right, as y grows downward.
        let degrees = atan2(dy, dx) * 180 / .pi
        let quarters = ((Int((degrees / 90).rounded()) % 4) + 4) % 4
        switch quarters {
        case 1: return "d270"  // turned a quarter clockwise: back a quarter
        case 2: return "d180"
        case 3: return "d90"
        default: return nil
        }
    }

    private static func dimension(_ field: String, of image: URL) async throws -> Int {
        let result = try await Shell.runChecked("vipsheader", ["-f", field, image.path], timeout: 30)
        guard let value = Int(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Abort(.internalServerError, reason: "Couldn't read the image's size.")
        }
        return value
    }
}
