import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import FrameStationKit

/// A tile that hasn't heard the NAS finished can still have its thumbnail from
/// an earlier session, and that picture beats the camera roll's. These pin the
/// lookup that finds it: from disk, for the version asked about, and never by
/// asking the NAS.
@Suite("A thumbnail already on this device is found without asking the NAS")
struct StoredThumbnailTests {
    @Test("Found on disk, for its own version only")
    func foundOnDiskForItsVersion() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fs-stored-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let asset = UUID()
        try jpeg(side: 64).write(to: root.appendingPathComponent("\(asset)-256-4"))

        // Nothing listens on port 9, so a lookup that asked the NAS would fail
        // rather than find anything.
        let loader = ThumbnailLoader(
            client: FrameStationClient(configuration: .init(baseURL: URL(string: "http://127.0.0.1:9")!)),
            diskRoot: root
        )

        #expect(await loader.storedThumbnail(assetID: asset, size: 256, version: 4) != nil)
        // Kept for the next lookup, so a tile built again draws it at once.
        #expect(loader.cachedThumbnail(assetID: asset, size: 256, version: 4) != nil)
        // A replaced thumbnail is a different picture, not a stand-in for it.
        #expect(await loader.storedThumbnail(assetID: asset, size: 256, version: 3) == nil)
        #expect(await loader.storedThumbnail(assetID: UUID(), size: 256, version: 4) == nil)
    }

    private func jpeg(side: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
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
