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

    /// Every place this space has photos from, commonest first.
    public func places(spaceID: UUID) async throws -> PlacesResponse {
        try await get("v1/spaces/\(spaceID)/places")
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

    // MARK: - Media URLs

    /// Built rather than fetched so a grid cell can hand a URL straight to the
    /// image loader without a round trip.
    public func thumbnailURL(assetID: UUID, size: Int = 256) -> URL? {
        URL(string: "v1/assets/\(assetID)/thumb?size=\(size)", relativeTo: baseURL)
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

    /// Moves photos out of `spaceID` and into another space.
    ///
    /// A move, not a copy — they leave the source. Returns the ids that actually
    /// moved, which is what lets the app walk them in the destination afterwards
    /// rather than asking someone to take its word for it.
    @discardableResult
    public func move(
        spaceID: UUID, assetIDs: [UUID], to destinationSpaceID: UUID
    ) async throws -> MoveAssetsResponse {
        try await post(
            "v1/spaces/\(spaceID)/assets/move",
            body: MoveAssetsRequest(
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
