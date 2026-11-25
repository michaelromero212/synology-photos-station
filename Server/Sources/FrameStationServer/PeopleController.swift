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
        people.post(":personID", "maybe", use: answerMaybe)
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

    /// The face that stands for each of these people in their circle: a clean
    /// headshot, so who it is shows at a glance (his ask, 2026-11-10). By the
    /// person's file and face, for those with any face in this library.
    ///
    /// Clean means all of these, from what the NAS measured when it found
    /// the face:
    /// - surely them: one the owner confirmed, or a close match;
    /// - level and facing the camera: the eyes side by side, the right eye
    ///   on the left, and the nose between them;
    /// - big enough to be sharp in the circle, and found with confidence;
    /// - with room around it, so the circle isn't cut off by the photo's
    ///   edge;
    /// - from a photo, not a video frame or a screenshot.
    ///
    /// Of those, one from the last two years they were photographed, so a
    /// child looks like they do now, and then the sharpest for them, the
    /// biggest, the most like them, from a photo the owner's phone rated
    /// well. Someone with no clean face gets their best one anyway: level
    /// first, then a photo, then the clearest.
    ///
    /// With the crop version its circle is cut at, decided as `FaceCrop.crop`
    /// decides the file's name (see `FaceCrop.version`).
    static func covers(
        of people: [UUID], userID: UUID, spaceID: UUID, on sql: any SQLDatabase
    ) async throws -> [UUID: (sha256: String, ordinal: Int, version: Int)] {
        guard !people.isEmpty else { return [:] }
        struct Cover: Decodable { let personID: UUID; let sha256: String; let ordinal: Int; let isHDRVideo: Bool }
        // Landmarks are x, y pairs in fractions of the frame: right eye, left
        // eye, nose, then the mouth's corners. Scaled by the photo's own
        // width and height, which are as it's shown, so angles are true.
        let rows = try await sql.raw("""
            WITH faces AS (
                SELECT c.person_id, c.sha256, c.ordinal, f.box, f.landmarks, f.score, f.size_px, f.sharpness,
                       f.frame_ms IS NULL AS still,
                       c.state = 'confirmed' OR c.similarity >= \(bind: Self.sureLikeness) AS sure,
                       COALESCE(c.similarity, 0.8)::float8 AS likeness,
                       a.local_captured_at AS taken,
                       COALESCE(NULLIF(a.width, 0), 1)::float8 AS w,
                       COALESCE(NULLIF(a.height, 0), 1)::float8 AS h,
                       COALESCE(o.is_utility OR 'utility' = ANY(o.tags), false) AS utility,
                       COALESCE(o.aesthetic, 0)::float8 AS aesthetic
                FROM person_faces c
                JOIN nas_faces f ON f.user_id = c.user_id AND f.sha256 = c.sha256 AND f.ordinal = c.ordinal
                JOIN assets a ON a.sha256 = c.sha256
                JOIN space_assets sa ON sa.asset_id = a.id AND sa.space_id = \(bind: spaceID)
                                    AND sa.deleted_at IS NULL
                LEFT JOIN media_observations o ON o.user_id = c.user_id AND o.sha256 = c.sha256
                WHERE c.user_id = \(bind: userID) AND c.person_id = ANY(\(bind: people)::uuid[])
                  AND c.state IN ('auto', 'confirmed')
            ),
            measured AS (
                SELECT *,
                       (landmarks[3] - landmarks[1]) * w AS dx,
                       (landmarks[4] - landmarks[2]) * h AS dy,
                       abs(landmarks[5] - (landmarks[1] + landmarks[3]) / 2) * w AS off,
                       \(unsafeRaw: String(FaceCrop.margin)) * greatest(box[3] * w, box[4] * h) AS side,
                       (box[1] + box[3] / 2) * w AS cx,
                       (box[2] + box[4] / 2) * h AS cy,
                       percent_rank() OVER (PARTITION BY person_id ORDER BY sharpness) AS sharper,
                       COALESCE(taken >= max(taken) OVER (PARTITION BY person_id) - interval '2 years', false)
                           AS recent
                FROM faces
            ),
            judged AS (
                SELECT *,
                       dx > 0 AND abs(dy) <= \(unsafeRaw: String(Self.levelSlope)) * dx AS level,
                       sure AND still AND NOT utility
                           AND dx > 0 AND abs(dy) <= \(unsafeRaw: String(Self.levelSlope)) * dx
                           AND off <= \(unsafeRaw: String(Self.frontalOffset)) * dx
                           AND size_px >= \(unsafeRaw: String(Self.headshotPixels))
                           AND score >= \(unsafeRaw: String(Self.headshotScore))
                           AND cx - side / 2 >= 0 AND cx + side / 2 <= w
                           AND cy - side / 2 >= 0 AND cy + side / 2 <= h AS clean,
                       score * least(size_px, 200) * (0.5 + sharper) * likeness * (2 + aesthetic) AS quality
                FROM measured
            ),
            picked AS (
                SELECT DISTINCT ON (person_id) person_id, sha256, ordinal
                FROM judged
                ORDER BY person_id, clean DESC, (clean AND recent) DESC, level DESC, still DESC,
                         quality DESC, sha256, ordinal
            )
            -- Whether it's an HDR video's, for its key, only for the face
            -- picked: one look-up per person, not per face.
            SELECT person_id AS "personID", sha256, ordinal::int AS ordinal,
                   \(unsafeRaw: FaceCrop.hdrVideo(sha256: "picked.sha256")) AS "isHDRVideo"
            FROM picked
            """).all(decoding: Cover.self)
        return Dictionary(
            rows.map { ($0.personID, ($0.sha256, $0.ordinal, FaceCrop.version(isHDRVideo: $0.isHDRVideo))) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// A face placed this close to someone's others is surely them.
    static let sureLikeness: Float = 0.6
    /// Level: tilted no more than 15 degrees (tan 15° ≈ 0.27).
    static let levelSlope = 0.27
    /// Facing the camera: the nose within a fifth of the eyes' distance of
    /// the point between them.
    static let frontalOffset = 0.2
    /// Big and sure enough for a circle: the face's shorter side in the
    /// analyzer's 1,280-pixel render, and YuNet's confidence.
    static let headshotPixels = 90
    static let headshotScore = 0.8

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

    /// Who someone unnamed must be to get a circle, and to be suggested for
    /// a name. Measured on his library (2026-11-11): every person he named is
    /// in 95+ photos across 26+ days, while 155 unnamed circles ran from a
    /// stranger in 3 photos at one party up. A page of all of them was too
    /// much to go through (his word), so the NAS sorts them, as Photos does,
    /// rather than asking anyone to:
    /// - suggested: in many photos over many days, someone they know. Up to
    ///   `suggestedLimit`, those seen on the most days first, under the named;
    /// - more: seen more than once, behind one More People row;
    /// - no circle: one day only, or a handful of photos. Their photos stay,
    ///   and they come back on their own once they turn up on other days.
    enum Tier {
        static let suggestedPhotos = 20
        static let suggestedDays = 5
        static let suggestedLimit = 18
        static let morePhotos = 5
        static let moreDays = 2
    }

    /// The people to show, named first, then those suggested for a name,
    /// then the rest; see `Tier`. `withMore` false leaves out the rest, for
    /// the Albums page's row.
    ///
    /// Someone unnamed the NAS has a question about ("Is this Emma?", see
    /// `PeopleClusterer`) carries it as `maybe`, and if they'd be listed at
    /// all, they're suggested ahead of everyone else suggested, the closest
    /// first, within the same `Tier.suggestedLimit`. So the page never has
    /// more unnamed circles than before, and the ones with a question come
    /// first. A question is shown only while the named person is still the
    /// owner's, named and not hidden, and no face of the group has been said
    /// not to be them, whatever the last pass wrote.
    static func summaries(
        userID: UUID, spaceID: UUID, limit: Int, only: UUID? = nil, withMore: Bool = true,
        on sql: any SQLDatabase
    ) async throws -> [PersonSummary] {
        struct Row: Decodable {
            let id: UUID
            let name: String?
            let relation: String?
            let isMe: Bool
            let photos: Int
            let questions: Int
            let tier: String
            let maybeID: UUID?
            let maybeName: String?
        }
        // Tiers are decided over everyone before one person is picked out,
        // so someone's tier is the same on their own and in the list.
        //
        // The question costs this page load little: `maybe_id` comes along
        // in the one scan of people that's already made, and the named
        // person is looked up by key, after the counting, only for the few
        // rows that have one. The check that the owner hasn't said no reads
        // only the named person's rejected faces, by index, and only then.
        let filter: SQLQueryString = only.map { "AND t.id = \(bind: $0)" } ?? ""
        let more: SQLQueryString = withMore ? "" : "AND t.tier <> 'more'"
        let rows = try await sql.raw("""
            WITH counted AS (
                SELECT p.id, p.name, p.relation, p.is_me, p.maybe_id, p.maybe_similarity,
                       count(DISTINCT pf.sha256)::int AS photos,
                       -- Days apart, by the clock where each was taken.
                       count(DISTINCT a.local_captured_at::date)::int AS days
                FROM people p
                JOIN person_faces pf ON pf.person_id = p.id AND pf.state IN ('auto', 'confirmed')
                JOIN assets a ON a.sha256 = pf.sha256
                JOIN space_assets sa ON sa.asset_id = a.id AND sa.space_id = \(bind: spaceID)
                                    AND sa.deleted_at IS NULL
                WHERE p.user_id = \(bind: userID) AND NOT p.hidden
                  AND \(unsafeRaw: TimelineController.visible)
                GROUP BY p.id, p.name, p.relation, p.is_me, p.maybe_id, p.maybe_similarity
            ), judged AS (
                SELECT c.*,
                       (c.name IS NOT NULL OR c.is_me) AS named,
                       (c.name IS NULL AND NOT c.is_me
                        AND c.photos >= \(bind: Tier.suggestedPhotos) AND c.days >= \(bind: Tier.suggestedDays)) AS likely,
                       m.id AS asked, m.name AS asked_name,
                       -- Someone who'd be listed anyway, with a question.
                       (m.id IS NOT NULL
                        AND c.photos >= \(bind: Tier.morePhotos) AND c.days >= \(bind: Tier.moreDays)) AS asking
                FROM counted c
                LEFT JOIN people m ON m.id = c.maybe_id AND c.name IS NULL AND NOT c.is_me
                                  AND m.user_id = \(bind: userID) AND m.name IS NOT NULL AND NOT m.hidden
                                  AND NOT EXISTS (
                                      SELECT 1 FROM person_faces r
                                      JOIN person_faces g ON g.user_id = r.user_id AND g.sha256 = r.sha256
                                                         AND g.ordinal = r.ordinal AND g.person_id = c.id
                                                         AND g.state IN ('auto', 'confirmed')
                                      WHERE r.person_id = m.id AND r.state = 'rejected')
            ), ranked AS (
                SELECT *, row_number() OVER (
                           PARTITION BY (asking OR likely)
                           ORDER BY asking DESC, CASE WHEN asking THEN maybe_similarity END DESC NULLS LAST,
                                    days DESC, photos DESC, id) AS place
                FROM judged
            ), t AS (
                SELECT *,
                       CASE WHEN named THEN 'named'
                            WHEN (likely OR asking) AND place <= \(bind: Tier.suggestedLimit) THEN 'suggested'
                            WHEN photos >= \(bind: Tier.morePhotos) AND days >= \(bind: Tier.moreDays) THEN 'more'
                       END AS tier
                FROM ranked
            )
            SELECT t.id, t.name, t.relation, t.is_me AS "isMe", t.photos, t.tier,
                   t.asked AS "maybeID", t.asked_name AS "maybeName",
                   (SELECT count(*)::int FROM person_faces q
                    WHERE q.person_id = t.id AND q.state = 'suggested') AS questions
            FROM t
            WHERE t.tier IS NOT NULL
              \(more)
              \(filter)
            -- Family and the owner first, then everyone else named, then the
            -- suggested with a question, the closest first, then the other
            -- suggested by how many days they're seen on, then the rest by
            -- how many photos they're in.
            ORDER BY CASE t.tier WHEN 'named' THEN 0 WHEN 'suggested' THEN 1 ELSE 2 END,
                     (t.tier = 'suggested' AND t.asking) DESC,
                     CASE WHEN t.tier = 'suggested' AND t.asking THEN t.place ELSE 0 END,
                     (t.is_me OR (t.relation IS NOT NULL AND t.relation <> 'friend')) DESC,
                     CASE WHEN t.tier = 'suggested' THEN t.place ELSE 0 END,
                     t.photos DESC, t.id
            LIMIT \(bind: limit)
            """).all(decoding: Row.self)
        guard !rows.isEmpty else { return [] }

        // The face that stands for each: a clean headshot. See `covers`. A
        // question's named person is almost always in the list already, so
        // this seldom looks for anyone more.
        let wanted = Array(Set(rows.map(\.id) + rows.compactMap(\.maybeID)))
        let cover = try await Self.covers(of: wanted, userID: userID, spaceID: spaceID, on: sql)
            .mapValues { "\($0.sha256.prefix(12))-\($0.ordinal)-v\($0.version)" }
        return rows.map { row in
            var maybe: PersonMaybe?
            if let id = row.maybeID, let name = row.maybeName {
                maybe = PersonMaybe(id: id, name: name, face: cover[id] ?? "none")
            }
            return PersonSummary(id: row.id, name: row.name, photoCount: row.photos,
                                 face: cover[row.id] ?? "none", questions: row.name == nil ? 0 : row.questions,
                                 relation: row.relation, isMe: row.isMe, tier: row.tier, maybe: maybe)
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
                -- A question about who they are is answered by naming them;
                -- if the name is taken back, the next pass asks afresh.
                maybe_id = NULL, maybe_similarity = NULL,
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
                try await Self.merge(other, into: personID, userID: userID, on: sql)
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
        await req.application.storage[PeopleClustererKey.self]?.touch(userID)
        return try await summary(req, userID: userID, spaceID: spaceID, personID: personID)
    }

    /// The owner says `other` and `person` are one: everything of `other`'s
    /// becomes `person`'s, and `other` goes. For the merge endpoint and a yes
    /// to "Is this Emma?"; run inside the caller's transaction. Never for
    /// the NAS's own merges, which never override the owner (see
    /// `PeopleClusterer.write`).
    ///
    /// The owner's latest word wins. Each face that is `other`'s (auto or
    /// confirmed) becomes `person`'s even where the owner earlier said it
    /// isn't `person`, or it was only a question for them: otherwise a no
    /// tapped by mistake would quietly drop every such face out of a later
    /// "Same Person". What the owner decided about `other` otherwise comes
    /// along only where `person` has nothing about that face, so a face
    /// confirmed for `person` is never made rejected by it.
    static func merge(_ other: UUID, into person: UUID, userID: UUID, on sql: any SQLDatabase) async throws {
        try await sql.raw("""
            INSERT INTO person_faces (user_id, sha256, ordinal, person_id, state, similarity, box, decided_at)
            SELECT user_id, sha256, ordinal, \(bind: person), state, similarity, box, decided_at
            FROM person_faces
            WHERE person_id = \(bind: other) AND user_id = \(bind: userID) AND state IN ('auto', 'confirmed')
            ON CONFLICT (user_id, sha256, ordinal, person_id)
            DO UPDATE SET state = EXCLUDED.state, similarity = EXCLUDED.similarity, decided_at = now()
            WHERE person_faces.state IN ('rejected', 'suggested')
               OR (person_faces.state = 'auto' AND EXCLUDED.state = 'confirmed')
            """).run()
        try await sql.raw("""
            INSERT INTO person_faces (user_id, sha256, ordinal, person_id, state, similarity, box, decided_at)
            SELECT user_id, sha256, ordinal, \(bind: person), state, similarity, box, decided_at
            FROM person_faces
            WHERE person_id = \(bind: other) AND user_id = \(bind: userID) AND state IN ('rejected', 'suggested')
            ON CONFLICT DO NOTHING
            """).run()
        // Their question, if they had one, was about who they were before
        // this; the next pass asks afresh.
        try await sql.raw("""
            UPDATE people SET name = COALESCE(name, (SELECT name FROM people WHERE id = \(bind: other))),
                              maybe_id = NULL, maybe_similarity = NULL,
                              updated_at = now()
            WHERE id = \(bind: person) AND user_id = \(bind: userID)
            """).run()
        try await sql.raw("DELETE FROM people WHERE id = \(bind: other) AND user_id = \(bind: userID)").run()
    }

    /// The owner's answer to "Is this Emma?" for a whole unnamed group (see
    /// `PersonSummary.maybe`), sent for the group with the named person the
    /// app showed. Taken whatever the NAS asks now: it's the owner's word.
    ///
    /// Yes is the owner merging the group into the named person, and answers
    /// with the named person. No says none of the group's faces is them:
    /// each gets a rejected row for them, so the NAS never puts those faces
    /// with them, folds the group into them, or asks about them again. It
    /// answers with the group.
    @Sendable
    func answerMaybe(req: Request) async throws -> PersonSummary {
        let (userID, spaceID) = try await Self.requireOwnLibrary(req)
        let groupID = try await Self.requirePerson(req, userID: userID)
        let body = try req.content.decode(PersonMaybeAnswer.self)
        let named = body.personID
        guard named != groupID else { throw Abort(.badRequest, reason: "That's the same person.") }
        try await req.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                // Both locked, so a pass or another answer can't merge, name
                // or take either away in between.
                struct Person: Decodable { let id: UUID; let named: Bool; let hidden: Bool }
                let both = try await sql.raw("""
                    SELECT id, (name IS NOT NULL OR is_me) AS named, hidden FROM people
                    WHERE id IN (\(bind: groupID), \(bind: named)) AND user_id = \(bind: userID)
                    ORDER BY id
                    FOR UPDATE
                    """).all(decoding: Person.self)
                guard let group = both.first(where: { $0.id == groupID }) else { throw Abort(.notFound) }
                guard let person = both.first(where: { $0.id == named }),
                      person.named, !person.hidden
                else { throw Abort(.notFound) }
                guard !group.named else { throw Abort(.conflict, reason: "They have a name already.") }
                if body.isPerson {
                    try await Self.merge(groupID, into: named, userID: userID, on: sql)
                } else {
                    try await sql.raw("""
                        INSERT INTO person_faces (user_id, sha256, ordinal, person_id, state, similarity, box, decided_at)
                        SELECT user_id, sha256, ordinal, \(bind: named), 'rejected', NULL, box, now()
                        FROM person_faces
                        WHERE person_id = \(bind: groupID) AND user_id = \(bind: userID)
                          AND state IN ('auto', 'confirmed')
                        ON CONFLICT (user_id, sha256, ordinal, person_id)
                        DO UPDATE SET state = 'rejected', similarity = NULL, decided_at = now()
                        WHERE person_faces.state = 'suggested'
                        """).run()
                    try await sql.raw("""
                        UPDATE people SET maybe_id = NULL, maybe_similarity = NULL
                        WHERE id = \(bind: groupID) AND user_id = \(bind: userID)
                        """).run()
                }
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
        await req.application.storage[PeopleClustererKey.self]?.touch(userID)
        return try await summary(req, userID: userID, spaceID: spaceID, personID: body.isPerson ? named : groupID)
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
        let rows = try await Self.suggestedFaces(userID: userID, spaceID: spaceID, personID: personID, on: req.sql)
        return PersonSuggestionsResponse(
            person: try await summary(req, userID: userID, spaceID: spaceID, personID: personID),
            suggestions: rows.map { PersonSuggestion(assetID: $0.assetID, ordinal: $0.ordinal) }
        )
    }

    struct SuggestedFace: Decodable {
        let assetID: UUID
        let ordinal: Int
        let sha256: String
    }

    /// The faces "Is this Emma?" asks about, in the order it asks them: one
    /// photo per face, the closest first. Also the order `FaceCropWarmer`
    /// cuts them in, so the first questions are the first ready.
    static func suggestedFaces(
        userID: UUID, spaceID: UUID, personID: UUID, on sql: any SQLDatabase
    ) async throws -> [SuggestedFace] {
        try await sql.raw("""
            SELECT "assetID", ordinal, sha256 FROM (
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
            """).all(decoding: SuggestedFace.self)
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

    // MARK: - Faces

    @Sendable
    func personFace(req: Request) async throws -> Response {
        let (userID, spaceID) = try await Self.requireOwnLibrary(req)
        let personID = try await Self.requirePerson(req, userID: userID)
        // The same face the People row names in `PersonSummary.face`.
        guard let cover = try await Self.covers(of: [personID], userID: userID, spaceID: spaceID, on: req.sql)[personID]
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
    /// A face's two sizes. `size` fills the small circles: the People rows,
    /// the grid of everyone, a photo's people (78 points at most, 234 pixels
    /// on a phone). `largeSize` fills the big ones: someone's own page and
    /// "Is this Emma?" (224 points there, 672 pixels on a phone), which
    /// `size` left soft (2026-11-16: "faces just need to show up clear and
    /// quickly"). Asked for with `?size=`; only these two are ever made, so a
    /// request can't have the NAS render any size it likes.
    static let size = 256
    static let largeSize = 768

    /// The size a request gets: the large one for anything over the small,
    /// the small one when it doesn't say, as apps from before the large one
    /// don't.
    static func size(requested: Int?) -> Int {
        guard let requested, requested > size else { return size }
        return largeSize
    }

    /// How much of the head and shoulders around the face is kept.
    static let margin: Float = 1.8
    /// Part of every crop's file name and of `PersonSummary.face`: moved
    /// when crops are made differently, so neither the NAS nor a device's
    /// cache goes on serving the old ones. 2: leveled by the eyes. 3: a
    /// photo's rotation tag applied once, not twice (see the last step). 4: a
    /// face small in its photo cut from a bigger render.
    ///
    /// 5, `hdrVideoVersion`: a face from an HDR video, cut from its frame
    /// tone-mapped to SDR, where it came out gray and flat (see
    /// `extractFrame`). Only those faces changed, so only they moved: a
    /// photo's face, an SDR clip's and one from a clip not yet measured stay
    /// at 4, and none of them is cut again, or fetched again by every device,
    /// for the same picture. Which a face is comes from the database
    /// (`hdrVideo`), asked alike for its key (`PeopleController.covers`) and
    /// its file name (`crop`), so the two never disagree. When a clip's
    /// poster or ladder job first measures it as HDR, its faces' keys move to
    /// 5 and every device fetches them anew; the v5 circle is cut then, and
    /// the gray v4 ones are deleted.
    static let version = 4
    static let hdrVideoVersion = 5

    /// A face's version: `hdrVideoVersion` for one from an HDR video,
    /// `version` for every other.
    static func version(isHDRVideo: Bool) -> Int {
        isHDRVideo ? hdrVideoVersion : version
    }

    /// Whether a file's faces are an HDR video's, as SQL for the column that
    /// holds its content hash: a video with a row measured HDR. One file can
    /// have several rows, a shared library's copy or one an import kept, and
    /// each is measured on its own, while its circles are one set beside its
    /// thumbnails. So this goes by the file, not by whichever of its rows a
    /// query reads: a key at 5 is never served the gray circle at 4. A clip
    /// not yet measured (NULL) isn't one, until it is.
    static func hdrVideo(sha256 column: String) -> String {
        """
        EXISTS (SELECT 1 FROM assets clip WHERE clip.sha256 = \(column)
                AND clip.media_type = 'video' AND clip.dynamic_range = 'hdr')
        """
    }

    /// The most a photo is rendered at for a small face: a 48-megapixel
    /// photo's long side is about 8,000.
    static let largestRender = 4096

    static func serve(_ req: Request, userID: UUID, sha256: String, ordinal: Int) async throws -> Response {
        let size = size(requested: req.query[Int.self, at: "size"])
        let path = try await crop(app: req.application, userID: userID, sha256: sha256, ordinal: ordinal, size: size).url
        let response = try await req.fileio.asyncStreamFile(at: path.path)
        response.headers.replaceOrAdd(name: .contentType, value: "image/jpeg")
        response.headers.replaceOrAdd(name: .cacheControl, value: "private, max-age=86400")
        return response
    }

    /// The face's picture, and whether it was made just now rather than
    /// found already made. Usually made ahead by `FaceCropWarmer`. `size` is
    /// `size` or `largeSize`; the small one keeps the file name it always had.
    static func crop(
        app: Application, userID: UUID, sha256: String, ordinal: Int, size: Int = FaceCrop.size
    ) async throws -> (url: URL, made: Bool) {
        let isLarge = size != Self.size
        let size = isLarge ? largeSize : Self.size
        // The face and its file in one query: the file decides the version
        // in the name, and a circle already made still costs one query and a
        // file check.
        struct Face: Decodable {
            let box: [Float]
            let landmarks: [Float]
            let frameMS: Int?
            let storagePath: String?
            let blobExt: String
            let mediaType: String
            let isHDRVideo: Bool
        }
        guard let face = try await app.sql.raw("""
            SELECT f.box, f.landmarks, f.frame_ms AS "frameMS",
                   a.storage_path AS "storagePath", a.blob_ext AS "blobExt", a.media_type AS "mediaType",
                   \(unsafeRaw: hdrVideo(sha256: "f.sha256")) AS "isHDRVideo"
            FROM nas_faces f
            JOIN assets a ON a.sha256 = f.sha256
            WHERE f.user_id = \(bind: userID) AND f.sha256 = \(bind: sha256) AND f.ordinal = \(bind: ordinal)
            LIMIT 1
            """).first(decoding: Face.self), face.box.count == 4
        else { throw Abort(.notFound) }
        let directory = app.blobStore.derivativeDirectory(sha256: sha256)
        let boxKey = face.box.map { String(Int(($0 * 10_000).rounded())) }.joined(separator: "-")
        let target = directory.appendingPathComponent(fileName(
            version: version(isHDRVideo: face.isHDRVideo), ordinal: ordinal, boxKey: boxKey, size: size
        ))
        if FileManager.default.fileExists(atPath: target.path) { return (target, false) }

        let source: URL
        if let library = face.storagePath, FileManager.default.fileExists(atPath: library) {
            source = URL(fileURLWithPath: library)
        } else {
            source = app.blobStore.blobPath(sha256: sha256, fileExtension: face.blobExt)
        }
        guard FileManager.default.fileExists(atPath: source.path) else { throw Abort(.notFound) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let work = directory.appendingPathComponent(".face-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // Upright, as the analyzer saw it: vips turns photos by their EXIF,
        // ffmpeg turns video frames by their rotation.
        var still = source
        if face.mediaType == MediaType.video.rawValue {
            let frame = work.appendingPathComponent("frame.png")
            try await extractFrame(
                of: source, atMS: face.frameMS ?? 0, to: frame, isHDR: face.isHDRVideo,
                face: "\(sha256.prefix(12))-\(ordinal)", logger: app.logger
            )
            still = frame
        }
        var upright = work.appendingPathComponent("upright.v")
        try await Shell.runChecked("vips", ["thumbnail", still.path, upright.path, "1600"], timeout: 120)
        var width = try await dimension("width", of: upright)
        var height = try await dimension("height", of: upright)
        let (x, y, w, h) = (face.box[0], face.box[1], face.box[2], face.box[3])
        // A face small in its photo is cut from a bigger render, so its circle
        // is the photo's own pixels rather than enlarged ones, as far as the
        // photo has them. Never past its own size.
        let wanted = max(w * Float(width), h * Float(height)) * margin
        if wanted < Float(size) {
            let bigger = min(Int((1600 * Float(size) / max(wanted, 1)).rounded(.up)), Self.largestRender)
            let detailed = work.appendingPathComponent("detailed.v")
            try await Shell.runChecked(
                "vips", ["thumbnail", still.path, detailed.path, "\(bigger)", "--size", "down"], timeout: 120
            )
            upright = detailed
            width = try await dimension("width", of: upright)
            height = try await dimension("height", of: upright)
        }
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
        // The large one is never enlarged: a face with fewer pixels in its
        // photo than that comes as it is, and the device draws it to size.
        let partial = work.appendingPathComponent("face.jpg")
        try await Shell.runChecked(
            "vips", ["thumbnail", square.path, partial.path + "[Q=85,strip]", "\(size)", "--no-rotate"]
                + (isLarge ? ["--size", "down"] : []),
            timeout: 60
        )
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: partial, to: target)
        // Its v4 circles, both sizes, were cut from the gray frame, and
        // nothing asks for them once its key has moved, so they go now rather
        // than stay beside the new ones as waste.
        if face.isHDRVideo {
            for old in [Self.size, largeSize] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(
                    fileName(version: version, ordinal: ordinal, boxKey: boxKey, size: old)
                ))
            }
        }
        return (target, true)
    }

    /// A crop's file name. The small one keeps the name it always had.
    private static func fileName(version: Int, ordinal: Int, boxKey: String, size: Int) -> String {
        "face\(version)-\(ordinal)-\(boxKey)\(size == Self.size ? "" : "-\(size)px").jpg"
    }

    /// A video face's frame, as a PNG. An HDR clip's is tone-mapped to SDR as
    /// its poster is (`Derivatives.toneMapFilter`): untoned, an iPhone's HLG
    /// frame is a light gray, and its faces came out gray and flat. Unlike the
    /// poster's, it stays at its own size, as a small face is cut from up to
    /// `largestRender`. Where this machine can't tone-map (Homebrew's ffmpeg
    /// has no zscale), or ffmpeg fails at it, the frame is taken the plain way,
    /// as every face's was before, so a circle is still made, and the log says
    /// which face.
    private static func extractFrame(
        of video: URL, atMS ms: Int, to frame: URL, isHDR: Bool, face: String, logger: Logger
    ) async throws {
        let seconds = String(format: "%.3f", Double(ms) / 1000)
        let arguments = ["-nostdin", "-loglevel", "error", "-ss", seconds,
                         "-i", video.path, "-frames:v", "1", "-y"]
        if isHDR {
            guard let problem = await toneMapFrame(arguments, of: video, to: frame) else { return }
            logger.warning("people: face \(face) from an HDR clip not tone-mapped, cut as before: \(problem)")
        }
        try await Shell.runChecked("ffmpeg", arguments + [frame.path], timeout: 120)
    }

    /// Writes an HDR clip's frame tone-mapped: nil once it's written,
    /// otherwise why it wasn't. One ffprobe for the colors the clip is tagged
    /// with, which the filters say outright.
    private static func toneMapFrame(_ arguments: [String], of video: URL, to frame: URL) async -> String? {
        if let problem = await Derivatives.toneMapProblem() { return problem }
        let signal = await HDRVideo.signal(video)
        guard signal.range.isHDR else { return "ffprobe doesn't read it as HDR" }
        do {
            try await Shell.runChecked(
                "ffmpeg", arguments + ["-vf", Derivatives.toneMapFilter(for: signal, fit: nil), frame.path],
                timeout: 120
            )
        } catch {
            return "ffmpeg failed to tone-map it: \(Derivatives.reason(error))"
        }
        // Not just present: a frame ffmpeg couldn't filter can leave an empty
        // file and still exit 0.
        let size = (try? FileManager.default.attributesOfItem(atPath: frame.path))?[.size] as? NSNumber
        return (size?.int64Value ?? 0) > 0 ? nil : "ffmpeg wrote nothing"
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
