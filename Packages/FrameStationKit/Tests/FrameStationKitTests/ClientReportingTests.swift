import Foundation
import Testing
@testable import FrameStationKit

/// Answers every request with an empty 200, except a path containing "hang",
/// which it never answers at all: a request that can only end by being called
/// off, and a playback link, which gets one. Kept apart from `StubServer`,
/// whose queued answers other suites share.
final class ReportingStub: URLProtocol {
    /// Every address asked for, in order.
    nonisolated(unsafe) private static var asked: [URL] = []
    private static let lock = NSLock()
    static var requested: [URL] { lock.withLock { asked } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReportingStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock { Self.asked.append(url) }
        guard !url.path.contains("hang") else { return }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        let body = url.path.hasSuffix("/playback")
            ? Data(#"{"url":"https://nas.test/v1/stream/x","expiresAt":"2030-01-01T00:00:00Z","kind":"direct"}"#.utf8)
            : Data()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// What the client's observers heard, from whichever thread they heard it on.
private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var _writes: [String] = []
    private var _outcomes: [TransferFailure?] = []

    var writes: [String] { lock.withLock { _writes } }
    var outcomes: [TransferFailure?] { lock.withLock { _outcomes } }

    func write(_ path: String) { lock.withLock { _writes.append(path) } }
    func outcome(_ failure: TransferFailure?) { lock.withLock { _outcomes.append(failure) } }
}

@Suite("The client reports what the app's pages and banner need to know")
struct ClientReportingTests {
    private func client(heard: Heard) async -> FrameStationClient {
        let client = FrameStationClient(
            configuration: .init(baseURL: URL(string: "https://nas.test")!, token: "token"),
            session: ReportingStub.session()
        )
        await client.observeWrites { heard.write($0) }
        await client.observeOutcomes { heard.outcome($0) }
        return client
    }

    /// Every screen that leaves cancels what it was loading. Counted as a
    /// failure, each one sent the connection monitor to check the NAS, and on
    /// a phone just back from the background that check could fail too.
    @Test("A request the app called off isn't evidence about the NAS")
    func cancellationIsNotAFailure() async throws {
        #expect(FrameStationClient.isCancellation(URLError(.cancelled)))
        #expect(FrameStationClient.isCancellation(CancellationError()))
        #expect(!FrameStationClient.isCancellation(URLError(.timedOut)))
        #expect(!FrameStationClient.isCancellation(URLError(.cannotConnectToHost)))

        let heard = Heard()
        let client = await client(heard: heard)
        let request = Task { try await client.sendEmpty(.get, "v1/hang") }
        try await Task.sleep(for: .milliseconds(200))
        request.cancel()
        await #expect(throws: (any Error).self) { try await request.value }
        #expect(heard.outcomes.isEmpty)
    }

    /// A server from before ladders reads `quality` and nothing else, so the
    /// question rides beside it: asked as a quality of its own, an old server
    /// would have taken it for a request for the original, a 51 Mbps file on a
    /// cellular link.
    @Test("A ladder is asked for beside the quality, never in its place")
    func adaptiveIsAskedBesideTheQuality() async throws {
        let client = await client(heard: Heard())
        let asset = UUID()
        _ = try await client.playbackURL(assetID: asset, quality: .mobile, adaptive: true)
        _ = try await client.playbackURL(assetID: asset, quality: .original)
        let asked = ReportingStub.requested.filter { $0.path.contains(asset.uuidString) }
        let queries = asked.map { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems ?? [] }
        #expect(queries.count == 2)
        #expect(queries.first == [
            URLQueryItem(name: "quality", value: "mobile"), URLQueryItem(name: "adaptive", value: "1"),
        ])
        #expect(queries.last == [URLQueryItem(name: "quality", value: "original")])
    }

    @Test("Writes the server accepted are reported by path, and reads aren't")
    func writesAreReported() async throws {
        let heard = Heard()
        let client = await client(heard: heard)
        let asset = "v1/spaces/\(UUID())/assets/\(UUID())"

        try await client.sendEmpty(.get, asset)
        #expect(heard.writes.isEmpty)

        try await client.sendEmpty(.delete, asset)
        #expect(heard.writes == ["/" + asset])
        // Still a success to the banner, as every answered request is.
        #expect(heard.outcomes.count == 2 && heard.outcomes.allSatisfy { $0 == nil })
    }
}
