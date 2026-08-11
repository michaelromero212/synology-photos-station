import FrameStationAPI
import Foundation

/// The last timeline this device saw, kept on disk so the grid can draw
/// without a network.
///
/// Without it, launching out of range shows nothing at all — the manifest
/// lives in memory, the first fetch fails, and the library appears to be
/// empty. With it you get what Synology Photos gives you in airplane mode:
/// the day headers, the places, the shape of the library, and whichever
/// thumbnails the image cache still holds.
///
/// Deliberately *not* in `Caches/`. iOS empties that directory under storage
/// pressure, which is exactly the moment someone needs their library to still
/// open. This is small, and it is the difference between an app that works
/// offline and one that looks broken.
public struct TimelineSnapshot: Codable, Sendable {
    public let manifest: TimelineManifest
    public let items: [String: [TimelineItem]]
    public let cursor: Int64
    public let savedAt: Date
}

public enum TimelineSnapshotStore {
    /// How many items are worth keeping.
    ///
    /// The manifest is what draws the grid and it is tiny; items only decide
    /// which tiles can show a picture. Persisting all of a 67k library would
    /// mean re-encoding megabytes every time a bucket loads during a scroll,
    /// to make photos from 2011 available offline that nobody is going to
    /// open. Newest first, because that is what offline browsing is for.
    static let maxItems = 5_000

    private static var root: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        let directory = base.appendingPathComponent("FrameStation/timeline", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            // Derived data — it should never inflate someone's iCloud backup.
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return directory
    }

    private static func file(spaceID: UUID, zoom: TimelineZoom) -> URL? {
        root?.appendingPathComponent("\(spaceID)-\(zoom.rawValue).json")
    }

    public static func load(spaceID: UUID, zoom: TimelineZoom) -> TimelineSnapshot? {
        guard let file = file(spaceID: spaceID, zoom: zoom),
              let data = try? Data(contentsOf: file)
        else { return nil }
        return try? FrameStationCoding.decoder.decode(TimelineSnapshot.self, from: data)
    }

    /// Trims to `maxItems` in manifest order, then writes.
    ///
    /// Runs off the main actor: the store that calls this drives a scrolling
    /// grid, and encoding a few thousand items is not something to do between
    /// two frames.
    public static func save(
        manifest: TimelineManifest,
        items: [String: [TimelineItem]],
        cursor: Int64,
        spaceID: UUID,
        zoom: TimelineZoom
    ) {
        guard let file = file(spaceID: spaceID, zoom: zoom) else { return }

        var kept: [String: [TimelineItem]] = [:]
        var budget = maxItems
        for bucket in manifest.buckets {
            guard budget > 0 else { break }
            guard let bucketItems = items[bucket.key] else { continue }
            kept[bucket.key] = Array(bucketItems.prefix(budget))
            budget -= min(budget, bucketItems.count)
        }

        let snapshot = TimelineSnapshot(
            manifest: manifest, items: kept, cursor: cursor, savedAt: Date()
        )
        guard let data = try? FrameStationCoding.encoder.encode(snapshot) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// Signing out must not leave the last library on disk. These are places
    /// and dates for someone's family, and the next person to sign in on this
    /// device has no business seeing them.
    public static func clearAll() {
        guard let root else { return }
        try? FileManager.default.removeItem(at: root)
    }

    public static func diskSize() -> Int64 {
        guard let root, let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
