import FrameStationAPI
import Foundation

extension CharacterSet {
    /// `.urlQueryAllowed` permits `&`, `=` and `+`, which are exactly the
    /// characters that break a *value* inside a query string. A place called
    /// "Baden-Baden & Umgebung" would otherwise arrive as two parameters.
    static let urlQueryValue: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return allowed
    }()
}

extension FrameStationClient {

    // MARK: - Timeline

    public func timeline(spaceID: UUID, zoom: TimelineZoom = .day) async throws -> TimelineManifest {
        try await get("v1/spaces/\(spaceID)/timeline?zoom=\(zoom.rawValue)")
    }

    public func bucket(
        spaceID: UUID, key: String, zoom: TimelineZoom = .day
    ) async throws -> TimelineBucketPage {
        try await get("v1/spaces/\(spaceID)/timeline/\(key)?zoom=\(zoom.rawValue)")
    }

    public func changes(
        spaceID: UUID, since: Int64, limit: Int = 500
    ) async throws -> SpaceChanges {
        try await get("v1/spaces/\(spaceID)/changes?since=\(since)&limit=\(limit)")
    }

    public func detail(spaceID: UUID, assetID: UUID) async throws -> AssetDetail {
        try await get("v1/spaces/\(spaceID)/assets/\(assetID)/detail")
    }

    // MARK: - Search

    /// The places this space has photos from.
    ///
    /// Bounded by `limit`, because the full vocabulary grows one entry per town
    /// anyone ever passed through. `query` filters by name so a caller holding
    /// only the top few can still search all of them; `alphabetical` is for the
    /// full list, where the job is finding a name rather than being shown the
    /// ones you shoot most.
    public func places(
        spaceID: UUID, matching query: String = "",
        limit: Int = 12, alphabetical: Bool = false
    ) async throws -> PlacesResponse {
        var path = "v1/spaces/\(spaceID)/places?limit=\(limit)"
        if alphabetical { path += "&sort=name" }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let encoded = trimmed.addingPercentEncoding(
                withAllowedCharacters: .urlQueryValue
            ) ?? ""
            path += "&q=\(encoded)"
        }
        return try await get(path)
    }

    /// Photos taken somewhere whose name contains `place`.
    public func search(
        spaceID: UUID, place: String, offset: Int = 0, limit: Int = 120
    ) async throws -> SearchResults {
        let encoded = place.addingPercentEncoding(
            withAllowedCharacters: .urlQueryValue
        ) ?? ""
        return try await get(
            "v1/spaces/\(spaceID)/search?place=\(encoded)&offset=\(offset)&limit=\(limit)"
        )
    }

    // MARK: - Collections

    /// The whole Albums page in one request.
    ///
    /// The device's own date goes up with it. "On this day" means the day the
    /// person is having, and a NAS in another timezone — or simply a request
    /// made at one in the morning — would otherwise answer for the wrong one.
    public func collections(spaceID: UUID, on date: Date = Date()) async throws -> CollectionsResponse {
        try await get("v1/spaces/\(spaceID)/collections?date=\(Self.dayStamp(date))")
    }

    /// The photos inside one collection, opened with the key its card carried.
    public func collectionItems(
        spaceID: UUID, kind: CollectionKind, key: String, on date: Date = Date()
    ) async throws -> SearchResults {
        let encodedKey = key.addingPercentEncoding(
            withAllowedCharacters: .urlQueryValue
        ) ?? ""
        return try await get(
            "v1/spaces/\(spaceID)/collections/items"
            + "?kind=\(kind.rawValue)&key=\(encodedKey)&date=\(Self.dayStamp(date))"
        )
    }

    /// The calendar day as the *device* reckons it, which is the only reckoning
    /// that matters for a collection built around "today".
    static func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Names a day, or clears the name.
    ///
    /// `everyYear` is the birthday-versus-party distinction: a birthday is this
    /// date in every year, an engagement party is this date once. Passing a nil
    /// or empty name forgets whichever one applies.
    public func nameOccasion(
        spaceID: UUID, day: String, name: String?, everyYear: Bool
    ) async throws {
        try await sendBodyNoContent(
            .put, "v1/spaces/\(spaceID)/collections/name",
            body: NameOccasionRequest(day: day, name: name, everyYear: everyYear)
        )
    }

    /// What is still in the bin and still on disk.
    public func deletedItems(spaceID: UUID) async throws -> SearchResults {
        try await get("v1/spaces/\(spaceID)/collections/deleted")
    }

    /// Puts removed photographs back where they were.
    @discardableResult
    public func restore(spaceID: UUID, assetIDs: [UUID]) async throws -> MediaEditResponse {
        try await post(
            "v1/spaces/\(spaceID)/collections/deleted/restore",
            body: RestoreAssetsRequest(assetIDs: assetIDs)
        )
    }

    /// Deletes removed photographs immediately, ahead of the 29-day sweep. The
    /// bytes go; there is no putting these back. The caller confirms first.
    @discardableResult
    public func purge(spaceID: UUID, assetIDs: [UUID]) async throws -> MediaEditResponse {
        try await post(
            "v1/spaces/\(spaceID)/collections/deleted/purge",
            body: PurgeAssetsRequest(assetIDs: assetIDs)
        )
    }

    // MARK: - Media URLs

    /// Built rather than fetched so a grid cell can hand a URL straight to the
    /// image loader without a round trip.
    /// `version` is `assets.thumb_version` (0 when unknown). The server ignores
    /// it — it only makes the URL change when the server regenerates a
    /// thumbnail, so the device stops serving the old bytes from its one-year
    /// immutable cache and fetches the new ones. Adding it at all busts the
    /// pre-versioning cache, since those entries had no `v`.
    public func thumbnailURL(assetID: UUID, size: Int = 256, version: Int = 0) -> URL? {
        URL(string: "v1/assets/\(assetID)/thumb?size=\(size)&v=\(version)", relativeTo: baseURL)
    }

    public func previewURL(assetID: UUID) -> URL? {
        URL(string: "v1/assets/\(assetID)/preview", relativeTo: baseURL)
    }

    /// The original bytes, for handing to the share sheet so a photo can go
    /// back into the iPhone's own library.
    public func originalData(assetID: UUID) async throws -> Data {
        guard let url = originalURL(assetID: assetID) else {
            throw FrameStationClientError.invalidURL("original")
        }
        var request = URLRequest(url: url)
        if let header = authorizationHeader() {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FrameStationClientError.http(
                status: (response as? HTTPURLResponse)?.statusCode ?? -1, reason: nil
            )
        }
        return data
    }

    public func originalURL(assetID: UUID) -> URL? {
        URL(string: "v1/assets/\(assetID)/original", relativeTo: baseURL)
    }

    /// Bearer header for media requests, which bypass `send` and go straight
    /// through `URLSession` so they can stream.
    public func authorizationHeader() -> String? {
        currentToken.map { "Bearer \($0)" }
    }
}

