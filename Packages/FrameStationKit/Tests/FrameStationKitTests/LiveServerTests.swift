import FrameStationAPI
import XCTest

@testable import FrameStationKit

/// Integration tests against a running server.
///
/// Skipped unless `FRAMESTATION_LIVE_URL` is set, so the normal `swift test` run
/// stays hermetic:
///
///     FRAMESTATION_LIVE_URL=http://127.0.0.1:8099 swift test
///
/// These exist because compiling is not the same as agreeing. The client and
/// server share types, but they do not share a JSON encoder configuration
/// unless both go through `FrameStationCoding` — and that mismatch is invisible
/// until a real request crosses the wire.
final class LiveServerTests: XCTestCase {
    private var baseURL: URL?

    override func setUp() {
        super.setUp()
        baseURL = ProcessInfo.processInfo.environment["FRAMESTATION_LIVE_URL"]
            .flatMap(URL.init(string:))
    }

    private func requireServer() throws -> FrameStationClient {
        guard let baseURL else {
            throw XCTSkip("Set FRAMESTATION_LIVE_URL to run live server tests.")
        }
        return FrameStationClient(configuration: .init(baseURL: baseURL))
    }

    func testHealthEndpointDecodes() async throws {
        let client = try requireServer()
        let health = try await client.health()

        XCTAssertEqual(health.status, "ok")
        XCTAssertEqual(health.database, "up")
        XCTAssertGreaterThan(health.migrationsApplied, 0)
    }

    func testUnauthenticatedRequestSurfacesServerReason() async throws {
        let client = try requireServer()
        await client.setToken("not-a-real-token")

        do {
            _ = try await client.me()
            XCTFail("Expected an authentication failure.")
        } catch let error as FrameStationClientError {
            guard case .http(let status, _) = error else {
                return XCTFail("Expected an HTTP error, got \(error).")
            }
            XCTAssertEqual(status, 401)
        }
    }

    func testMissingTokenFailsBeforeHittingTheNetwork() async throws {
        let client = try requireServer()

        do {
            _ = try await client.me()
            XCTFail("Expected .notAuthenticated.")
        } catch let error as FrameStationClientError {
            XCTAssertEqual(error, .notAuthenticated)
        }
    }
}
