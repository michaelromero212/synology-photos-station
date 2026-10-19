import FrameStationAPI
import Foundation
import SQLKit
import Vapor

extension AlbumListResponse: @retroactive Content {}
extension AlbumDTO: @retroactive Content {}
extension CreateAlbumRequest: @retroactive Content {}
extension UpdateAlbumRequest: @retroactive Content {}
extension AlbumAssetsRequest: @retroactive Content {}
extension SetAlbumPeopleRequest: @retroactive Content {}

/// Albums: collections you build by hand, cutting across dates. Three kinds.
///
/// **Yours alone**, the default (`space_id` null). Private to its owner: nobody
/// else can see one, list one, or learn that it exists — including members of a
/// library whose photos it contains. Contents are placements in any library the
/// owner belongs to, re-checked on every read, so leaving a shared library
/// takes its photos back out rather than leaving a private window into a space
/// you were removed from.
///
/// **Shared with people** you chose: the family for one album, two cousins for
/// another. Such an album has a space of its own, kind `album`, holding exactly
/// its people and its photos, so every check that decides who may see a photo
/// applies to it unchanged. A photo added from your library is shared into
/// that space, and only its people see it. Everyone in it can add; its owner
/// chooses who's in it, renames it and deletes it. Leave everyone out and it's
/// yours alone again. Older apps never see one: they'd look for a library
/// that, to them, isn't there.
///
/// **A family album** belongs to a shared library. Every member sees it, and it
/// holds only that library's photos: one added from somewhere else is shared
/// into the library first, as `share` does it, family notice and all, with the
/// original left where it was. Contributors add to it. Its creator or the
/// library's owner renames or deletes it, and a photo in it is taken out by
/// whoever added it, the album's creator or the library's owner. Viewers look.
/// Leaving the library leaves its albums behind, for the people still in it.
///
/// 404 rather than 403 wherever a refusal would confirm an album exists.
struct AlbumController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes
            .grouped(DeviceTokenAuthenticator())
            .grouped(AuthenticatedDevice.guardMiddleware())

        protected.get("albums", use: list)
        protected.post("albums", use: create)
        protected.get("albums", ":albumID", use: detail)
        protected.patch("albums", ":albumID", use: update)
        protected.delete("albums", ":albumID", use: delete)
        protected.get("albums", ":albumID", "items", use: items)
        protected.post("albums", ":albumID", "assets", use: addAssets)
        protected.delete("albums", ":albumID", "assets", ":spaceAssetID", use: removeAsset)
        protected.put("albums", ":albumID", "people", use: setPeople)
        protected.delete("albums", ":albumID", "people", "me", use: leave)
    }

    private struct IDRow: Decodable { let id: UUID }

    private struct AlbumRow: Decodable {
        let id: UUID
        let name: String
        let spaceID: UUID?
        let ownerUserID: UUID
        let itemCount: Int
        let coverAssetID: UUID?
        let createdAt: Date
        let updatedAt: Date
        /// The caller's role in a family album's library.
        let role: String?
        /// `shared` for a family album, `album` for one shared with people,
        /// nil for one that's yours alone.
        let spaceKind: String?

        var isPeopleAlbum: Bool { spaceKind == "album" }
    }

    /// An album the caller can see, and what they may do with it.
    private struct Access {
        let album: AlbumRow
        /// Rename, change the cover, delete.
        let manage: Bool
        let add: Bool
        /// Take out a photo somebody else added.
        let removeAny: Bool
    }

    private static func access(_ row: AlbumRow, caller: UUID) -> Access {
        // Yours alone: nobody else ever gets this far.
        guard row.spaceID != nil else {
            return Access(album: row, manage: true, add: true, removeAny: true)
        }
        let role = row.role.flatMap(SpaceRole.init(rawValue:))
        let contributes = role == .owner || role == .contributor
        let manages = contributes && (row.ownerUserID == caller || role == .owner)
        return Access(album: row, manage: manages, add: contributes, removeAny: manages)
    }

    /// Someone in an album shared with people.
    private struct Member: Decodable {
        let spaceID: UUID
        let id: UUID
        let displayName: String
        let role: String
    }

    /// Everyone in the given album spaces, by space.
    private static func roster(
        of spaceIDs: [UUID], on sql: any SQLDatabase
    ) async throws -> [UUID: [Member]] {
        guard !spaceIDs.isEmpty else { return [:] }
        let rows = try await sql.raw("""
            SELECT m.space_id AS "spaceID", u.id, u.display_name AS "displayName", m.role
            FROM space_members m
            JOIN users u ON u.id = m.user_id
            WHERE m.space_id = ANY(\(bind: spaceIDs))
            ORDER BY u.display_name
            """).all(decoding: Member.self)
        return Dictionary(grouping: rows, by: \.spaceID)
    }

    /// `roster` is the album's people when it's shared with people, nil
    /// otherwise.
    private func dto(_ access: Access, roster: [Member]?, caller: UUID) -> AlbumDTO {
        let row = access.album
        let people = roster.map { members in
            members.filter { $0.id != caller }
                .map { UserDTO(id: $0.id, displayName: $0.displayName) }
        }
        let owner = roster?.first { $0.role == SpaceRole.owner.rawValue }
            .map { UserDTO(id: $0.id, displayName: $0.displayName) }
        return AlbumDTO(
            id: row.id, name: row.name,
            itemCount: row.itemCount, coverAssetID: row.coverAssetID,
            createdAt: row.createdAt, updatedAt: row.updatedAt,
            spaceID: row.spaceID, canManage: access.manage, canAdd: access.add,
            people: people, owner: owner
        )
    }

    /// One album as the caller sees it, with its people when it has them.
    private func respond(
        _ access: Access, caller: UUID, on sql: any SQLDatabase
    ) async throws -> AlbumDTO {
        guard access.album.isPeopleAlbum, let spaceID = access.album.spaceID else {
            return dto(access, roster: nil, caller: caller)
        }
        let roster = try await Self.roster(of: [spaceID], on: sql)
        return dto(access, roster: roster[spaceID] ?? [], caller: caller)
    }

    // MARK: - Reading

    /// The caller's own albums, and with `?shared=true` the family albums of
    /// every shared library they belong to, and those libraries themselves.
    /// With `?people=true` as well, the albums shared with them by people.
    ///
    /// Family albums only when asked for: an app from before them would file
    /// them under the person's own albums, as though they were private. And
    /// albums shared with people only when asked for too: an app from before
    /// those would look for their library, find none, and show an album whose
    /// photos it couldn't open.
    private func list(_ req: Request) async throws -> AlbumListResponse {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let family = req.query[Bool.self, at: "shared"] ?? false
        let people = family && (req.query[Bool.self, at: "people"] ?? false)
        let rows = try await req.sql.raw("""
            \(Self.albumSelect(caller: device.userID))
            WHERE (a.space_id IS NULL AND a.owner_user_id = \(bind: device.userID))
               OR (\(bind: family) AND a.space_id IS NOT NULL AND m.user_id IS NOT NULL
                   AND (\(bind: people) OR sp.kind = 'shared'))
            ORDER BY a.updated_at DESC
            """).all(decoding: AlbumRow.self)
        let rosters = try await Self.roster(
            of: rows.filter(\.isPeopleAlbum).compactMap(\.spaceID), on: req.sql
        )
        return AlbumListResponse(
            albums: rows.map { row in
                dto(
                    Self.access(row, caller: device.userID),
                    roster: row.isPeopleAlbum ? rosters[row.spaceID ?? UUID()] ?? [] : nil,
                    caller: device.userID
                )
            },
            includesFamilyAlbums: family ? true : nil,
            libraries: family ? try await libraries(of: device.userID, on: req.sql) : nil,
            includesPeopleAlbums: people ? true : nil
        )
    }

    /// The shared libraries a person is in, as cards for the Albums page:
    /// their size, and the photo added most recently for a cover, one with a
    /// thumbnail ready and a photo over a video where there's a choice. Here,
    /// with the albums, rather than on `/me`, so a cover is as fresh as the
    /// page it's drawn on.
    private func libraries(
        of userID: UUID, on sql: any SQLDatabase
    ) async throws -> [SharedLibrarySummary] {
        try await sql.raw("""
            SELECT s.id, s.name,
                   (SELECT count(*) FROM space_members WHERE space_id = s.id)::int AS "memberCount",
                   (SELECT count(*) FROM space_assets sa JOIN assets a ON a.id = sa.asset_id
                    WHERE sa.space_id = s.id AND sa.deleted_at IS NULL
                      AND \(unsafeRaw: TimelineController.visible)
                      AND \(Hidden.excluded(for: userID)))::int AS "itemCount",
                   (SELECT sa.asset_id FROM space_assets sa JOIN assets a ON a.id = sa.asset_id
                    WHERE sa.space_id = s.id AND sa.deleted_at IS NULL
                      AND \(unsafeRaw: TimelineController.visible)
                      AND \(Hidden.excluded(for: userID))
                    ORDER BY (a.derived_at IS NOT NULL) DESC, (a.media_type = 'photo') DESC,
                             sa.uploaded_at DESC
                    LIMIT 1) AS "coverAssetID"
            FROM spaces s
            JOIN space_members m ON m.space_id = s.id AND m.user_id = \(bind: userID)
            WHERE s.kind = 'shared'
            ORDER BY s.name
            """).all(decoding: SharedLibrarySummary.self)
    }

    private func detail(_ req: Request) async throws -> AlbumDTO {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let albumID = try req.parameters.require("albumID", as: UUID.self)
        return try await respond(
            try await requireReadable(albumID, device: device, on: req.sql),
            caller: device.userID, on: req.sql
        )
    }

    /// The album's photos, in album order — the one thing that differs from the
    /// timeline, which is always chronological.
    private func items(_ req: Request) async throws -> TimelineBucketPage {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let albumID = try req.parameters.require("albumID", as: UUID.self)
        _ = try await requireReadable(albumID, device: device, on: req.sql)

        // A family album's photos come from its own library and nowhere else,
        // checked again here as well as when they were added.
        let rows = try await req.sql.raw("""
            SELECT \(unsafeRaw: TimelineController.itemColumns),
                   EXISTS (
                       SELECT 1 FROM space_asset_favorites f
                       WHERE f.space_asset_id = sa.id AND f.user_id = \(bind: device.userID)
                   ) AS "isFavorite"
            FROM album_assets aa
            JOIN albums al ON al.id = aa.album_id
            JOIN space_assets sa ON sa.id = aa.space_asset_id
            JOIN assets a ON a.id = sa.asset_id
            JOIN space_members m ON m.space_id = sa.space_id
                                AND m.user_id = \(bind: device.userID)
            WHERE aa.album_id = \(bind: albumID) AND sa.deleted_at IS NULL
              AND (al.space_id IS NULL OR sa.space_id = al.space_id)
              AND \(Hidden.excluded(for: device.userID))
            ORDER BY aa.position, aa.added_at
            """).all(decoding: TimelineController.ItemRow.self)

        // Reuses the timeline's page shape so the client renders albums with
        // the same grid, cells and thumbnail cache. `key` is the album id.
        return TimelineBucketPage(
            key: albumID.uuidString, zoom: .day, items: rows.map { $0.toItem() }
        )
    }

    // MARK: - Writing

    private func create(_ req: Request) async throws -> AlbumDTO {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let input = try req.content.decode(CreateAlbumRequest.self)

        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else {
            throw Abort(.badRequest, reason: "An album needs a name.")
        }
        let people = try await Self.household(
            input.memberIDs ?? [], excluding: device.userID, on: req.sql
        )
        if !people.isEmpty {
            guard input.spaceID == nil else {
                throw Abort(
                    .badRequest,
                    reason: "An album is shared with a library or with people, not both."
                )
            }
            let albumID = try await req.withPinnedConnection { sql -> UUID in
                try await sql.raw("BEGIN").run()
                do {
                    let space = try await Self.makeAlbumSpace(
                        name: name, owner: device.userID, people: people, on: sql
                    )
                    guard let created = try await sql.raw("""
                        INSERT INTO albums (owner_user_id, name, created_by, space_id)
                        VALUES (\(bind: device.userID), \(bind: name), \(bind: device.userID),
                                \(bind: space))
                        RETURNING id
                        """).first(decoding: IDRow.self) else {
                        throw Abort(.internalServerError, reason: "Could not create the album.")
                    }
                    try await sql.raw("COMMIT").run()
                    return created.id
                } catch {
                    try? await sql.raw("ROLLBACK").run()
                    throw error
                }
            }
            let album = try await requireReadable(albumID, device: device, on: req.sql)
            if !input.spaceAssetIDs.isEmpty {
                try await attach(input.spaceAssetIDs, to: album, device: device, req: req)
            }
            return try await respond(
                try await requireReadable(albumID, device: device, on: req.sql),
                caller: device.userID, on: req.sql
            )
        }
        if let spaceID = input.spaceID {
            // A family album: in a shared library the person can add to. A
            // personal library has nobody else to share an album with.
            try await SpaceAccess.requireContributor(
                spaceID: spaceID, userID: device.userID, on: req.sql
            )
            guard try await req.sql.raw("""
                SELECT id FROM spaces WHERE id = \(bind: spaceID) AND kind = 'shared'
                """).first(decoding: IDRow.self) != nil else {
                throw Abort(.badRequest, reason: "Only a shared library has shared albums.")
            }
        }
        guard let created = try await req.sql.raw("""
            INSERT INTO albums (owner_user_id, name, created_by, space_id)
            VALUES (\(bind: device.userID), \(bind: name), \(bind: device.userID),
                    \(bind: input.spaceID))
            RETURNING id
            """).first(decoding: IDRow.self) else {
            throw Abort(.internalServerError, reason: "Could not create the album.")
        }

        let album = try await requireReadable(created.id, device: device, on: req.sql)
        if !input.spaceAssetIDs.isEmpty {
            try await attach(input.spaceAssetIDs, to: album, device: device, req: req)
        }
        return try await respond(
            try await requireReadable(created.id, device: device, on: req.sql),
            caller: device.userID, on: req.sql
        )
    }

    private func update(_ req: Request) async throws -> AlbumDTO {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let albumID = try req.parameters.require("albumID", as: UUID.self)
        let input = try req.content.decode(UpdateAlbumRequest.self)

        let album = try await requireReadable(albumID, device: device, on: req.sql)
        try Self.requireManage(album)

        if let raw = input.name {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 120 else {
                throw Abort(.badRequest, reason: "An album needs a name.")
            }
            try await req.sql.raw("""
                UPDATE albums SET name = \(bind: name), updated_at = now()
                WHERE id = \(bind: albumID)
                """).run()
            // Its space goes by the album's name: that's the title on the
            // notification its people get when someone adds to it.
            if album.album.isPeopleAlbum, let spaceID = album.album.spaceID {
                try await req.sql.raw("""
                    UPDATE spaces SET name = \(bind: name) WHERE id = \(bind: spaceID)
                    """).run()
            }
        }

        if let cover = input.coverAssetID {
            // The cover has to be something the album actually contains,
            // otherwise it becomes a way to display an arbitrary asset.
            guard try await req.sql.raw("""
                SELECT sa.id FROM album_assets aa
                JOIN space_assets sa ON sa.id = aa.space_asset_id
                WHERE aa.album_id = \(bind: albumID) AND sa.asset_id = \(bind: cover)
                """).first(decoding: IDRow.self) != nil else {
                throw Abort(.badRequest, reason: "That photo isn't in this album.")
            }
            try await req.sql.raw("""
                UPDATE albums SET cover_asset_id = \(bind: cover), updated_at = now()
                WHERE id = \(bind: albumID)
                """).run()
        }
        return try await respond(
            try await requireReadable(albumID, device: device, on: req.sql),
            caller: device.userID, on: req.sql
        )
    }

    private func delete(_ req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let albumID = try req.parameters.require("albumID", as: UUID.self)
        let album = try await requireReadable(albumID, device: device, on: req.sql)
        try Self.requireManage(album)
        // Only the album row goes; album_assets cascades and the photos
        // themselves are untouched. Deleting a collection must never delete
        // the things collected.
        //
        // An album shared with people takes its own space's copies with it:
        // they were only ever there for the album, and the originals stay in
        // the libraries they came from. Removed the way any photo is, so the
        // bytes go only when nothing else holds them, and nobody is left in
        // the space to see what's still on its clock.
        if album.album.isPeopleAlbum, let spaceID = album.album.spaceID {
            try await req.withPinnedConnection { sql in
                try await sql.raw("BEGIN").run()
                do {
                    try await sql.raw("""
                        UPDATE space_assets
                        SET deleted_at = now(), deleted_by = \(bind: device.userID)
                        WHERE space_id = \(bind: spaceID) AND deleted_at IS NULL
                        """).run()
                    try await sql.raw("DELETE FROM albums WHERE id = \(bind: albumID)").run()
                    try await sql.raw("""
                        DELETE FROM space_members WHERE space_id = \(bind: spaceID)
                        """).run()
                    try await sql.raw("COMMIT").run()
                } catch {
                    try? await sql.raw("ROLLBACK").run()
                    throw error
                }
            }
            return .noContent
        }
        try await req.sql.raw("DELETE FROM albums WHERE id = \(bind: albumID)").run()
        return .noContent
    }

    private func addAssets(_ req: Request) async throws -> AlbumDTO {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let albumID = try req.parameters.require("albumID", as: UUID.self)
        let input = try req.content.decode(AlbumAssetsRequest.self)

        let album = try await requireReadable(albumID, device: device, on: req.sql)
        try Self.requireAdd(album)
        try await attach(input.spaceAssetIDs, to: album, device: device, req: req)
        return try await respond(
            try await requireReadable(albumID, device: device, on: req.sql),
            caller: device.userID, on: req.sql
        )
    }

    private func removeAsset(_ req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let albumID = try req.parameters.require("albumID", as: UUID.self)
        let placementID = try req.parameters.require("spaceAssetID", as: UUID.self)

        let album = try await requireReadable(albumID, device: device, on: req.sql)
        try Self.requireAdd(album)

        struct AddedRow: Decodable { let addedBy: UUID }
        guard let added = try await req.sql.raw("""
            SELECT added_by AS "addedBy" FROM album_assets
            WHERE album_id = \(bind: albumID) AND space_asset_id = \(bind: placementID)
            """).first(decoding: AddedRow.self) else {
            // Not in the album, so already out of it.
            return .noContent
        }
        guard album.removeAny || added.addedBy == device.userID else {
            throw Abort(
                .forbidden,
                reason: "Only the person who added it, the album's creator or the library's owner can take it out."
            )
        }
        try await req.sql.raw("""
            DELETE FROM album_assets
            WHERE album_id = \(bind: albumID) AND space_asset_id = \(bind: placementID)
            """).run()
        // In an album shared with people the photo was the album's own copy,
        // there for nothing else, so it goes the way a removed photo does.
        if album.album.isPeopleAlbum, let spaceID = album.album.spaceID {
            try await req.sql.raw("""
                UPDATE space_assets
                SET deleted_at = now(), deleted_by = \(bind: device.userID)
                WHERE id = \(bind: placementID) AND space_id = \(bind: spaceID)
                  AND deleted_at IS NULL
                """).run()
        }
        try await refreshCover(albumID, on: req.sql)
        return .noContent
    }

    // MARK: - People

    /// Who an album is shared with. Its owner decides.
    ///
    /// Three moves, by where the album is and who's asked for:
    ///
    /// - **Yours alone, with people:** shared. It gets a space of its own with
    ///   them in it, and its photos are shared into that space, which tells
    ///   them the way adding to a shared album does.
    /// - **Shared, with other people:** they're added and dropped. Whoever is
    ///   dropped loses the album; what they added stays in it.
    /// - **Shared, with nobody:** yours alone again. Its photos stay in it, and
    ///   nobody else sees them.
    ///
    /// A family album is shared with its whole library, which a list of people
    /// can't change.
    private func setPeople(_ req: Request) async throws -> AlbumDTO {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let albumID = try req.parameters.require("albumID", as: UUID.self)
        let input = try req.content.decode(SetAlbumPeopleRequest.self)

        let album = try await requireReadable(albumID, device: device, on: req.sql)
        try Self.requireManage(album)
        guard album.album.spaceKind != SpaceKind.shared.rawValue else {
            throw Abort(.badRequest, reason: "Everyone in its library sees this album.")
        }
        let people = try await Self.household(
            input.memberIDs, excluding: device.userID, on: req.sql
        )

        if album.album.isPeopleAlbum, let spaceID = album.album.spaceID {
            try await req.withPinnedConnection { sql in
                try await sql.raw("BEGIN").run()
                do {
                    try await sql.raw("""
                        DELETE FROM space_members
                        WHERE space_id = \(bind: spaceID) AND role <> 'owner'
                          AND NOT (user_id = ANY(\(bind: people)))
                        """).run()
                    for person in people {
                        try await sql.raw("""
                            INSERT INTO space_members (space_id, user_id, role)
                            VALUES (\(bind: spaceID), \(bind: person), 'contributor')
                            ON CONFLICT (space_id, user_id) DO NOTHING
                            """).run()
                    }
                    if people.isEmpty {
                        // Its owner's alone again — whoever manages it now,
                        // which after an account deletion isn't who made it.
                        try await sql.raw("""
                            UPDATE albums
                            SET space_id = NULL, owner_user_id = \(bind: device.userID),
                                updated_at = now()
                            WHERE id = \(bind: albumID)
                            """).run()
                    }
                    try await sql.raw("COMMIT").run()
                } catch {
                    try? await sql.raw("ROLLBACK").run()
                    throw error
                }
            }
        } else if !people.isEmpty {
            try await share(album, with: people, device: device, req: req)
        }
        return try await respond(
            try await requireReadable(albumID, device: device, on: req.sql),
            caller: device.userID, on: req.sql
        )
    }

    /// Leaving an album somebody shared with you. The photos you added stay in
    /// it for the others, as leaving a library leaves yours behind. Its owner
    /// can't leave: they share it with nobody, or delete it.
    private func leave(_ req: Request) async throws -> HTTPStatus {
        let device = try req.auth.require(AuthenticatedDevice.self)
        let albumID = try req.parameters.require("albumID", as: UUID.self)
        let album = try await requireReadable(albumID, device: device, on: req.sql)
        guard album.album.isPeopleAlbum, let spaceID = album.album.spaceID else {
            throw Abort(.badRequest, reason: "Only an album shared with you can be left.")
        }
        guard album.album.role != SpaceRole.owner.rawValue else {
            throw Abort(.badRequest, reason: "You made this album. Share it with nobody, or delete it.")
        }
        try await req.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                try await sql.raw("""
                    DELETE FROM space_members
                    WHERE space_id = \(bind: spaceID) AND user_id = \(bind: device.userID)
                    """).run()
                // Nobody left in it but its owner: theirs alone again.
                try await sql.raw("""
                    UPDATE albums
                    SET space_id = NULL, updated_at = now(),
                        owner_user_id = COALESCE(
                            (SELECT user_id FROM space_members
                             WHERE space_id = \(bind: spaceID) AND role = 'owner' LIMIT 1),
                            owner_user_id)
                    WHERE id = \(bind: albumID)
                      AND NOT EXISTS (
                          SELECT 1 FROM space_members
                          WHERE space_id = \(bind: spaceID) AND role <> 'owner'
                      )
                    """).run()
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
        return .noContent
    }

    /// Shares an album that was yours alone: a space for it with its people in
    /// it, and every photo in it shared into that space in album order.
    ///
    /// A photo from a library you can only view stays out, as `attach` keeps
    /// it out: sharing it on isn't yours to do. The copies an earlier sharing
    /// left in another album space go, since nothing shows them anymore.
    private func share(
        _ album: Access, with people: [UUID], device: AuthenticatedDevice, req: Request
    ) async throws {
        let albumID = album.album.id

        struct ItemRow: Decodable {
            let placementID: UUID
            let spaceID: UUID
            let spaceKind: String
            let assetID: UUID
            let role: String
            let position: Double
            let addedBy: UUID
            let addedAt: Date
        }
        let items = try await req.sql.raw("""
            SELECT sa.id AS "placementID", sa.space_id AS "spaceID", s.kind AS "spaceKind",
                   sa.asset_id AS "assetID", m.role, aa.position,
                   aa.added_by AS "addedBy", aa.added_at AS "addedAt"
            FROM album_assets aa
            JOIN space_assets sa ON sa.id = aa.space_asset_id
            JOIN spaces s ON s.id = sa.space_id
            JOIN space_members m ON m.space_id = sa.space_id
                                AND m.user_id = \(bind: device.userID)
            WHERE aa.album_id = \(bind: albumID) AND sa.deleted_at IS NULL
            ORDER BY aa.position, aa.added_at
            """).all(decoding: ItemRow.self)

        let spaceID = try await req.withPinnedConnection { sql -> UUID in
            try await sql.raw("BEGIN").run()
            do {
                let space = try await Self.makeAlbumSpace(
                    name: album.album.name, owner: device.userID, people: people, on: sql
                )
                try await sql.raw("COMMIT").run()
                return space
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }

        var copies: [(placementID: UUID, item: ItemRow)] = []
        for item in items where SpaceRole(rawValue: item.role) != .viewer {
            if let shared = try await MediaEditController.shareIn(
                assetID: item.assetID, from: item.spaceID, to: spaceID,
                device: device, req: req
            ) {
                copies.append((shared.placementID, item))
            }
        }
        let leftovers = items
            .filter { $0.spaceKind == "album" && $0.spaceID != spaceID }
            .map(\.placementID)
        let placed = copies

        try await req.withPinnedConnection { sql in
            try await sql.raw("BEGIN").run()
            do {
                try await sql.raw("""
                    DELETE FROM album_assets WHERE album_id = \(bind: albumID)
                    """).run()
                for copy in placed {
                    try await sql.raw("""
                        INSERT INTO album_assets (album_id, space_asset_id, added_by, position, added_at)
                        VALUES (\(bind: albumID), \(bind: copy.placementID), \(bind: copy.item.addedBy),
                                \(bind: copy.item.position), \(bind: copy.item.addedAt))
                        ON CONFLICT (album_id, space_asset_id) DO NOTHING
                        """).run()
                }
                try await sql.raw("""
                    UPDATE albums SET space_id = \(bind: spaceID), updated_at = now()
                    WHERE id = \(bind: albumID)
                    """).run()
                if !leftovers.isEmpty {
                    try await sql.raw("""
                        UPDATE space_assets
                        SET deleted_at = now(), deleted_by = \(bind: device.userID)
                        WHERE id = ANY(\(bind: leftovers)) AND deleted_at IS NULL
                        """).run()
                }
                try await sql.raw("COMMIT").run()
            } catch {
                try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
        try await refreshCover(albumID, on: req.sql)
    }

    /// The people an album can be shared with: accounts on this NAS that
    /// haven't been deleted, other than whoever's asking. Any other id is
    /// dropped rather than refused, the way a photo you can't see is.
    private static func household(
        _ ids: [UUID], excluding caller: UUID, on sql: any SQLDatabase
    ) async throws -> [UUID] {
        let unique = Array(Set(ids)).filter { $0 != caller }
        guard !unique.isEmpty else { return [] }
        guard unique.count <= 50 else {
            throw Abort(.badRequest, reason: "Share an album with at most 50 people.")
        }
        return try await sql.raw("""
            SELECT id FROM users WHERE id = ANY(\(bind: unique)) AND deleted_at IS NULL
            """).all(decoding: IDRow.self).map(\.id)
    }

    /// An album's own space: its owner and its people, and nobody else. Run
    /// inside the caller's transaction.
    private static func makeAlbumSpace(
        name: String, owner: UUID, people: [UUID], on sql: any SQLDatabase
    ) async throws -> UUID {
        guard let space = try await sql.raw("""
            INSERT INTO spaces (kind, name, created_by)
            VALUES ('album', \(bind: name), \(bind: owner))
            RETURNING id
            """).first(decoding: IDRow.self) else {
            throw Abort(.internalServerError, reason: "Could not share the album.")
        }
        try await sql.raw("""
            INSERT INTO space_members (space_id, user_id, role)
            VALUES (\(bind: space.id), \(bind: owner), 'owner')
            """).run()
        for person in people {
            try await sql.raw("""
                INSERT INTO space_members (space_id, user_id, role)
                VALUES (\(bind: space.id), \(bind: person), 'contributor')
                ON CONFLICT (space_id, user_id) DO NOTHING
                """).run()
        }
        return space.id
    }

    // MARK: - Helpers

    /// Adds placements, silently skipping any the caller can't see.
    ///
    /// The membership join is the whole security story: you may only collect
    /// photos already visible to you, and an unknown or forbidden id adds
    /// nothing rather than erroring — which also means this can't be used to
    /// probe whether an id exists.
    ///
    /// A family album holds only its library's photos. One from anywhere else
    /// is shared in first, from a library the caller can add to, the way
    /// `share` does it, and the album gets the library's copy.
    private func attach(
        _ placementIDs: [UUID], to album: Access,
        device: AuthenticatedDevice, req: Request
    ) async throws {
        guard !placementIDs.isEmpty else { return }
        guard placementIDs.count <= 500 else {
            throw Abort(.badRequest, reason: "Add at most 500 photos at a time.")
        }
        let albumID = album.album.id
        let library = album.album.spaceID

        var placements = placementIDs
        if let library {
            struct SeenRow: Decodable {
                let spaceID: UUID
                let assetID: UUID
                let role: String
            }
            placements = []
            for placementID in placementIDs {
                guard let seen = try await req.sql.raw("""
                    SELECT sa.space_id AS "spaceID", sa.asset_id AS "assetID", m.role
                    FROM space_assets sa
                    JOIN space_members m ON m.space_id = sa.space_id
                                        AND m.user_id = \(bind: device.userID)
                    WHERE sa.id = \(bind: placementID) AND sa.deleted_at IS NULL
                    """).first(decoding: SeenRow.self) else { continue }
                if seen.spaceID == library {
                    placements.append(placementID)
                    continue
                }
                // Sharing out of a library needs the same say there that
                // `share` asks for.
                guard SpaceRole(rawValue: seen.role) != .viewer else { continue }
                if let shared = try await MediaEditController.shareIn(
                    assetID: seen.assetID, from: seen.spaceID, to: library,
                    device: device, req: req
                ) {
                    placements.append(shared.placementID)
                }
            }
        }

        for placementID in placements {
            try await req.sql.raw("""
                INSERT INTO album_assets (album_id, space_asset_id, added_by, position)
                SELECT \(bind: albumID), sa.id, \(bind: device.userID),
                       COALESCE(
                           (SELECT MAX(position) + 1 FROM album_assets WHERE album_id = \(bind: albumID)),
                           0
                       )
                FROM space_assets sa
                JOIN space_members m ON m.space_id = sa.space_id
                WHERE sa.id = \(bind: placementID)
                  AND sa.deleted_at IS NULL
                  AND m.user_id = \(bind: device.userID)
                  AND sa.space_id = COALESCE(\(bind: library), sa.space_id)
                ON CONFLICT (album_id, space_asset_id) DO NOTHING
                """).run()
        }
        try await refreshCover(albumID, on: req.sql)
        try await req.sql.raw("""
            UPDATE albums SET updated_at = now() WHERE id = \(bind: albumID)
            """).run()
    }

    /// Keeps the cover pointing at something that is still in the album.
    private func refreshCover(_ albumID: UUID, on sql: any SQLDatabase) async throws {
        try await sql.raw("""
            UPDATE albums SET cover_asset_id = (
                SELECT sa.asset_id
                FROM album_assets aa
                JOIN space_assets sa ON sa.id = aa.space_asset_id
                WHERE aa.album_id = \(bind: albumID) AND sa.deleted_at IS NULL
                ORDER BY aa.position, aa.added_at
                LIMIT 1
            )
            WHERE id = \(bind: albumID)
              AND (
                  cover_asset_id IS NULL
                  OR NOT EXISTS (
                      SELECT 1 FROM album_assets aa2
                      JOIN space_assets sa2 ON sa2.id = aa2.space_asset_id
                      WHERE aa2.album_id = \(bind: albumID)
                        AND sa2.asset_id = albums.cover_asset_id
                  )
              )
            """).run()
    }

    /// An album you own, or a family album in a library you belong to; any
    /// other id is a 404, so a refusal never confirms an album exists.
    private func requireReadable(
        _ albumID: UUID, device: AuthenticatedDevice, on sql: any SQLDatabase
    ) async throws -> Access {
        guard let row = try await sql.raw("""
            \(Self.albumSelect(caller: device.userID))
            WHERE a.id = \(bind: albumID)
              AND ((a.space_id IS NULL AND a.owner_user_id = \(bind: device.userID))
                   OR (a.space_id IS NOT NULL AND m.user_id IS NOT NULL))
            """).first(decoding: AlbumRow.self) else {
            throw Abort(.notFound, reason: "No such album.")
        }
        return Self.access(row, caller: device.userID)
    }

    /// 403 from here on: the caller can see the album, so saying no reveals
    /// nothing they don't know.
    private static func requireManage(_ album: Access) throws {
        guard album.manage else {
            throw Abort(
                .forbidden,
                reason: "Only the album's creator or the library's owner can change it."
            )
        }
    }

    private static func requireAdd(_ album: Access) throws {
        guard album.add else {
            throw Abort(.forbidden, reason: "You have view-only access to this library.")
        }
    }

    /// An album, the caller's role in its library, and its count. The count
    /// re-checks membership: a personal album's against its owner's libraries,
    /// so its badge never promises photos they can no longer reach, and a
    /// family album's against its own library.
    private static func albumSelect(caller: UUID) -> SQLQueryString {
        """
        SELECT a.id, a.name, a.space_id AS "spaceID", a.owner_user_id AS "ownerUserID",
               -- No cover rather than one this person has reported, or one
               -- added by someone they blocked. See `Hidden`.
               CASE WHEN EXISTS (
                   SELECT 1 FROM album_assets ca
                   JOIN space_assets sa ON sa.id = ca.space_asset_id
                   WHERE ca.album_id = a.id AND sa.asset_id = a.cover_asset_id
                     AND NOT (\(Hidden.excluded(for: caller)))
               ) THEN NULL ELSE a.cover_asset_id END AS "coverAssetID",
               a.created_at AS "createdAt", a.updated_at AS "updatedAt",
               m.role, sp.kind AS "spaceKind",
               (SELECT count(*) FROM album_assets aa
                JOIN space_assets sa ON sa.id = aa.space_asset_id
                WHERE aa.album_id = a.id AND sa.deleted_at IS NULL
                  AND \(Hidden.excluded(for: caller))
                  AND CASE WHEN a.space_id IS NULL
                           THEN EXISTS (SELECT 1 FROM space_members m2
                                        WHERE m2.space_id = sa.space_id
                                          AND m2.user_id = a.owner_user_id)
                           ELSE sa.space_id = a.space_id END)::int AS "itemCount"
        FROM albums a
        LEFT JOIN space_members m ON m.space_id = a.space_id AND m.user_id = \(bind: caller)
        LEFT JOIN spaces sp ON sp.id = a.space_id
        """
    }
}