extension FrameStationClient {
    /// Per-user favourite. Idempotent in both directions.
    public func setFavorite(
        spaceID: UUID, assetID: UUID, _ favorite: Bool
    ) async throws {
        try await sendEmpty(
            favorite ? .put : .delete,
            "v1/spaces/\(spaceID)/assets/\(assetID)/favorite"
        )
    }
}

// MARK: - Rating and tags

extension FrameStationClient {
    /// Stars, 0–5, where 0 clears the rating.
    ///
    /// Not per-user, unlike `setFavorite`: rating a photo in a shared space
    /// rates it for everyone in that space.
    public func setRating(spaceID: UUID, assetID: UUID, _ rating: Int) async throws {
        try await sendBodyNoContent(
            .put, "v1/spaces/\(spaceID)/assets/\(assetID)/rating",
            body: SetRatingRequest(rating: rating)
        )
    }

    /// Adds and removes tags in one call, returning what the photo carries
    /// afterwards — so the viewer can redraw without refetching its detail.
    @discardableResult
    public func editTags(
        spaceID: UUID, assetID: UUID, add: [String] = [], remove: [String] = []
    ) async throws -> [String] {
        let response: TagListResponse = try await post(
            "v1/spaces/\(spaceID)/assets/\(assetID)/tags",
            body: EditTagsRequest(add: add, remove: remove)
        )
        return response.tags
    }

    /// Every tag in use in this library, for the editor to offer.
    public func spaceTags(spaceID: UUID) async throws -> [String] {
        let response: TagListResponse = try await get("v1/spaces/\(spaceID)/tags")
        return response.tags
    }
}

// MARK: - Correcting the record

extension FrameStationClient {
    /// Re-times photos, and moves their files to match.
    ///
    /// One call for the whole selection rather than one per photo: a date change
    /// moves the file on disk, and a partial batch spread over fifty requests is
    /// a much worse thing to recover from than one that either largely worked or
    /// largely didn't.
    ///
    /// Build `items` with `CaptureTimeEdit.plan` — the shift-versus-set-all
    /// arithmetic lives there so the sheet can show exactly what it will apply.
    @discardableResult
    public func setCaptureTimes(
        spaceID: UUID, items: [EditCaptureTimeRequest.Item]
    ) async throws -> MediaEditResponse {
        try await post(
            "v1/spaces/\(spaceID)/assets/capture-time",
            body: EditCaptureTimeRequest(items: items)
        )
    }

