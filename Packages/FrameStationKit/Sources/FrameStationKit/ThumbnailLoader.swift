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
    /// `nonisolated(unsafe)` because `NSCache` carries its own lock, so the
    /// actor's isolation is redundant for it — and `cachedThumbnail` needs to
    /// read it without suspending. Spelled out rather than left implicit: the
    /// exemption is safe for *this* type specifically, not for the rest of the
    /// actor's state, which genuinely does need the isolation.
    nonisolated(unsafe) private let memory = NSCache<NSString, CacheEntry>()
    /// Decoded ThumbHash previews. Counted rather than weighed — each one is
    /// thirty-two pixels square, so a few thousand is a rounding error beside
    /// the picture cache above. See `cachedPlaceholder`.
    nonisolated(unsafe) private let previews = NSCache<NSString, CacheEntry>()
    private let diskRoot: URL
    private var inFlight: [URL: Task<Fetched, Never>] = [:]

    final class CacheEntry: NSObject {
        let image: PlatformImage
        let cost: Int
        init(image: PlatformImage, cost: Int) {
            self.image = image
            self.cost = cost
        }
    }

    /// Bytes the disk tier may hold. See `pruneIfNeeded`.
    private var diskLimitBytes: Int64
    /// Running total, so an ordinary cache write doesn't stat the whole
    /// directory. `nil` until the first measurement.
    private var diskBytes: Int64?

    public init(
        client: FrameStationClient,
        memoryLimitBytes: Int = 96 * 1024 * 1024,
        diskLimitBytes: Int64 = CacheLimit.default.bytes,
        diskRoot: URL? = nil
    ) {
        self.client = client
        self.session = .shared
        self.memory.totalCostLimit = memoryLimitBytes
        self.previews.countLimit = 4000
        self.diskLimitBytes = diskLimitBytes

        let base = diskRoot ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FrameStation/thumbs", isDirectory: true)
        self.diskRoot = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    /// Applied immediately, so lowering the cap in Settings frees space then
    /// rather than at some later write.
    public func setDiskLimit(_ bytes: Int64) {
        diskLimitBytes = bytes
        pruneIfNeeded(remeasure: true)
    }

    public func thumbnail(
        assetID: UUID, size: Int = 256, version: Int = 0, isPrefetch: Bool = false
    ) async -> PlatformImage? {
        guard let url = await client.thumbnailURL(
            assetID: assetID, size: size, version: version
        ) else { return nil }
        // The version is in the key as well as the URL: a regenerated thumbnail
        // is a different key, so the loader's own two-tier cache doesn't hand
        // back the stale one either.
        return await image(
            at: url, key: "\(assetID)-\(size)-\(version)",
            targetPixels: size, isPrefetch: isPrefetch
        )
    }

    /// An already-decoded thumbnail, without suspending.
    ///
    /// Everything else here is `async`, which means even a tile whose image is
    /// sitting decoded in memory has to wait for two actor hops — one to build
    /// the URL, one to reach this cache — before it can be drawn. Across a
    /// screenful that is a frame or two of gray on every appearance, and leaving
    /// a tab and coming back re-runs all of it: the grid is rebuilt from
    /// scratch, so every visible cell pays the round trip again at once.
    ///
    /// The key is derivable from the asset and the size alone, so the lookup
    /// needs none of that. `NSCache` is its own lock, and this only ever reads,
    /// so it is safe to reach from outside the actor's isolation.
    nonisolated public func cachedThumbnail(
        assetID: UUID, size: Int, version: Int = 0
    ) -> PlatformImage? {
        memory.object(forKey: "\(assetID)-\(size)-\(version)" as NSString)?.image
    }

    /// An already-decoded ThumbHash preview, without suspending.
    ///
    /// The same bargain as `cachedThumbnail` above, for the blurred stand-in
    /// rather than the picture. One preview is thirty-two pixels square and
    /// costs almost nothing, which is why it was decoded inline as each cell was
    /// built; the flaw in that reasoning is that a fling builds thirty cells in
    /// a frame, and thirty of almost-nothing is main-thread work in the middle
    /// of a scroll.
    ///
    /// Worth being accurate about the size of it, because it was chased as the
    /// cause of a stutter and is not: on the measured fling it was one dropped
    /// frame of eight. The badges on `PhotoCell` were three, and two more are
    /// still unaccounted for. This is right on principle — decoding on the main
    /// thread while scrolling is never correct — rather than decisive.
    ///
    /// The cache is the part that earns its keep. A tile seen before opens on
    /// its blur with a dictionary lookup, which is the case that motivated
    /// decoding eagerly in the first place: leaving a tab and coming back
    /// rebuilds every visible cell at once.
    nonisolated public func cachedPlaceholder(assetID: UUID) -> PlatformImage? {
        previews.object(forKey: assetID.uuidString as NSString)?.image
    }

    /// Decodes a ThumbHash away from the caller's thread and keeps the result.
    ///
    /// `nonisolated` so it runs on the generic executor rather than queueing
    /// behind whatever this actor is doing — the fetches it serializes are
    /// network work, and a preview should not have to wait in that line.
    nonisolated public func placeholder(assetID: UUID, hash: [UInt8]) async -> PlatformImage? {
        let key = assetID.uuidString as NSString
        if let held = previews.object(forKey: key) { return held.image }
        guard let decoded = Self.placeholder(from: hash) else { return nil }
        previews.setObject(CacheEntry(image: decoded, cost: 1), forKey: key, cost: 1)
        return decoded
    }

    public func preview(assetID: UUID, targetPixels: Int = 2048) async -> PlatformImage? {
        guard let url = await client.previewURL(assetID: assetID) else { return nil }
        return await image(at: url, key: "\(assetID)-preview", targetPixels: targetPixels)
    }

    // MARK: - Prefetching

    /// Warms the cache for photos the user is about to reach.
    ///
    /// The technique Apple Photos leans on hardest: by the time a tile is on
    /// screen its bytes should already be local, so scrolling reveals pictures
    /// rather than gray squares that fill in afterwards.
    ///
    /// Fire-and-forget, and deliberately lower priority than anything visible —
    /// see `acquire`. A prefetch that competed with the tiles someone is
    /// actually looking at would make scrolling worse, not better.
    public func prefetch(_ assets: [(id: UUID, version: Int)], size: Int = 256) {
        for asset in assets {
            let key = "\(asset.id)-\(size)-\(asset.version)" as NSString
            // Already decoded and resident: nothing to do, and checking here
            // keeps a re-scroll over warm content completely free.
            if memory.object(forKey: key) != nil { continue }
            Task {
                _ = await self.thumbnail(
                    assetID: asset.id, size: size, version: asset.version, isPrefetch: true
                )
            }
        }
    }

    // MARK: - Core

    /// How many thumbnail fetches may be in flight at once.
    ///
    /// Unbounded was the real scrolling problem, and it looked like a slow
    /// server rather than a client bug. A fast fling over a large library
    /// starts one request per newly-appeared tile and never cancels them, so
    /// hundreds of fetches for tiles nobody will ever see queue ahead of the
    /// handful actually on screen. On a J4125 serving a 67k library that
    /// starves exactly the requests that matter.
    private static let maxConcurrent = 6
    /// Prefetch stops short of the cap so a visible tile can always get through.
    private static let prefetchCeiling = 3

    /// How deep the prefetch queue may get before further requests are dropped.
    ///
    /// Bounding concurrency alone was not enough, and missing this was the bug:
    /// a fling past twenty days still *queued* every one of their thumbnails,
    /// so the unbounded work simply moved from URLSession's queue to this one
    /// and came due later, fetching tiles that were long gone. Prefetch is a
    /// guess about what will be needed next — when the guesses pile up faster
    /// than they can be served, the old ones are worthless and dropping them is
    /// the correct answer, not deferring them.
    private static let maxPrefetchBacklog = 24

    private var active = 0
    private var waiting: [(isPrefetch: Bool, resume: CheckedContinuation<Void, Never>)] = []

    /// Returns false when a prefetch should simply be abandoned.
    private func acquire(isPrefetch: Bool) async -> Bool {
        let ceiling = isPrefetch ? Self.prefetchCeiling : Self.maxConcurrent
        if active < ceiling {
            active += 1
            return true
        }
        if isPrefetch, waiting.filter({ $0.isPrefetch }).count >= Self.maxPrefetchBacklog {
            return false
        }
        await withCheckedContinuation { continuation in
            waiting.append((isPrefetch, continuation))
        }
        // No increment here: `release` hands its slot straight over rather than
        // dropping the count and letting the woken task put it back. That gap
        // was small but real — another caller could look in between, see room
        // that wasn't there, and push past the ceiling.
        return true
    }

    private func release() {
        // Visible work first, always: a queue served in arrival order would put
        // tiles from three screens away ahead of the one under the thumb.
        if let index = waiting.firstIndex(where: { !$0.isPrefetch }) {
            waiting.remove(at: index).resume.resume()
            return
        }
        // A prefetch may only take the slot if doing so still leaves it under
        // its own, lower ceiling.
        if active <= Self.prefetchCeiling, !waiting.isEmpty {
            waiting.removeFirst().resume.resume()
            return
        }
        active -= 1
    }

    private func image(
        at url: URL, key: String, targetPixels: Int, isPrefetch: Bool = false
    ) async -> PlatformImage? {
        if let entry = memory.object(forKey: key as NSString) { return entry.image }

        // Coalesce: a fast scroll can ask for the same cell several times before
        // the first request returns. Only the originating call accounts for the
        // bytes, so a coalesced caller takes the image and nothing else.
        if let existing = inFlight[url] { return await existing.value.image }

        guard await acquire(isPrefetch: isPrefetch) else { return nil }
        defer { release() }

        let task = Task<Fetched, Never> { [diskRoot, session, client] in
            let diskPath = diskRoot.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_"))

            if let data = try? Data(contentsOf: diskPath),
               let image = Self.decode(data, targetPixels: targetPixels) {
                // Stamp it as used. The modification date is what eviction
                // sorts on, so without this the cache would evict by age
                // rather than by use and throw away the tiles someone scrolls
                // past every day.
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date()], ofItemAtPath: diskPath.path
                )
                return Fetched(image: image, bytesWritten: 0)
            }

            var request = URLRequest(url: url)
            if let header = await client.authorizationHeader() {
                request.setValue(header, forHTTPHeaderField: "Authorization")
            }

            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse
            else { return Fetched(image: nil, bytesWritten: 0) }

            // 202 means the derivation queue hasn't reached it yet. Not an
            // error and not cacheable — the caller keeps its ThumbHash and the
            // next scroll pass will pick it up.
            guard http.statusCode == 200 else { return Fetched(image: nil, bytesWritten: 0) }

            let wrote = (try? data.write(to: diskPath, options: .atomic)) != nil
            return Fetched(
                image: Self.decode(data, targetPixels: targetPixels),
                bytesWritten: wrote ? Int64(data.count) : 0
            )
        }

        inFlight[url] = task
        let fetched = await task.value
        let image = fetched.image
        inFlight[url] = nil

        if fetched.bytesWritten > 0 {
            diskBytes = (diskBytes ?? measureDiskBytes()) + fetched.bytesWritten
            pruneIfNeeded()
        }

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

        // `targetPixels` is the SHORT edge we need — it is the edge that fills a
        // square grid tile under `scaledToFill`. But `ThumbnailMaxPixelSize`
        // caps the *longest* edge, so passing it straight through shrinks the
        // short edge by the aspect ratio: a 512×1111 thumbnail comes back
        // 236×512, and the tile then upscales that 236 into a blur — which
        // silently undid the server's short-edge sizing. Scale the cap up by the
        // thumbnail's own long/short ratio so the short edge lands on
        // `targetPixels`. (The server thumbnail is already oriented, so its
        // stored pixel dimensions are the displayed ones — no transform to
        // account for here.) `--size down` on the server means this only ever
        // caps, never enlarges past what the derivative holds.
        var maxPixel = targetPixels
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            maxPixel = maxPixelForShortEdge(
                targetShortEdge: targetPixels, sourceWidth: width, sourceHeight: height
            )
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #elseif canImport(AppKit)
        return NSImage(cgImage: cgImage, size: .zero)
        #endif
    }

    /// The `ThumbnailMaxPixelSize` cap that lands a thumbnail's SHORT edge on
    /// `targetShortEdge`.
    ///
    /// ImageIO caps the *longest* edge, but the short edge is the one that fills
    /// a square grid tile under `scaledToFill` — so a 512px short edge on a
    /// 512×1111 derivative has to ask ImageIO for an 1111px longest edge. Scale
    /// the target up by the long/short ratio; the server's `--size down` keeps
    /// this a cap, never an enlargement. Kept a pure function so the sizing is
    /// unit-tested without decoding a real image.
    nonisolated static func maxPixelForShortEdge(
        targetShortEdge: Int, sourceWidth: Int, sourceHeight: Int
    ) -> Int {
        let longEdge = max(sourceWidth, sourceHeight)
        let shortEdge = min(sourceWidth, sourceHeight)
        guard shortEdge > 0 else { return targetShortEdge }
        return Int((Double(targetShortEdge) * Double(longEdge) / Double(shortEdge)).rounded())
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

    /// Drops every cached image, on both tiers.
    ///
    /// Leaves the timeline snapshot alone deliberately — that is metadata, it
    /// is what lets the grid draw at all with no network, and it is a rounding
    /// error next to the pictures.
    public func clearDiskCache() {
        memory.removeAllObjects()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: diskRoot, includingPropertiesForKeys: nil
        )) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
        diskBytes = 0
    }

    /// What Settings shows. Measured rather than reported from the running
    /// total, because iOS may empty `Caches/` underneath us at any time.
    public func diskCacheSize() -> Int64 {
        let measured = measureDiskBytes()
        diskBytes = measured
        return measured
    }

    private func measureDiskBytes() -> Int64 {
        entries().reduce(0) { $0 + $1.size }
    }

    private struct DiskEntry {
        let url: URL
        let size: Int64
        let used: Date
    }

    private func entries() -> [DiskEntry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: diskRoot, includingPropertiesForKeys: keys
        ) else { return [] }
        return files.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return DiskEntry(
                url: url,
                size: Int64(values?.fileSize ?? 0),
                used: values?.contentModificationDate ?? .distantPast
            )
        }
    }

    /// Evicts least-recently-used files once the cache is over its limit.
    ///
    /// Prunes down to 80% rather than exactly to the cap: trimming a single
    /// file per write would mean a full directory scan on nearly every
    /// thumbnail, and scrolling is the one thing this class exists to keep
    /// fast. Going under leaves room for a few thousand more writes first.
    ///
    /// `remeasure` is for an explicit user action — iOS empties `Caches/` on
    /// its own schedule, so the running total is a good enough guide for a
    /// write but not for something someone is watching.
    private func pruneIfNeeded(remeasure: Bool = false) {
        let total = remeasure ? measureDiskBytes() : (diskBytes ?? measureDiskBytes())
        diskBytes = total
        guard total > diskLimitBytes else { return }

        let target = Int64(Double(diskLimitBytes) * 0.8)
        var remaining = total
        // Oldest use first — the definition of least-recently-used, and why
        // the read path above touches the modification date.
        for entry in entries().sorted(by: { $0.used < $1.used }) {
            guard remaining > target else { break }
            guard (try? FileManager.default.removeItem(at: entry.url)) != nil else { continue }
            remaining -= entry.size
        }
        diskBytes = remaining
    }
}

private struct Fetched {
    let image: PlatformImage?
    let bytesWritten: Int64
}
