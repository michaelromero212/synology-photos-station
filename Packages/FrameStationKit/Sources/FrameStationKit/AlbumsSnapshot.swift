import FrameStationAPI
import Foundation

/// The last Albums page this device saw, kept on disk so the page draws at once
/// on a fresh launch rather than waiting for the NAS.
///
/// The albums and the collections were held only in memory, so every launch
/// opened the page empty until the NAS answered. That is normally a moment, but
/// right after a large backup the NAS is busy filing what arrived, and the first
/// visit sat blank for most of half a minute. Now the page draws what it showed
/// last time and takes the new answer when it comes, the way the grid does with
/// `TimelineSnapshotStore`, and in the same place for the same reasons.
public enum AlbumsSnapshotStore {
    private static var root: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        let directory = base.appendingPathComponent("FrameStation/albums", isDirectory: true)
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

    // MARK: - Albums

    public static func loadAlbums() -> [AlbumDTO]? {
        load([AlbumDTO].self, from: "albums.json")
    }

    public static func saveAlbums(_ albums: [AlbumDTO]) {
        save(albums, to: "albums.json")
    }

    // MARK: - Collections

    public static func loadCollections(spaceID: UUID) -> CollectionsResponse? {
        load(CollectionsResponse.self, from: "collections-\(spaceID).json")
    }

    public static func saveCollections(_ page: CollectionsResponse, spaceID: UUID) {
        save(page, to: "collections-\(spaceID).json")
    }

    // MARK: - The Places row

    public static func loadPlaceTotal(spaceID: UUID) -> Int? {
        load(Int.self, from: "places-\(spaceID).json")
    }

    public static func savePlaceTotal(_ total: Int, spaceID: UUID) {
        save(total, to: "places-\(spaceID).json")
    }

    /// Signing out must not leave the last library's albums on disk, for the
    /// same reason as `TimelineSnapshotStore.clearAll`: trips are places and
    /// dates for someone's family.
    public static func clearAll() {
        guard let root else { return }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Files

    private static func load<Value: Decodable>(_ type: Value.Type, from name: String) -> Value? {
        guard let file = root?.appendingPathComponent(name),
              let data = try? Data(contentsOf: file)
        else { return nil }
        return try? FrameStationCoding.decoder.decode(type, from: data)
    }

    private static func save<Value: Encodable>(_ value: Value, to name: String) {
        guard let file = root?.appendingPathComponent(name),
              let data = try? FrameStationCoding.encoder.encode(value)
        else { return }
        try? data.write(to: file, options: .atomic)
    }
}
