import FrameStationAPI
import Foundation
import SQLKit
import Vapor

extension SetRatingRequest: @retroactive Content {}
extension EditTagsRequest: @retroactive Content {}
extension TagListResponse: @retroactive Content {}
extension SetLocationRequest: @retroactive Content {}
extension SetLocationResponse: @retroactive Content {}

/// Ratings and tags — the metadata a person edits by hand.
///
/// Both hang off the *placement*, not the file. The same photo in Personal and
/// in Family Shared can carry different tags, and rating it in one library
/// doesn't rate it in the other. That is deliberate: a tag is what this library
/// calls the photo, not a property of the bytes.
///
/// Unlike favourites they are not per-user either. "Mom favourited this" and
/// "I favourited this" are separate facts, but a shared space agreeing that a
/// photo is tagged Beach is the entire point of tagging it — so these are
/// contributor-gated writes to one shared value, scoped exactly the way
/// `AssetController.remove` is.
struct MetadataController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(DeviceTokenAuthenticator())
            .grouped(AuthenticatedDevice.guardMiddleware())

        protected.put("spaces", ":spaceID", "assets", ":assetID", "rating", use: setRating)
        protected.post("spaces", ":spaceID", "assets", ":assetID", "tags", use: editTags)
        protected.get("spaces", ":spaceID", "tags", use: spaceTags)
        protected.put("spaces", ":spaceID", "assets", ":assetID", "location", use: setLocation)
    }

    // MARK: - Location

    /// Corrects where a photo was taken, or clears it.
    ///
    /// Unlike tags and ratings this is a property of the *file*, not of the
    /// placement: a photograph was taken in one place, and the same photo in two
    /// libraries cannot honestly have been taken in two. So it writes to
    /// `assets` — but the write is still gated on being a contributor to a space
    /// the photo is in, which is what proves you may touch it at all.
    ///
    /// `place_name` is re-derived here rather than accepted from the client.
    /// Search matches on that column, so a name the server didn't produce would
    /// be a place you could see and not find. Coordinates are the input; the
    /// words are the server's to choose.
    @Sendable
    func setLocation(req: Request) async throws -> SetLocationResponse {
        let input = try req.content.decode(SetLocationRequest.self)

        // Both or neither. Half a coordinate places a photo on the equator or
        // the meridian, which is worse than leaving it unplaced.
        let latitude = input.latitude
        let longitude = input.longitude
        guard (latitude == nil) == (longitude == nil) else {
            throw Abort(.badRequest, reason: "A location needs both a latitude and a longitude.")
        }
        if let latitude, let longitude {
            guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                throw Abort(.badRequest, reason: "That isn't a point on Earth.")
            }
        }

        // Called for its access check and its "is this photo actually here?"
        // check; the asset id itself comes off the route, since the location
        // belongs to the file rather than to this one placement of it.
        _ = try await writablePlacement(req)
        let assetID = try req.parameters.require("assetID", as: UUID.self)
        let placeName = latitude.flatMap { lat in
            longitude.flatMap { req.application.geocoder?.label(latitude: lat, longitude: $0) }
        }

        try await req.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                try await sql.raw("""
                    UPDATE assets
                    SET lat = \(bind: latitude),
                        lon = \(bind: longitude),
                        place_name = \(bind: placeName)
                    WHERE id = \(bind: assetID)
                    """).run()
                // Every space holding this photo hears about it: the day headers
                // carry the place, so a correction that only reached one library
                // would leave the others captioned with the old one.
                let placements = try await sql.raw("""
                    SELECT space_id AS "spaceID", id FROM space_assets
                    WHERE asset_id = \(bind: assetID) AND deleted_at IS NULL
                    """).all(decoding: PlacementRow.self)
                for placement in placements {
                    _ = try await ChangeLog.append(
                        spaceID: placement.spaceID, entity: "space_asset",
                        entityID: placement.id, op: "update", on: sql
                    )
                }
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }

        return SetLocationResponse(
            latitude: latitude, longitude: longitude, placeName: placeName
        )
    }

    private struct PlacementRow: Decodable {
        let spaceID: UUID
        let id: UUID
    }

    private struct IDRow: Decodable { let id: UUID }
    private struct TagRow: Decodable { let name: String }

    // MARK: - Rating

    @Sendable
    func setRating(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(SetRatingRequest.self)
        guard (0...5).contains(input.rating) else {
            throw Abort(.badRequest, reason: "A rating is 0 to 5 stars.")
        }
        let target = try await writablePlacement(req)

        // Zero stars is "unrated", and NULL is how the column already says
        // that. Storing a literal 0 would give the same state two spellings,
        // and every reader would have to know both.
        let stars: Int? = input.rating == 0 ? nil : input.rating

        try await req.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                try await sql.raw("""
                    UPDATE space_assets SET rating = \(bind: stars)::smallint
                    WHERE id = \(bind: target.id)
                    """).run()
                // Other devices — and other members of a shared space — learn
                // about this through the same delta-sync path as everything
                // else, so it can't be a bare UPDATE.
                _ = try await ChangeLog.append(
                    spaceID: target.spaceID, entity: "space_asset",
                    entityID: target.id, op: "update", on: sql
                )
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
        return .noContent
    }

    // MARK: - Tags

    /// Applies one edit and returns what the photo is tagged afterwards.
    ///
    /// Returning the result rather than 204 is what lets the viewer redraw its
    /// tag row without refetching the whole detail payload.
    @Sendable
    func editTags(req: Request) async throws -> TagListResponse {
        let input = try req.content.decode(EditTagsRequest.self)
        let add = try Self.normalized(input.add)
        let remove = try Self.normalized(input.remove)
        guard !add.isEmpty || !remove.isEmpty else {
            throw Abort(.badRequest, reason: "Nothing to add or remove.")
        }
        let target = try await writablePlacement(req)

        try await req.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                // Removals first, so "remove Beach, add Beach Day" reads as the
                // rename it looks like rather than depending on order.
                for name in remove {
                    try await detach(name, from: target.id, in: target.spaceID, on: sql)
                }
                for name in add {
                    try await attach(name, to: target.id, in: target.spaceID, on: sql)
                }
                _ = try await ChangeLog.append(
                    spaceID: target.spaceID, entity: "space_asset",
                    entityID: target.id, op: "update", on: sql
                )
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
        return TagListResponse(tags: try await tags(of: target.id, on: req.sql))
    }

    /// Every tag in use in this library.
    ///
    /// The editor offers these rather than making someone retype a name they
    /// already invented — and across a multi-photo selection it is the only way
    /// to *remove* a tag without knowing in advance what the photos carry.
    @Sendable
    func spaceTags(req: Request) async throws -> TagListResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)

        // Reading is membership, not contribution: a viewer can see the tags,
        // they just can't change them.
        try await SpaceAccess.requireMembership(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )

        // EXISTS rather than a join and DISTINCT: a tag on forty photos is
        // still one name, and this keeps it one row without having to dedupe
        // afterwards. The live-placement check stops a name that only survives
        // on a deleted photo being offered.
        let rows = try await req.sql.raw("""
            SELECT t.name
            FROM tags t
            WHERE t.space_id = \(bind: spaceID)
              AND EXISTS (
                  SELECT 1 FROM space_asset_tags st
                  JOIN space_assets sa ON sa.id = st.space_asset_id
                  WHERE st.tag_id = t.id AND sa.deleted_at IS NULL
              )
            ORDER BY lower(t.name)
            """).all(decoding: TagRow.self)
        return TagListResponse(tags: rows.map(\.name))
    }

    // MARK: - Helpers

    /// The placement this call acts on, once the caller is known to be allowed
    /// to write to it.
    ///
    /// Contributor or better, and a placement you can't see is 404 rather than
    /// 403 — refusing in a way that confirms the photo exists is itself the
    /// leak. Same shape as `AssetController.remove`.
    private func writablePlacement(_ req: Request) async throws -> (id: UUID, spaceID: UUID) {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let spaceID = try req.parameters.require("spaceID", as: UUID.self)
        let assetID = try req.parameters.require("assetID", as: UUID.self)

        try await SpaceAccess.requireContributor(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )

        guard let row = try await req.sql.raw("""
            SELECT id FROM space_assets
            WHERE space_id = \(bind: spaceID) AND asset_id = \(bind: assetID)
              AND deleted_at IS NULL
            """).first(decoding: IDRow.self) else {
            throw Abort(.notFound, reason: "No such asset in this space.")
        }
        return (row.id, spaceID)
    }

    /// Attaches one tag, creating it for the space on first use.
    ///
    /// Matched case-insensitively, so a library doesn't end up with Beach,
    /// beach and BEACH as three tags that mean one thing; whichever spelling
    /// was used first is the one kept.
    private func attach(
        _ name: String, to placementID: UUID, in spaceID: UUID, on sql: any SQLDatabase
    ) async throws {
        let tagID: UUID
        if let existing = try await sql.raw("""
            SELECT id FROM tags
            WHERE space_id = \(bind: spaceID) AND lower(name) = lower(\(bind: name))
            """).first(decoding: IDRow.self) {
            tagID = existing.id
        } else {
            // DO UPDATE rather than DO NOTHING: on conflict, DO NOTHING returns
            // no row at all, so a tag another request created a moment earlier
            // would look like an insert that failed.
            guard let created = try await sql.raw("""
                INSERT INTO tags (space_id, name)
                VALUES (\(bind: spaceID), \(bind: name))
                ON CONFLICT (space_id, name) DO UPDATE SET name = EXCLUDED.name
                RETURNING id
                """).first(decoding: IDRow.self) else {
                throw Abort(.internalServerError, reason: "Could not create the tag.")
            }
            tagID = created.id
        }

        try await sql.raw("""
            INSERT INTO space_asset_tags (space_asset_id, tag_id)
            VALUES (\(bind: placementID), \(bind: tagID))
            ON CONFLICT DO NOTHING
            """).run()
    }

    private func detach(
        _ name: String, from placementID: UUID, in spaceID: UUID, on sql: any SQLDatabase
    ) async throws {
        try await sql.raw("""
            DELETE FROM space_asset_tags st
            USING tags t
            WHERE st.tag_id = t.id
              AND st.space_asset_id = \(bind: placementID)
              AND t.space_id = \(bind: spaceID)
              AND lower(t.name) = lower(\(bind: name))
            """).run()

        // A tag exists because something carries it. Once nothing does, leaving
        // the row behind would have the space's tag list offering names that
        // match no photo.
        try await sql.raw("""
            DELETE FROM tags t
            WHERE t.space_id = \(bind: spaceID)
              AND lower(t.name) = lower(\(bind: name))
              AND NOT EXISTS (
                  SELECT 1 FROM space_asset_tags st WHERE st.tag_id = t.id
              )
            """).run()
    }

    /// Sorted case-insensitively, or "beach day" files after "Sunset" and the
    /// tag row in the viewer looks unsorted to anyone who didn't capitalise.
    private func tags(of placementID: UUID, on sql: any SQLDatabase) async throws -> [String] {
        try await sql.raw("""
            SELECT t.name FROM tags t
            JOIN space_asset_tags st ON st.tag_id = t.id
            WHERE st.space_asset_id = \(bind: placementID)
            ORDER BY lower(t.name)
            """).all(decoding: TagRow.self).map(\.name)
    }

    /// Trims, collapses inner whitespace, and drops repeats.
    ///
    /// Names come out of a text field, where " beach " and "beach" are the same
    /// tag to the person typing them.
    static func normalized(_ names: [String]) throws -> [String] {
        guard names.count <= 50 else {
            throw Abort(.badRequest, reason: "Edit at most 50 tags at a time.")
        }
        var seen: Set<String> = []
        var result: [String] = []
        for raw in names {
            let name = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !name.isEmpty else { continue }
            guard name.count <= 60 else {
                throw Abort(.badRequest, reason: "A tag can be at most 60 characters.")
            }
            if seen.insert(name.lowercased()).inserted { result.append(name) }
        }
        return result
    }
}
