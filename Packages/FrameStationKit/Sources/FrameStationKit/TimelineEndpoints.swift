import FrameStationAPI
import Foundation

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

    // MARK: - Media URLs

    /// Built rather than fetched so a grid cell can hand a URL straight to the
    /// image loader without a round trip.
    public func thumbnailURL(assetID: UUID, size: Int = 256) -> URL? {
        URL(string: "v1/assets/\(assetID)/thumb?size=\(size)", relativeTo: baseURL)
    }

    public func previewURL(assetID: UUID) -> URL? {
        URL(string: "v1/assets/\(assetID)/preview", relativeTo: baseURL)
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
