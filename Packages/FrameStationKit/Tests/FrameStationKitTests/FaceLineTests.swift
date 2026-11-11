import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import FrameStationKit

/// Answers for the NAS's face pictures, but only once the test lets it, and
/// remembers each face asked for. Kept apart from the other stubs, whose
/// answers other suites share.
final class HeldFaces: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var asked: [String] = []
    nonisolated(unsafe) private static var open = false
    nonisolated(unsafe) static var picture = Data()

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldFaces.self]
        return URLSession(configuration: configuration)
    }

    static func asked(in run: String) -> [String] {
        lock.withLock { asked.filter { $0.hasPrefix("/\(run)/") } }
    }

    static func answer() { lock.withLock { open = true } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock { Self.asked.append(url.path) }
        wait()
    }

    private func wait() {
        guard Self.lock.withLock({ Self.open }) else {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { self.wait() }
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/jpeg"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.picture)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Scrolling the grid of People starts a fetch for every circle it passes,
/// six at a time. The circles scrolled past used to wait their turn anyway,
/// and the ones on screen waited behind all of them (his screenshot,
/// 2026-11-10). A face whose circle is gone leaves the line.
@Suite("A face whose circle is gone leaves the line")
struct FaceLineTests {
    @Test("Circles scrolled past are never fetched; the one the scroll stops on is")
    func scrolledPastLeave() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fs-faces-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        HeldFaces.picture = try jpeg(side: 32)

        let loader = ThumbnailLoader(
            client: FrameStationClient(configuration: .init(baseURL: URL(string: "https://nas.test")!)),
            diskRoot: root,
            session: HeldFaces.session()
        )
        let run = UUID().uuidString
        func face(_ name: String) -> Task<PlatformImage?, Never> {
            Task { await loader.face(at: URL(string: "https://nas.test/\(run)/\(name)")!, key: "\(run)-\(name)") }
        }

        // The first screenful takes every slot, and the NAS is slow to answer.
        let first = (1...6).map { face("first\($0)") }
        for _ in 0..<500 where HeldFaces.asked(in: run).count < 6 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(HeldFaces.asked(in: run).count == 6)

        // Twenty circles go by while it does, each gone before its turn.
        let passed = (1...20).map { face("passed\($0)") }
        try await Task.sleep(for: .milliseconds(200))
        passed.forEach { $0.cancel() }
        try await Task.sleep(for: .milliseconds(200))

        // The scroll stops; then the NAS answers.
        let stoppedOn = face("stopped")
        try await Task.sleep(for: .milliseconds(100))
        HeldFaces.answer()

        for task in first { #expect(await task.value != nil) }
        for task in passed { #expect(await task.value == nil) }
        #expect(await stoppedOn.value != nil)
        let asked = HeldFaces.asked(in: run)
        #expect(asked.count == 7)
        #expect(!asked.contains { $0.contains("passed") })
    }

    private func jpeg(side: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
