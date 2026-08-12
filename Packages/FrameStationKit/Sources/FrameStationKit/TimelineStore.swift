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
    private var snapshotTask: Task<Void, Never>?
    /// Whether what's on screen came off the disk rather than the server. The
    /// grid uses this to stop asking for buckets that cannot arrive.
    public private(set) var isFromSnapshot = false

    public init(client: FrameStationClient, spaceID: UUID, zoom: TimelineZoom = .day) {
        self.client = client
        self.spaceID = spaceID
        self.zoom = zoom
    }

    public var buckets: [TimelineBucket] { manifest?.buckets ?? [] }
    public var total: Int { manifest?.total ?? 0 }

    /// Fetches the manifest.
    ///
    /// Only *announces* loading when there is nothing on screen yet, and that
    /// distinction is the difference between a timeline that updates itself and
    /// one that can't afford to. `refresh()` ends by calling this to pick up new
    /// bucket counts, so with an unconditional `state = .loading` every delta
    /// replaced the entire grid with a spinner and then rebuilt it — survivable
    /// once, on a deliberate pull, and unusable on a timer.
    ///
    /// The failure path is guarded for the same reason the one in `refresh()`
    /// is: a blip on a background poll must not throw away a library the user is
    /// looking at and put an error in its place.
    public func load() async {
        let isFirstLoad = manifest == nil
        if isFirstLoad { state = .loading }
        do {
            let manifest = try await client.timeline(spaceID: spaceID, zoom: zoom)
            self.manifest = manifest
            self.cursor = manifest.cursor
            self.state = .loaded
            self.isFromSnapshot = false
            scheduleSnapshot()
        } catch {
            guard isFirstLoad else { return }
            // Nothing in memory and nothing on the wire — but there may still
            // be the last timeline this device saw. Showing that beats showing
            // an error page over a library the user knows perfectly well
            // exists, and the connection banner already says why the pictures
            // are missing.
            if restoreSnapshot() { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// Returns false when there is nothing stored to fall back to.
    @discardableResult
    private func restoreSnapshot() -> Bool {
        guard let snapshot = TimelineSnapshotStore.load(spaceID: spaceID, zoom: zoom)
        else { return false }
        manifest = snapshot.manifest
        items = snapshot.items
        cursor = snapshot.cursor
        state = .loaded
        isFromSnapshot = true
        return true
    }

    /// Coalesces writes.
    ///
    /// Every bucket that scrolls into view would otherwise re-encode the whole
    /// snapshot; a fling through a year would do it dozens of times for a file
    /// only the next cold launch reads.
    private func scheduleSnapshot() {
        guard let manifest else { return }
        snapshotTask?.cancel()
        let items = items
        let cursor = cursor
        let spaceID = spaceID
        let zoom = zoom
        snapshotTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            TimelineSnapshotStore.save(
                manifest: manifest, items: items, cursor: cursor,
                spaceID: spaceID, zoom: zoom
            )
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
            scheduleSnapshot()
        } catch {
            // Only claim the bucket is empty when the server said so. Writing
            // `[]` after a network failure is what turns a restored snapshot
            // into a grid of blank tiles: the day already has items from disk,
            // and a failed fetch would throw them away and cache the loss.
            if items[key] == nil, !isFromSnapshot { items[key] = [] }
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
            // Whether any bucket gained or lost an item, as opposed to an item
            // being replaced where it already sat. See the manifest refetch
            // below — this is the difference between the two.
            var membershipMoved = false

            for change in delta.changes {
                switch change.op {
                case .insert, .update:
                    guard let item = change.item else { continue }
                    let key = bucketKey(for: item.capturedAt)
                    touched.insert(key)
                    var bucket = items[key] ?? []
                    if let index = bucket.firstIndex(where: { $0.id == item.id }) {
                        bucket[index] = item
                    } else {
                        // Either genuinely new, or re-dated out of another
                        // bucket and into this one. Both change the counts.
                        membershipMoved = true
                        if items[key] != nil { bucket.append(item) }
                    }
                    if items[key] != nil {
                        items[key] = bucket.sorted { $0.capturedAt > $1.capturedAt }
                    }
                case .delete:
                    membershipMoved = true
                    for (key, bucket) in items where bucket.contains(where: { $0.id == change.entityID }) {
                        items[key] = bucket.filter { $0.id != change.entityID }
                        touched.insert(key)
                    }
                }
            }

            cursor = delta.cursor

            // Only when membership actually moved.
            //
            // `load()` replaces the manifest, and the grid builds its sections
            // from that — so every call re-identifies the whole `LazyVStack`.
            // Done while somebody is scrolled into the middle of a library, that
            // can strand the scroll position past the end of the rebuilt content
            // and leave them looking at nothing.
            //
            // It used to be rare enough not to matter, because only real inserts
            // and deletes produced a delta. Now a finished thumbnail produces one
            // too — that is the whole point of announcing derivations — and an
            // update in place changes neither bucket membership nor any count,
            // so there is nothing in the manifest for it to refresh.
            if membershipMoved { await load() }
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
