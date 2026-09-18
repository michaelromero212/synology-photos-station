import FrameStationAPI
import Foundation

/// Typed client for the FrameStation server.
///
/// Every request and response type comes from `FrameStationAPI`, which the
/// server imports too — so a contract change breaks the build on both sides
/// rather than at runtime on someone's phone.
public actor FrameStationClient {
    public struct Configuration: Sendable {
        /// Base URL including scheme and port, e.g. `https://nas.example.com:8443`.
        public var baseURL: URL
        public var token: String?

        public init(baseURL: URL, token: String? = nil) {
            self.baseURL = baseURL
            self.token = token
        }
    }

    private var configuration: Configuration
    private let session: URLSession
    private var outcomeObserver: (@Sendable (TransferFailure?) -> Void)?

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    /// Watches whether requests are getting through, so something outside can
    /// tell the difference between a quiet app and an unreachable server.
    ///
    /// At this level rather than at each call site: the stores above
    /// deliberately swallow failures — a blip must not blank the grid — which
    /// is exactly what makes an outage invisible from up there. Nil reports a
    /// success.
    public func observeOutcomes(_ observer: (@Sendable (TransferFailure?) -> Void)?) {
        outcomeObserver = observer
    }

    public func setToken(_ token: String?) {
        configuration.token = token
    }

    public var baseURL: URL { configuration.baseURL }

    /// Media requests stream through URLSession directly rather than going via
    /// `send`, so they need the raw token to build their own Authorization.
    public var currentToken: String? { configuration.token }

    /// Generic authenticated GET, used by the timeline endpoints.
    func get<Response: Decodable>(_ path: String) async throws -> Response {
        try await send(.get, path)
    }

    func post<Body: Encodable, Response: Decodable>(
        _ path: String, body: Body, authenticated: Bool = true
    ) async throws -> Response {
        try await send(.post, path, body: body, authenticated: authenticated)
    }

    func patch<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        try await send(.patch, path, body: body)
    }

    /// PUT that expects a body back — for the writes whose result the caller
    /// needs, rather than the ones that only need to have happened.
    func put<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        try await send(.put, path, body: body)
    }

    /// Request with a JSON body and no response body.
    func sendBodyNoContent<Body: Encodable>(_ method: Method, _ path: String, body: Body) async throws {
        try await sendNoContent(method, path, body: body)
    }

    /// Authenticated request with no body either way (favorite toggles).
    func sendEmpty(_ method: Method, _ path: String) async throws {
        _ = try await run(makeRequest(method, path))
    }

    // MARK: - Endpoints

    public func health() async throws -> HealthResponse {
        try await send(.get, "health", authenticated: false)
    }

    public func redeemInvite(_ body: RedeemInviteRequest) async throws -> RedeemInviteResponse {
        let response: RedeemInviteResponse = try await send(
            .post, "v1/auth/redeem", body: body, authenticated: false
        )
        configuration.token = response.token
        return response
    }

    public func me() async throws -> MeResponse {
        try await send(.get, "v1/me")
    }

    public func registerPushToken(_ body: RegisterPushTokenRequest) async throws {
        try await sendNoContent(.put, "v1/devices/push-token", body: body)
    }

    /// Tells the NAS how much of this device's backup is still outstanding, so
    /// it can wake the device up to finish it. See the server's `BackupNudger`.
    public func reportBackupState(_ body: ReportBackupStateRequest) async throws {
        try await sendNoContent(.put, "v1/devices/backup-state", body: body)
    }

    /// The read endpoint takes no arguments, but the no-content helper is
    /// body-shaped; an empty object is a valid, forward-compatible payload.
    private struct ActivityReadBody: Encodable {}

    public func activityFeed(limit: Int = 50) async throws -> ActivityFeedResponse {
        try await send(.get, "v1/activity?limit=\(limit)")
    }

    /// Marks everything up to now as seen.
    public func markActivityRead() async throws {
        try await sendNoContent(.post, "v1/activity/read", body: ActivityReadBody())
    }

    /// A signed, short-lived URL a player can fetch directly.
    /// The signed URL to play. `quality` picks which representation — the
    /// server falls back to the original whenever the rendition it asks for
    /// hasn't been built yet, so this can always be asked for optimistically.
    public func playbackURL(
        assetID: UUID, quality: PlaybackQuality = .default
    ) async throws -> PlaybackURLResponse {
        try await send(
            .get, "v1/assets/\(assetID.uuidString)/playback?quality=\(quality.rawValue)"
        )
    }

    /// Removes a photo from a library. The file moves to `#recycle`; the
    /// record of the removal is what stops backup putting it back.
    public func removeAsset(spaceID: UUID, assetID: UUID) async throws {
        try await sendNoContent(
            .delete, "v1/spaces/\(spaceID.uuidString)/assets/\(assetID.uuidString)",
            body: EmptyAlbumBody()
        )
    }

    // MARK: - Albums

    public func albums() async throws -> AlbumListResponse {
        try await send(.get, "v1/albums")
    }

    public func createAlbum(_ body: CreateAlbumRequest) async throws -> AlbumDTO {
        try await send(.post, "v1/albums", body: body)
    }

    public func albumItems(_ albumID: UUID) async throws -> TimelineBucketPage {
        try await send(.get, "v1/albums/\(albumID.uuidString)/items")
    }

    public func updateAlbum(_ albumID: UUID, _ body: UpdateAlbumRequest) async throws -> AlbumDTO {
        try await send(.patch, "v1/albums/\(albumID.uuidString)", body: body)
    }

    public func deleteAlbum(_ albumID: UUID) async throws {
        try await sendNoContent(.delete, "v1/albums/\(albumID.uuidString)", body: EmptyAlbumBody())
    }

    public func addToAlbum(_ albumID: UUID, _ body: AlbumAssetsRequest) async throws -> AlbumDTO {
        try await send(.post, "v1/albums/\(albumID.uuidString)/assets", body: body)
    }

    public func removeFromAlbum(_ albumID: UUID, placementID: UUID) async throws {
        try await sendNoContent(
            .delete, "v1/albums/\(albumID.uuidString)/assets/\(placementID.uuidString)",
            body: EmptyAlbumBody()
        )
    }

    private struct EmptyAlbumBody: Encodable {}

    public func probeUpload(_ body: UploadProbeRequest) async throws -> UploadProbeResponse {
        try await send(.post, "v1/uploads/probe", body: body)
    }

    /// Uploads one chunk from a file on disk.
    ///
    /// Takes a file URL rather than `Data` because this is the shape a
    /// background `URLSession` requires — background upload tasks must be
    /// file-backed, and they cannot resume mid-file, which is the entire reason
    /// the protocol is chunked. See ARCHITECTURE.md §8.
    public func uploadChunk(
        uploadID: UUID,
        index: Int,
        fileURL: URL
    ) async throws -> ChunkAcceptedResponse {
        var request = try makeRequest(.put, "v1/uploads/\(uploadID)/chunk/\(index)")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let data = try await run(request, fromFile: fileURL)
        return try FrameStationCoding.decoder.decode(ChunkAcceptedResponse.self, from: data)
    }

    /// The request a background `URLSession` needs to send one chunk itself.
    ///
    /// Exposed because a background session builds and owns its own tasks — it
    /// can't borrow this client's `URLSession`, but it must borrow its auth and
    /// URL construction or the two would drift.
    public func chunkUploadRequest(uploadID: UUID, index: Int) throws -> URLRequest {
        var request = try makeRequest(.put, "v1/uploads/\(uploadID)/chunk/\(index)")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return request
    }

    public func commitUpload(
        uploadID: UUID,
        _ body: CommitUploadRequest
    ) async throws -> CommitUploadResponse {
        try await send(.post, "v1/uploads/\(uploadID)/commit", body: body)
    }

    /// Hands the server the thumbnail this device already rendered.
    ///
    /// Sent right after a commit, so the picture is servable to *every* device
    /// immediately rather than after the NAS works through its derivation
    /// queue. Best-effort by nature — see `UploadThumbnailRequest`.
    public func sendThumbnail(
        assetID: UUID,
        _ body: UploadThumbnailRequest
    ) async throws {
        try await sendNoContent(.post, "v1/assets/\(assetID)/thumb", body: body)
    }

    /// Links an already-stored asset into a space — the `.have` path, and how a
    /// photo moves from Personal to Family Shared without copying bytes.
    public func linkAsset(
        spaceID: UUID,
        assetID: UUID,
        _ body: LinkAssetRequest = LinkAssetRequest()
    ) async throws -> CommitUploadResponse {
        try await send(.post, "v1/spaces/\(spaceID)/assets/\(assetID)", body: body)
    }

    // MARK: - Transport

    enum Method: String {
        case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE"
    }

    private func makeRequest(
        _ method: Method,
        _ path: String,
        authenticated: Bool = true
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: configuration.baseURL) else {
            throw FrameStationClientError.invalidURL(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        if authenticated {
            guard let token = configuration.token else {
                throw FrameStationClientError.notAuthenticated
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<Response: Decodable>(
        _ method: Method,
        _ path: String,
        authenticated: Bool = true
    ) async throws -> Response {
        let data = try await run(makeRequest(method, path, authenticated: authenticated))
        return try FrameStationCoding.decoder.decode(Response.self, from: data)
    }

    private func send<Body: Encodable, Response: Decodable>(
        _ method: Method,
        _ path: String,
        body: Body,
        authenticated: Bool = true
    ) async throws -> Response {
        var request = try makeRequest(method, path, authenticated: authenticated)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try FrameStationCoding.encoder.encode(body)
        let data = try await run(request)
        return try FrameStationCoding.decoder.decode(Response.self, from: data)
    }

    private func sendNoContent<Body: Encodable>(
        _ method: Method,
        _ path: String,
        body: Body,
        authenticated: Bool = true
    ) async throws {
        var request = try makeRequest(method, path, authenticated: authenticated)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try FrameStationCoding.encoder.encode(body)
        _ = try await run(request)
    }

    /// Sends a request and reports what happened.
    ///
    /// Every path funnels through here so the reporting is written once. Doing
    /// it per call site would let a newly added endpoint opt out of the
    /// connection banner by simply forgetting to.
    private func run(_ request: URLRequest, fromFile fileURL: URL? = nil) async throws -> Data {
        do {
            let data: Data
            let response: URLResponse
            if let fileURL {
                (data, response) = try await session.upload(for: request, fromFile: fileURL)
            } else {
                (data, response) = try await session.data(for: request)
            }
            try validate(response, data: data)
            outcomeObserver?(nil)
            return data
        } catch {
            outcomeObserver?(TransferFailure.classify(error))
            throw error
        }
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw FrameStationClientError.notHTTP
        }
        guard (200..<300).contains(http.statusCode) else {
            // The server returns {"error": true, "reason": "..."} on Abort.
            let reason = (try? JSONDecoder().decode(ServerError.self, from: data))?.reason
            throw FrameStationClientError.http(status: http.statusCode, reason: reason)
        }
    }

    private struct ServerError: Decodable {
        let reason: String?
    }
}

public enum FrameStationClientError: Error, LocalizedError, Equatable {
    case invalidURL(String)
    case notAuthenticated
    case notHTTP
    case http(status: Int, reason: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let path):
            return "Could not build a URL for \(path)."
        case .notAuthenticated:
            return "Not signed in to this server."
        case .notHTTP:
            return "Unexpected non-HTTP response."
        case .http(let status, let reason):
            return reason ?? "Server returned HTTP \(status)."
        }
    }
}
