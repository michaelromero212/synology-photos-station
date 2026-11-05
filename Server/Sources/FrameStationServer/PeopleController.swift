import FrameStationAPI
import Foundation
import SQLKit
import Vapor

extension PeopleResponse: @retroactive Content {}
extension PersonSummary: @retroactive Content {}
extension PersonSuggestionsResponse: @retroactive Content {}

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
        protected.get("spaces", ":spaceID", "assets", ":assetID", "faces", ":ordinal", use: assetFace)
    }

    static let pageLimit = 20
    static let listLimit = 500

    // MARK: - Who can ask

    /// 404 unless the space is the caller's own personal library and the NAS
    /// analyzes it.
    static func requireOwnLibrary(_ req: Request) async throws -> (userID: UUID, spaceID: UUID) {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let context = try await CurationController.context(userID: device.userID, spaceID: spaceID, on: req.sql)
        guard context.isPersonal, context.nas != "off" else { throw Abort(.notFound) }
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
            let photos: Int
            let questions: Int
        }
        let filter: SQLQueryString = only.map { "AND p.id = \(bind: $0)" } ?? ""
        let rows = try await sql.raw("""
            SELECT p.id, p.name, count(DISTINCT pf.sha256)::int AS photos,
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
            GROUP BY p.id, p.name
            HAVING count(DISTINCT pf.sha256) >= CASE WHEN p.name IS NULL THEN 3 ELSE 1 END
            ORDER BY (p.name IS NOT NULL) DESC, photos DESC, p.id
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
            ORDER BY c.person_id, (c.state = 'confirmed') DESC, (f.frame_ms IS NULL) DESC,
                     f.size_px * f.score DESC, c.sha256, c.ordinal
            """).all(decoding: Cover.self)
        let cover = Dictionary(uniqueKeysWithValues: covers.map { ($0.personID, "\($0.sha256.prefix(12))-\($0.ordinal)") })
        return rows.map {
            PersonSummary(id: $0.id, name: $0.name, photoCount: $0.photos,
                          face: cover[$0.id] ?? "none", questions: $0.name == nil ? 0 : $0.questions)
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
        struct Row: Decodable { let name: String? }
        let row = try await req.sql.raw("SELECT name FROM people WHERE id = \(bind: personID)").first(decoding: Row.self)
        return PersonSummary(id: personID, name: row?.name, photoCount: 0, face: "none")
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
            ORDER BY (c.state = 'confirmed') DESC, (f.frame_ms IS NULL) DESC,
                     f.size_px * f.score DESC, c.sha256, c.ordinal
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

    static func serve(_ req: Request, userID: UUID, sha256: String, ordinal: Int) async throws -> Response {
        let path = try await crop(app: req.application, userID: userID, sha256: sha256, ordinal: ordinal)
        let response = try await req.fileio.asyncStreamFile(at: path.path)
        response.headers.replaceOrAdd(name: .contentType, value: "image/jpeg")
        response.headers.replaceOrAdd(name: .cacheControl, value: "private, max-age=86400")
        return response
    }

    static func crop(app: Application, userID: UUID, sha256: String, ordinal: Int) async throws -> URL {
        struct Face: Decodable { let box: [Float]; let frameMS: Int? }
        guard let face = try await app.sql.raw("""
            SELECT box, frame_ms AS "frameMS" FROM nas_faces
            WHERE user_id = \(bind: userID) AND sha256 = \(bind: sha256) AND ordinal = \(bind: ordinal)
            """).first(decoding: Face.self), face.box.count == 4
        else { throw Abort(.notFound) }
        let directory = app.blobStore.derivativeDirectory(sha256: sha256)
        let boxKey = face.box.map { String(Int(($0 * 10_000).rounded())) }.joined(separator: "-")
        let target = directory.appendingPathComponent("face-\(ordinal)-\(boxKey).jpg")
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
        let square = work.appendingPathComponent("square.v")
        try await Shell.runChecked("vips", ["extract_area", upright.path, square.path,
                                            "\(left)", "\(top)", "\(Int(side))", "\(Int(side))"], timeout: 60)
        let partial = work.appendingPathComponent("face.jpg")
        try await Shell.runChecked("vips", ["thumbnail", square.path, partial.path + "[Q=85,strip]", "\(size)"], timeout: 60)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: partial, to: target)
        return target
    }

    private static func dimension(_ field: String, of image: URL) async throws -> Int {
        let result = try await Shell.runChecked("vipsheader", ["-f", field, image.path], timeout: 30)
        guard let value = Int(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Abort(.internalServerError, reason: "Couldn't read the image's size.")
        }
        return value
    }
}
