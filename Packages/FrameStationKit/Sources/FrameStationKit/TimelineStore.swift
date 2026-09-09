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

    /// Oldest first, newest last — the presentation order.
    ///
    /// The server sends the manifest newest-first (and still does, so older app
    /// builds are untouched); the app reverses it here, in one place, so the
    /// whole library reads the way Apple's does: you land on the newest at the
    /// bottom and scroll up for older. Everything downstream — the sections, the
    /// fast-scrubber's fraction→date mapping, the viewer's swipe and next-video
    /// order — takes its order from this, so the flip lives here and nowhere
    /// else. Within a day, `loadBucket` and `refresh` order items to match.
    public var buckets: [TimelineBucket] { Array((manifest?.buckets ?? []).reversed()) }
    public var total: Int { manifest?.total ?? 0 }

    /// Whether anything on screen is still waiting for the NAS to render it.
    ///
    /// A photo arrives in the timeline before it has a thumbnail — derivation is
    /// a queue, and on a J4125 a 4K video can sit in it for a while. Until it
    /// finishes there is no thumbnail *and* no ThumbHash, so the tile is a grey
    /// rectangle, and the person guaranteed to be looking at it is whoever just
    /// uploaded.
    ///
    /// The server announces the derivation through the change log, so the only
    /// question is how soon the app asks. This is what lets it ask more often
    /// while there is something specific to wait for, and go back to its lazy
    /// cadence once there isn't. Short-circuits on the first one it finds.
    public var hasPendingDerivations: Bool {
        items.values.contains { bucket in
            bucket.contains { !$0.isDerived }
        }
    }

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

    /// Changes density, or leaves everything exactly as it was.
    ///
    /// This used to set `zoom`, empty `items` and *then* fetch — so a failed
    /// fetch left the grid contradicting itself. `load()` deliberately keeps the
    /// manifest it already has when a refresh fails, which is right for a
    /// network blip but wrong here: the result was the new zoom's column count
    /// and row height applied to the old zoom's buckets, with no items at all.
    /// Day headings laid out at year density, every tile a placeholder.
    ///
    /// Fetching first and swapping all of it together means a failure is simply
    /// a zoom that didn't happen.
    public func setZoom(_ newZoom: TimelineZoom) async {
        guard newZoom != zoom else { return }
        do {
            let fresh = try await client.timeline(spaceID: spaceID, zoom: newZoom)
            items.removeAll()
            manifest = fresh
            cursor = fresh.cursor
            state = .loaded
            isFromSnapshot = false
            // Last, deliberately. `zoom` is what observers watch to know the
            // density changed, and anything reacting to it — restoring the
            // scroll anchor, most of all — needs the new buckets already in
            // place when it looks.
            zoom = newZoom
            scheduleSnapshot()
        } catch {
            // Nothing moved. The caller's anchor is still valid, and the grid
            // the user is looking at is still the one they were reading.
        }
    }

    /// Idempotent and de-duplicated — safe to call from `onAppear` on every cell.
    public func loadBucket(_ key: String) async {
        guard items[key] == nil, !loadingBuckets.contains(key) else { return }
        loadingBuckets.insert(key)
        defer { loadingBuckets.remove(key) }

        do {
            let page = try await client.bucket(spaceID: spaceID, key: key, zoom: zoom)
            // Reversed to oldest-first, to match `buckets` and the way the grid
            // now reads a day forward. The server still sends within-day
            // newest-first; the flip is the client's, in one direction, here.
            items[key] = Array(page.items.reversed())
            scheduleSnapshot()
        } catch {
            // Leave the day unloaded on failure rather than caching an empty
            // result. `items[key] == nil` is exactly what lets the section's
            // `.task` fetch it again the next time it scrolls into view, so a
            // one-off blip on a single day heals itself instead of stranding
            // that day as blank tiles until the app relaunches — which is how
            // the oldest day once sat empty on a phone while every other device
            // had it. Only a successful fetch records items here; a genuinely
            // empty day is the server saying so, not a dropped request. (A
            // restored snapshot's items are untouched for the same reason —
            // nothing overwrites them on a failed refetch.)
            _ = error
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
                        // Oldest-first, matching `loadBucket` and `buckets`.
                        items[key] = bucket.sorted { $0.capturedAt < $1.capturedAt }
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
