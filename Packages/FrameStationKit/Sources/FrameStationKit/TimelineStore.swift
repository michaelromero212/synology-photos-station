import FrameStationAPI
import Foundation
import Observation

/// Holds the timeline for one space.
///
/// The manifest arrives first and is tiny — bucket keys and counts only — which
/// is enough to lay out every section and drive a correct fast-scrubber before
/// a single image loads. Bucket contents are fetched as they come into view.
@Observable
@MainActor
public final class TimelineStore {
    public enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var manifest: TimelineManifest?
    public private(set) var state: LoadState = .idle
    /// Bucket key → items, populated on demand.
    public private(set) var items: [String: [TimelineItem]] = [:]
    public private(set) var cursor: Int64 = 0

    private let client: FrameStationClient
    public let spaceID: UUID
    public private(set) var zoom: TimelineZoom
    private var loadingBuckets: Set<String> = []

    public init(client: FrameStationClient, spaceID: UUID, zoom: TimelineZoom = .day) {
        self.client = client
        self.spaceID = spaceID
        self.zoom = zoom
    }

    public var buckets: [TimelineBucket] { manifest?.buckets ?? [] }
    public var total: Int { manifest?.total ?? 0 }

    public func load() async {
        state = .loading
        do {
            let manifest = try await client.timeline(spaceID: spaceID, zoom: zoom)
            self.manifest = manifest
            self.cursor = manifest.cursor
            self.state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func setZoom(_ newZoom: TimelineZoom) async {
        guard newZoom != zoom else { return }
        zoom = newZoom
        items.removeAll()
        await load()
    }

    /// Idempotent and de-duplicated — safe to call from `onAppear` on every cell.
    public func loadBucket(_ key: String) async {
        guard items[key] == nil, !loadingBuckets.contains(key) else { return }
        loadingBuckets.insert(key)
        defer { loadingBuckets.remove(key) }

        do {
            let page = try await client.bucket(spaceID: spaceID, key: key, zoom: zoom)
            items[key] = page.items
        } catch {
            items[key] = []
        }
    }

    /// Pulls everything that changed since `cursor` and applies it in place.
    ///
    /// Applied idempotently on purpose: the server serialises `change_log`
    /// sequence assignment per space, but a client that replays a range after a
    /// dropped connection must not double-insert.
    public func refresh() async {
        guard manifest != nil else { return await load() }
        do {
            let delta = try await client.changes(spaceID: spaceID, since: cursor)
            guard !delta.changes.isEmpty else { return }

            var touched = Set<String>()
            for change in delta.changes {
                switch change.op {
                case .insert, .update:
                    guard let item = change.item else { continue }
                    let key = bucketKey(for: item.capturedAt)
                    touched.insert(key)
                    var bucket = items[key] ?? []
                    if let index = bucket.firstIndex(where: { $0.id == item.id }) {
                        bucket[index] = item
                    } else if items[key] != nil {
                        bucket.append(item)
                    }
                    if items[key] != nil {
                        items[key] = bucket.sorted { $0.capturedAt > $1.capturedAt }
                    }
                case .delete:
                    for (key, bucket) in items where bucket.contains(where: { $0.id == change.entityID }) {
                        items[key] = bucket.filter { $0.id != change.entityID }
                        touched.insert(key)
                    }
                }
            }

            cursor = delta.cursor
            // Counts and bucket membership changed; the manifest is cheap.
            await load()
        } catch {
            // A failed refresh leaves the existing timeline intact on purpose —
            // a transient network blip should not blank the grid.
        }
    }

    private func bucketKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        switch zoom {
        case .year: formatter.dateFormat = "yyyy"
        case .month: formatter.dateFormat = "yyyy-MM"
        case .day: formatter.dateFormat = "yyyy-MM-dd"
        }
        return formatter.string(from: date)
    }
}