    /// Turns photos a quarter or half turn.
    ///
    /// Relative, not absolute: "rotate left" is what the button says, and after
    /// somebody else has already straightened a photo the client's idea of its
    /// current orientation is stale anyway.
    ///
    /// Returns as soon as the record is written. Thumbnails are regenerated in
    /// the background and arrive over the usual delta sync, so a bulk rotate
    /// doesn't hold the app open while a NAS re-renders two hundred images.
    @discardableResult
    public func rotate(
        spaceID: UUID, assetIDs: [UUID], _ rotation: MediaRotation
    ) async throws -> MediaEditResponse {
        try await post(
            "v1/spaces/\(spaceID)/assets/orientation",
            body: RotateMediaRequest(assetIDs: assetIDs, rotation: rotation)
        )
    }

    /// Sets or clears where a photo was taken.
    ///
    /// The place *name* comes back from the server rather than being sent to it:
    /// search matches on the name the server derived, so a client-supplied one
    /// would be a place you could read and not find. Pass nil for both to clear.
    @discardableResult
    public func setLocation(
        spaceID: UUID, assetID: UUID, latitude: Double?, longitude: Double?
    ) async throws -> SetLocationResponse {
        try await put(
            "v1/spaces/\(spaceID)/assets/\(assetID)/location",
            body: SetLocationRequest(latitude: latitude, longitude: longitude)
        )
    }

    /// Puts photos into a shared space, leaving the originals where they are.
    ///
    /// Returns the ids they carry **in the destination**, which are not the ids
    /// that were sent — the destination gets its own rows — so the app can walk
    /// them there rather than asking anyone to take its word for it. The source
    /// ids come back too, for offering to remove the originals afterwards.
    @discardableResult
    public func share(
        spaceID: UUID, assetIDs: [UUID], to destinationSpaceID: UUID
    ) async throws -> ShareAssetsResponse {
        try await post(
            "v1/spaces/\(spaceID)/assets/share",
            body: ShareAssetsRequest(
                assetIDs: assetIDs, destinationSpaceID: destinationSpaceID
            )
        )
    }

    /// Corrects who photos are attributed to, or clears the correction.
    ///
    /// Never rewrites who uploaded them — that stays recorded server-side as the
    /// fact it is. Passing nil for `creditedTo` drops the override and returns
    /// the credit to the uploader.
    @discardableResult
    public func setCredit(
        spaceID: UUID, assetIDs: [UUID], creditedTo: UUID?
    ) async throws -> MediaEditResponse {
        try await post(
            "v1/spaces/\(spaceID)/assets/credit",
            body: SetCreditRequest(assetIDs: assetIDs, creditedTo: creditedTo)
        )
    }
}

// MARK: - Spaces

extension FrameStationClient {
    /// Everyone with an account on this NAS, for picking members.
    public func household() async throws -> HouseholdResponse {
        try await get("v1/household")
    }

    public func createSpace(_ body: CreateSpaceRequest) async throws -> SpaceDTO {
        try await post("v1/spaces", body: body)
    }

    public func renameSpace(_ spaceID: UUID, to name: String) async throws -> SpaceDTO {
        try await patch("v1/spaces/\(spaceID)", body: RenameSpaceRequest(name: name))
    }

    public func members(spaceID: UUID) async throws -> SpaceMembersResponse {
        try await get("v1/spaces/\(spaceID)/members")
    }

    public func addMember(
        spaceID: UUID, userID: UUID, role: SpaceRole = .contributor
    ) async throws {
        try await sendBodyNoContent(
            .put, "v1/spaces/\(spaceID)/members/\(userID)", body: AddMemberRequest(role: role)
        )
    }

    public func removeMember(spaceID: UUID, userID: UUID) async throws {
        try await sendEmpty(.delete, "v1/spaces/\(spaceID)/members/\(userID)")
    }
}

// MARK: - DSM sign-in

extension FrameStationClient {
    /// Signs in with a Synology DSM account. The password goes to the server
    /// once and is never stored; the returned token is what the app keeps.
    public func signInWithDSM(_ body: DSMLoginRequest) async throws -> DSMLoginResponse {
        let response: DSMLoginResponse = try await post("v1/auth/dsm", body: body, authenticated: false)
        setToken(response.token)
        return response
    }
}
