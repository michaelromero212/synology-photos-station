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
    /// finishes there is no thumbnail *and* no ThumbHash, so the tile is a gray
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
        if isFirstLoad {
            // Paint the last library this device saw *before* asking the
            // network for this one, rather than only if the ask fails.
            //
            // The snapshot holds the items, and their thumbnails are already in
            // the on-disk cache from previous runs, so restoring it puts real
            // photographs on screen at once. Waiting for the network instead
            // meant a cold launch went spinner → a grid of gray tiles → photos:
            // the manifest arrives first and only knows the day names and how
            // many, so the grid can draw the shape of the library a beat before
            // it can draw any of it. Caught in three frames of a screen
            // recording, which is exactly how it looks next to Synology's,
            // where the pictures are simply there.
            //
            // Stale for the moment it takes the fetch below to answer, and then
            // replaced. For a photo library that is the right trade: last
            // night's grid is a far better thing to show than a gray one.
            if !restoreSnapshot() { state = .loading }
        }
        do {
            let manifest = try await client.timeline(spaceID: spaceID, zoom: zoom)
            self.manifest = manifest
            adoptCursor(from: manifest)
            self.state = .loaded
            self.isFromSnapshot = false
            scheduleSnapshot()
            revalidateStaleBuckets()
        } catch {
            guard isFirstLoad else { return }
            // Nothing on the wire. If the snapshot above is on screen it stays
            // there — showing that beats showing an error page over a library
            // the user knows perfectly well exists, and the connection banner
            // already says why the pictures are missing.
            if isFromSnapshot { return }
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

    /// Decides where delta sync resumes once a manifest arrives.
    ///
    /// The cursor records which changes the days in memory already reflect,
    /// and that is what it has to keep meaning. It used to be set to the
    /// manifest's on every load, which skipped everything in between: a cold
    /// launch restores last night's days at last night's cursor, the fresh
    /// manifest jumped it to now, and whatever was deleted, re-dated or
    /// finished deriving while the app was closed never reached the days on
    /// screen. Nothing refetches a day that is already loaded, so a restored
    /// day kept its deleted photos and its gray tiles for good.
    ///
    /// So with days in memory the cursor stays where it is, and `refresh()`
    /// replays the gap. Only with nothing loaded — nothing to replay onto —
    /// does it start from the server's position.
    ///
    /// A server *behind* the cursor has had its database rebuilt or restored,
    /// and its sequence started over. The days in memory belong to a history
    /// that no longer exists, so they go, and the cursor follows the server —
    /// otherwise `since=` would point past the end of the new log and never see
    /// another change.
    private func adoptCursor(from manifest: TimelineManifest) {
        if cursor > manifest.cursor { items.removeAll() }
        if items.isEmpty { cursor = manifest.cursor }
    }

    /// Re-fetches the loaded days the server now counts differently.
    ///
    /// The backstop behind delta sync. A day stays in memory for as long as
    /// the session does, so a change that never arrived — or arrived and was
    /// misapplied — used to stay wrong for as long, and the saved snapshot
    /// carried it into the next launch too: a deleted photo still on screen,
    /// a re-dated one on two days at once. Comparing counts catches every such
    /// drift without knowing what caused it, and costs one lookup per loaded
    /// day each time the manifest is fetched.
    ///
    /// In place, day by day, never by emptying first — a day being refetched
    /// keeps showing what it had until the replacement lands, so a heal is
    /// never a flash of placeholders.
    private func revalidateStaleBuckets() {
        guard let manifest else { return }
        let known = Set(manifest.buckets.map(\.key))
        let stale = Self.staleBuckets(in: manifest, items: items)
        // A day the server no longer has at all needs no fetch: it's gone.
        for key in stale where !known.contains(key) { items[key] = nil }
        let refetch = stale.filter { known.contains($0) }
        guard !refetch.isEmpty else { return }
        let zoom = self.zoom
        revalidation = Task { [weak self] in
            for key in refetch {
                guard let self, self.zoom == zoom else { return }
                await self.reloadBucket(key)
            }
        }
    }

    /// The pass `revalidateStaleBuckets` started, if one is running. Held so
    /// tests can wait for it; nothing in the app needs to.
    @ObservationIgnored var revalidation: Task<Void, Never>?

    /// Fetches a day that is already loaded and swaps its contents.
    private func reloadBucket(_ key: String) async {
        guard !loadingBuckets.contains(key) else { return }
        loadingBuckets.insert(key)
        defer { loadingBuckets.remove(key) }
        let zoom = self.zoom
        do {
            let page = try await client.bucket(spaceID: spaceID, key: key, zoom: zoom)
            // A density change while this was in flight replaced every day.
            guard zoom == self.zoom else { return }
            items[key] = Array(page.items.reversed())
            scheduleSnapshot()
        } catch {
            // Keep what is there; the next manifest asks again.
        }
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
    /// Applied idempotently on purpose: the server serializes `change_log`
    /// sequence assignment per space, but a client that replays a range after a
    /// dropped connection must not double-insert.
    ///
    /// Every page, not just the first. The server hands changes out five
    /// hundred at a time and says when there are more, and this used to take
    /// one page and move on — after which the manifest reload jumped the
    /// cursor past the rest. An evening's backup from another phone is easily
    /// a thousand changes (each photo arrives, then its thumbnail finishes), so
    /// the tail of it simply never arrived: photos missing from days already
    /// on screen, and tiles that stayed gray because the "thumbnail finished"
    /// update was in a page nobody fetched.
    public func refresh() async {
        if manifest == nil {
            await load()
            // A first load that put last night's days back on screen resumes
            // from last night's cursor — see `adoptCursor`. Replay what changed
            // since now, rather than waiting for the next thing to ask.
            guard let manifest, cursor < manifest.cursor else { return }
        }

        let zoom = self.zoom
        // Whether any day gained or lost an item, as opposed to an item being
        // replaced where it already sat. See the manifest refetch below — this
        // is the difference between the two.
        var membershipMoved = false
        var appliedAny = false
        var pages = 0
        do {
            while true {
                let delta = try await client.changes(spaceID: spaceID, since: cursor)
                // A density change while this was in flight replaced every day
                // these would be filed under, and reloaded them from scratch.
                guard zoom == self.zoom else { return }
                if !delta.changes.isEmpty {
                    let applied = Self.applying(delta.changes, to: items, zoom: zoom)
                    items = applied.items
                    membershipMoved = membershipMoved || applied.membershipMoved
                    appliedAny = true
                }
                cursor = delta.cursor
                pages += 1
                guard delta.hasMore else { break }
                guard pages < Self.maximumReplayPages else {
                    // Too far behind to be worth replaying change by change —
                    // weeks away, or a whole library imported meanwhile. Start
                    // over from the server's position instead: the days on
                    // screen go, and the ones scrolled back into view load fresh.
                    items.removeAll()
                    await load()
                    return
                }
            }
        } catch {
            // A failed page leaves the timeline intact on purpose — a transient
            // network blip should not blank the grid. Whatever pages did arrive
            // are applied, and the cursor stays where they got to.
        }
        guard appliedAny else { return }

        // Only when membership actually moved.
        //
        // `load()` replaces the manifest, and the grid builds its sections
        // from that — so every call re-identifies the whole grid. Done while
        // somebody is scrolled into the middle of a library, that can strand
        // the scroll position past the end of the rebuilt content and leave
        // them looking at nothing.
        //
        // It used to be rare enough not to matter, because only real inserts
        // and deletes produced a delta. Now a finished thumbnail produces one
        // too — that is the whole point of announcing derivations — and an
        // update in place changes neither bucket membership nor any count, so
        // there is nothing in the manifest for it to refresh.
        if membershipMoved {
            await load()
        } else {
            // Write the delta down, or the next cold start undoes it.
            //
            // This is what made thumbnails come back and then leave again.
            // Snapshots were saved by `load` and `loadBucket` — the paths that
            // *fetch* — and never by the one that applies changes. An in-place
            // update deliberately does not reload (it moves nothing and changes
            // no counts), so the most important update there is, "the NAS has
            // finished this thumbnail", lived only in memory.
            //
            // The grid therefore healed itself while the app was open and
            // forgot every time it was killed: cold launch restores the
            // snapshot taken *before* derivation landed, the tile is gray
            // because `isDerived` is false, the delta arrives a moment later
            // and fills it, and the cycle repeats forever because that
            // correction is never the thing being saved.
            scheduleSnapshot()
        }
    }

    /// How many pages of changes `refresh()` replays before deciding a fresh
    /// start is cheaper. Five hundred changes a page.
    static let maximumReplayPages = 10

    // MARK: - Applying changes

    /// One page of `/changes`, applied to the days held in memory.
    ///
    /// A pure function of its inputs so the rules can be tested without a
    /// server, which is where the last bug in here hid: a re-dated photo
    /// arrives as an update filed under its *new* day, and this used to put it
    /// there without taking it out of the old one. It then sat on both days —
    /// on every device, including the one that made the edit — and because a
    /// loaded day is never refetched and the snapshot saves what is in memory,
    /// it stayed on both across relaunches too.
    ///
    /// Days that aren't loaded are left unloaded: the change is reflected when
    /// that day is fetched. `membershipMoved` reports whether any day's count
    /// may have changed, which is what decides whether the manifest is fetched
    /// again.
    nonisolated static func applying(
        _ changes: [SpaceChange],
        to days: [String: [TimelineItem]],
        zoom: TimelineZoom
    ) -> (items: [String: [TimelineItem]], membershipMoved: Bool) {
        var days = days
        var membershipMoved = false
        for change in changes {
            switch change.op {
            case .insert, .update:
                // No item means the placement is no longer something the grid
                // shows — deleted since, or a Live Photo's hidden half.
                guard let item = change.item else { continue }
                let key = bucketKey(for: item.capturedAt, zoom: zoom)

                // Out of any other day first. A re-dated photo is the same
                // placement under a new capture time; it belongs to exactly
                // one day, and that is the new one.
                for (other, held) in days where other != key {
                    guard held.contains(where: { $0.id == item.id }) else { continue }
                    days[other] = held.filter { $0.id != item.id }
                    membershipMoved = true
                }

                guard var held = days[key] else {
                    // Not loaded. New here or moved here, either way this
                    // day's count changed.
                    membershipMoved = true
                    continue
                }
                if let index = held.firstIndex(where: { $0.id == item.id }) {
                    held[index] = item
                } else {
                    // Either genuinely new, or re-dated into this day.
                    membershipMoved = true
                    held.append(item)
                }
                // Oldest-first, matching `loadBucket` and `buckets` — to the
                // millisecond, so photos taken within the same second land in
                // the order they were taken rather than the order they arrived.
                days[key] = held.sorted { $0.preciseCapturedAt < $1.preciseCapturedAt }

            case .delete:
                membershipMoved = true
                for (key, held) in days where held.contains(where: { $0.id == change.entityID }) {
                    days[key] = held.filter { $0.id != change.entityID }
                }
            }
        }
        return (days, membershipMoved)
    }

    /// Loaded days whose item count no longer matches the manifest's —
    /// including days the manifest no longer lists at all.
    nonisolated static func staleBuckets(
        in manifest: TimelineManifest, items: [String: [TimelineItem]]
    ) -> [String] {
        var counts: [String: Int] = [:]
        for bucket in manifest.buckets { counts[bucket.key] = bucket.count }
        return items
            .filter { key, held in held.count != (counts[key] ?? 0) }
            .map(\.key)
            .sorted()
    }

    /// The manifest's key for the day, month or year a capture time falls in.
    ///
    /// Formatted in UTC because the server sends capture times as the local
    /// wall clock labelled UTC — the same convention its `to_char` keys use.
    nonisolated static func bucketKey(for date: Date, zoom: TimelineZoom) -> String {
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
