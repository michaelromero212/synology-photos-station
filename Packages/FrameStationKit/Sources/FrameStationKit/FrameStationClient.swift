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

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
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

    /// Request with a JSON body and no response body.
    func sendBodyNoContent<Body: Encodable>(_ method: Method, _ path: String, body: Body) async throws {
        try await sendNoContent(method, path, body: body)
    }

    /// Authenticated request with no body either way (favourite toggles).
    func sendEmpty(_ method: Method, _ path: String) async throws {
        let request = try makeRequest(method, path)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
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
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        try validate(response, data: data)
        return try FrameStationCoding.decoder.decode(ChunkAcceptedResponse.self, from: data)
    }

    public func commitUpload(
        uploadID: UUID,
        _ body: CommitUploadRequest
    ) async throws -> CommitUploadResponse {
        try await send(.post, "v1/uploads/\(uploadID)/commit", body: body)
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
        let request = try makeRequest(method, path, authenticated: authenticated)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
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
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
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
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
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
