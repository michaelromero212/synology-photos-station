import CoreGraphics
import FrameStationAPI
import Foundation
import ImageIO

#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#endif

/// Two-tier thumbnail cache: decoded images in memory, encoded bytes on disk.
///
/// Both tiers matter for different reasons. The memory tier avoids re-decoding
/// while scrolling, which is the expensive part. The disk tier means scrolling
/// back through last year costs nothing over the network — and because every
/// URL here is content-addressed, cached bytes can never go stale.
public actor ThumbnailLoader {
    private let client: FrameStationClient
    private let session: URLSession
    private let memory = NSCache<NSString, CacheEntry>()
    private let diskRoot: URL
    private var inFlight: [URL: Task<PlatformImage?, Never>] = [:]

    final class CacheEntry: NSObject {
        let image: PlatformImage
        let cost: Int
        init(image: PlatformImage, cost: Int) {
            self.image = image
            self.cost = cost
        }
    }

    public init(
        client: FrameStationClient,
        memoryLimitBytes: Int = 96 * 1024 * 1024,
        diskRoot: URL? = nil
    ) {
        self.client = client
        self.session = .shared
        self.memory.totalCostLimit = memoryLimitBytes

        let base = diskRoot ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FrameStation/thumbs", isDirectory: true)
        self.diskRoot = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    public func thumbnail(assetID: UUID, size: Int = 256) async -> PlatformImage? {
        guard let url = await client.thumbnailURL(assetID: assetID, size: size) else { return nil }
        return await image(at: url, key: "\(assetID)-\(size)", targetPixels: size)
    }

    public func preview(assetID: UUID, targetPixels: Int = 2048) async -> PlatformImage? {
        guard let url = await client.previewURL(assetID: assetID) else { return nil }
        return await image(at: url, key: "\(assetID)-preview", targetPixels: targetPixels)
    }

    // MARK: - Core

    private func image(at url: URL, key: String, targetPixels: Int) async -> PlatformImage? {
        if let entry = memory.object(forKey: key as NSString) { return entry.image }

        // Coalesce: a fast scroll can ask for the same cell several times before
        // the first request returns.
        if let existing = inFlight[url] { return await existing.value }

        let task = Task<PlatformImage?, Never> { [diskRoot, session, client] in
            let diskPath = diskRoot.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_"))

            if let data = try? Data(contentsOf: diskPath),
               let image = Self.decode(data, targetPixels: targetPixels) {
                return image
            }

            var request = URLRequest(url: url)
            if let header = await client.authorizationHeader() {
                request.setValue(header, forHTTPHeaderField: "Authorization")
            }

            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse
            else { return nil }

            // 202 means the derivation queue hasn't reached it yet. Not an
            // error and not cacheable — the caller keeps its ThumbHash and the
            // next scroll pass will pick it up.
            guard http.statusCode == 200 else { return nil }

            try? data.write(to: diskPath, options: .atomic)
            return Self.decode(data, targetPixels: targetPixels)
        }

        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil

        if let image {
            memory.setObject(
                CacheEntry(image: image, cost: targetPixels * targetPixels * 4),
                forKey: key as NSString,
                cost: targetPixels * targetPixels * 4
            )
        }
        return image
    }

    /// Downsamples during decode rather than after.
    ///
    /// Decoding a 12 MP JPEG to a full bitmap costs ~48 MB before you scale it;
    /// at a screenful of cells that is an immediate memory spike and a dropped
    /// frame. `kCGImageSourceThumbnailMaxPixelSize` makes ImageIO decode
    /// straight to the size we actually want.
    nonisolated static func decode(_ data: Data, targetPixels: Int) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: targetPixels,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #elseif canImport(AppKit)
        return NSImage(cgImage: cgImage, size: .zero)
        #endif
    }

    /// Renders a ThumbHash to a tiny image for the instant placeholder.
    public nonisolated static func placeholder(from hash: [UInt8]) -> PlatformImage? {
        guard let decoded = ThumbHash.decode(hash, maxDimension: 32) else { return nil }

        var pixels = decoded.rgba
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(
            data: Data(bytes: &pixels, count: pixels.count) as CFData
        ), let cgImage = CGImage(
            width: decoded.width,
            height: decoded.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: decoded.width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }

        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #elseif canImport(AppKit)
        return NSImage(cgImage: cgImage, size: .zero)
        #endif
    }

    public func clearMemoryCache() {
        memory.removeAllObjects()
    }

    public func diskCacheSize() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: diskRoot, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
