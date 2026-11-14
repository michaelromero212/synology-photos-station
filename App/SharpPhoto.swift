import FrameStationKit
import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The original photograph, decoded for the screen it is on.
///
/// The 2048 px preview the NAS renders is a JPEG in sRGB with no HDR: right
/// for a first look, short of what the photo really is. An iPhone shoots in
/// Display P3, most of its photos carry an HDR gain map, and an iPad Pro,
/// a Mac or a 4K television has more pixels than 2048 across. Apple Photos
/// shows each device the original sized to its screen, and so does this — the
/// preview goes up first, then the original takes its place where it stands.
///
/// Decoded here, on the device, rather than rendered larger on the NAS: the
/// original already holds the color and the gain map, the NAS stores nothing
/// new, and the size can be exactly this screen's.
enum SharpPhoto {
    /// Above this the preview has to do: a RAW original can run to tens of
    /// megabytes, too much to fetch for one look.
    static let byteLimit: Int64 = 60_000_000

    /// The longest side, in pixels, of the largest screen this device shows
    /// photos on. Never below the preview, which it is meant to beat, and
    /// capped so a 6K display doesn't turn a single photo into 300 MB of
    /// bitmap.
    @MainActor
    static var screenLongEdge: Int {
        #if os(macOS)
        let edge = NSScreen.screens
            .map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }
            .max() ?? 2880
        #else
        let bounds = UIScreen.main.nativeBounds
        let edge = max(bounds.width, bounds.height)
        #endif
        return min(max(Int(edge.rounded()), 2048), 5120)
    }

    /// Whether to fetch originals at all. "Speed first" is someone asking to
    /// spend as little data as possible, and they get the preview.
    static var isAllowed: Bool {
        PlaybackSettings.videoQuality != .dataSaver
    }

    /// The original, upright, at most `maxPixels` on its longer side, in its
    /// own color space and with its HDR applied where it has any.
    nonisolated static func decode(_ data: Data, maxPixels: Int) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // The original carries its orientation as a tag; the preview was
            // already turned upright on the NAS.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        // Only for a photo that has a gain map: decoding to HDR doubles the
        // bitmap, which a plain photo would pay for nothing.
        if #available(iOS 18.0, macOS 15.0, tvOS 18.0, *), hasGainMap(source) {
            options[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        #if os(macOS)
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        #else
        return UIImage(cgImage: image)
        #endif
    }

    /// Apple's own gain map, which every iPhone since the 12 writes, or the
    /// ISO one that iOS 18 and later and other cameras write.
    @available(iOS 18.0, macOS 15.0, tvOS 18.0, *)
    nonisolated static func hasGainMap(_ source: CGImageSource) -> Bool {
        let kinds = [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap]
        return kinds.contains { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil }
    }

    /// Fetches and decodes in one go, or nil when the preview has to do.
    static func load(
        assetID: UUID, byteSize: Int64?, client: FrameStationClient, maxPixels: Int
    ) async -> PlatformImage? {
        if let byteSize, byteSize > byteLimit { return nil }
        guard let data = await OriginalBytes.shared.data(assetID: assetID, client: client),
              !Task.isCancelled
        else { return nil }
        // Off the main thread: decoding a big HEIC on it is a visible stall.
        return await Task.detached(priority: .userInitiated) {
            decode(data, maxPixels: maxPixels)
        }.value
    }
}

/// Originals recently fetched, still compressed, so swiping back to a photo
/// decodes it again instead of downloading it again. A few megabytes each;
/// the cache lets the oldest go first.
actor OriginalBytes {
    static let shared = OriginalBytes()

    private let cache: NSCache<NSUUID, NSData> = {
        let cache = NSCache<NSUUID, NSData>()
        cache.totalCostLimit = 96 * 1_024 * 1_024
        return cache
    }()
    /// One download per original, however many pages ask at once.
    private var inFlight: [UUID: Task<Data?, Never>] = [:]

    func data(assetID: UUID, client: FrameStationClient) async -> Data? {
        if let cached = cache.object(forKey: assetID as NSUUID) { return cached as Data }
        if let running = inFlight[assetID] { return await running.value }
        let task = Task<Data?, Never> {
            guard let url = await client.originalURL(assetID: assetID) else { return nil }
            var request = URLRequest(url: url)
            if let header = await client.authorizationHeader() {
                request.setValue(header, forHTTPHeaderField: "Authorization")
            }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200
            else { return nil }
            return data
        }
        inFlight[assetID] = task
        let data = await task.value
        inFlight[assetID] = nil
        if let data { cache.setObject(data as NSData, forKey: assetID as NSUUID, cost: data.count) }
        return data
    }
}

/// How many decoded originals the viewer holds at once.
///
/// The viewer keeps a model for every photo you've swiped past, so a sharp
/// image left on each would add up to gigabytes over one evening's scrolling —
/// and running out of memory is a crash. The few most recent stay; the rest go
/// back to their preview and decode again, from `OriginalBytes`, if you return.
@MainActor
final class SharpImageBudget {
    static let shared = SharpImageBudget()

    /// The page on screen, the ones either side and one more for a quick
    /// swipe back — fewer when each is large. An HDR photo decodes to 16
    /// bits a channel, so one 5K original on a Mac is about 150 MB.
    private let limit = 4
    private let byteLimit = 400 * 1_024 * 1_024
    private var recent: [(id: ObjectIdentifier, bytes: Int)] = []
    private var drops: [ObjectIdentifier: () -> Void] = [:]

    func admit(_ owner: AnyObject, image: PlatformImage, drop: @escaping () -> Void) {
        let id = ObjectIdentifier(owner)
        recent.removeAll { $0.id == id }
        recent.append((id, Self.bytes(of: image)))
        drops[id] = drop
        while recent.count > 1,
              recent.count > limit || recent.reduce(0, { $0 + $1.bytes }) > byteLimit {
            let oldest = recent.removeFirst()
            drops.removeValue(forKey: oldest.id)?()
        }
    }

    private static func bytes(of image: PlatformImage) -> Int {
        #if os(macOS)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        #else
        guard let cg = image.cgImage else { return 0 }
        #endif
        return cg.bytesPerRow * cg.height
    }
}
