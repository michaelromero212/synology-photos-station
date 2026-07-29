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
