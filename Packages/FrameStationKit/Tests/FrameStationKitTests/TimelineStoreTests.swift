import Foundation
import FrameStationAPI
import Testing
@testable import FrameStationKit

// Delta sync is where a timeline quietly drifts from the library it shows: a
// change applied to the wrong day, or never applied at all, doesn't crash
// anything. It just leaves a photo somewhere it isn't — and because a loaded
// day is never refetched and the snapshot saves what is in memory, it stays
// there across launches. These pin the rules that keep it honest.

private let day = "2025-06-15"
private let nextDay = "2025-06-16"

private func at(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

private func photo(_ id: UUID, _ iso: String, derived: Bool = true, space: UUID = UUID()) -> TimelineItem {
    TimelineItem(
        id: id, spaceID: space, assetID: id, capturedAt: at(iso), aspectRatio: 1,
        mediaType: .photo, durationMs: nil, thumbHash: nil, isFavorite: false,
        uploadedBy: UUID(), isDerived: derived
    )
}

private func change(_ seq: Int64, _ op: ChangeOperation, _ item: TimelineItem) -> SpaceChange {
    SpaceChange(seq: seq, op: op, entityID: item.id, item: op == .delete ? nil : item)
}

@Suite("Changes land on the right day")
struct TimelineChangeApplicationTests {
    @Test("A re-dated photo moves to its new day instead of appearing on both")
    func redatedPhotoMoves() {
        let a = UUID(), b = UUID(), c = UUID()
        let held = [
            day: [photo(a, "2025-06-15T09:00:00Z"), photo(b, "2025-06-15T10:00:00Z")],
            nextDay: [photo(c, "2025-06-16T08:00:00Z")],
        ]
        let redated = photo(a, "2025-06-16T12:00:00Z")

        let result = TimelineStore.applying([change(9, .update, redated)], to: held, zoom: .day)

        #expect(result.items[day]?.map(\.id) == [b])
        #expect(result.items[nextDay]?.map(\.id) == [c, a])
        #expect(result.membershipMoved)
    }

    @Test("An update in place keeps its day and moves nothing")
    func updateInPlace() {
        let a = UUID(), b = UUID()
        let held = [day: [photo(a, "2025-06-15T09:00:00Z", derived: false),
                          photo(b, "2025-06-15T10:00:00Z")]]

        let result = TimelineStore.applying(
            [change(4, .update, photo(a, "2025-06-15T09:00:00Z", derived: true))],
            to: held, zoom: .day
        )

        #expect(result.items[day]?.map(\.id) == [a, b])
        #expect(result.items[day]?.first?.isDerived == true)
        #expect(!result.membershipMoved)
    }

    @Test("A change to a day that isn't loaded leaves it unloaded, but counts")
    func unloadedDayStaysUnloaded() {
        let result = TimelineStore.applying(
            [change(2, .insert, photo(UUID(), "2025-06-16T09:00:00Z"))], to: [:], zoom: .day
        )
        #expect(result.items.isEmpty)
        #expect(result.membershipMoved)
    }

    @Test("A new photo is filed in capture order, not arrival order")
    func insertKeepsCaptureOrder() {
        let early = UUID(), late = UUID(), middle = UUID()
        let held = [day: [photo(early, "2025-06-15T08:00:00Z"), photo(late, "2025-06-15T18:00:00Z")]]

        let result = TimelineStore.applying(
            [change(7, .insert, photo(middle, "2025-06-15T12:00:00Z"))], to: held, zoom: .day
        )

        #expect(result.items[day]?.map(\.id) == [early, middle, late])
        #expect(result.membershipMoved)
    }

    @Test("A delete takes the photo out of whichever day holds it")
    func deleteRemoves() {
        let a = UUID(), b = UUID()
        let held = [day: [photo(a, "2025-06-15T09:00:00Z")], nextDay: [photo(b, "2025-06-16T09:00:00Z")]]

        let result = TimelineStore.applying(
            [SpaceChange(seq: 3, op: .delete, entityID: b, item: nil)], to: held, zoom: .day
        )

        #expect(result.items[day]?.map(\.id) == [a])
        #expect(result.items[nextDay]?.isEmpty == true)
        #expect(result.membershipMoved)
    }

    @Test("A change with no item — deleted since, or a Live Photo's hidden half — is skipped")
    func missingItemIsSkipped() {
        let a = UUID()
        let held = [day: [photo(a, "2025-06-15T09:00:00Z")]]
        let result = TimelineStore.applying(
            [SpaceChange(seq: 5, op: .update, entityID: UUID(), item: nil)], to: held, zoom: .day
        )
        #expect(result.items == held)
        #expect(!result.membershipMoved)
    }

    @Test("Keys match the server's to_char keys at every zoom")
    func bucketKeys() {
        let late = at("2025-06-15T23:59:59Z")
        #expect(TimelineStore.bucketKey(for: late, zoom: .day) == "2025-06-15")
        #expect(TimelineStore.bucketKey(for: late, zoom: .month) == "2025-06")
        #expect(TimelineStore.bucketKey(for: late, zoom: .year) == "2025")
    }
}

@Suite("Loaded days are checked against the server's counts")
struct TimelineStaleBucketTests {
    private func manifest(_ counts: [(String, Int)]) -> TimelineManifest {
        TimelineManifest(
            spaceID: UUID(), zoom: .day, total: counts.reduce(0) { $0 + $1.1 }, cursor: 1,
            buckets: counts.map { TimelineBucket(key: $0.0, count: $0.1, place: nil) }
        )
    }

    @Test("A day holding a different number of photos than the server counts is stale")
    func countMismatch() {
        let held = [day: [photo(UUID(), "2025-06-15T09:00:00Z"), photo(UUID(), "2025-06-15T10:00:00Z")]]
        #expect(TimelineStore.staleBuckets(in: manifest([(day, 1)]), items: held) == [day])
    }

    @Test("A day the server no longer lists is stale")
    func vanishedDay() {
        let held = [day: [photo(UUID(), "2025-06-15T09:00:00Z")]]
        #expect(TimelineStore.staleBuckets(in: manifest([(nextDay, 3)]), items: held) == [day])
    }

    @Test("Days that agree, and days not loaded at all, are left alone")
    func agreementIsQuiet() {
        let held = [day: [photo(UUID(), "2025-06-15T09:00:00Z")]]
        #expect(TimelineStore.staleBuckets(in: manifest([(day, 1), (nextDay, 40)]), items: held).isEmpty)
    }
}

// MARK: - Against a server

/// A FrameStation server made of queued answers: each request path takes the
/// next response filed under it. Anything unanswered is a 404, which the store
/// treats like any failed request.
final class StubServer: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queued: [String: [Data]] = [:]
    nonisolated(unsafe) private static var log: [String] = []

    static func answer<Body: Encodable>(_ path: String, with body: Body) {
        let data = try! FrameStationCoding.encoder.encode(body)
        lock.lock(); defer { lock.unlock() }
        queued[path, default: []].append(data)
    }

    static func requests(matching fragment: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return log.filter { $0.contains(fragment) }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path + (url.query.map { "?" + $0 } ?? "")
        Self.lock.lock()
        Self.log.append(path)
        let body = Self.queued[path]?.isEmpty == false ? Self.queued[path]?.removeFirst() : nil
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Delta sync catches up rather than skipping ahead", .serialized)
@MainActor
struct TimelineSyncTests {
    let space = UUID()

    private var client: FrameStationClient {
        FrameStationClient(
            configuration: .init(baseURL: URL(string: "https://nas.test")!, token: "token"),
            session: StubServer.session()
        )
    }

    private func manifest(cursor: Int64, count: Int) -> TimelineManifest {
        TimelineManifest(
            spaceID: space, zoom: .day, total: count, cursor: cursor,
            buckets: [TimelineBucket(key: day, count: count, place: nil)]
        )
    }

    private var timelinePath: String { "/v1/spaces/\(space)/timeline?zoom=day" }
    private var dayPath: String { "/v1/spaces/\(space)/timeline/\(day)?zoom=day" }
    private func changesPath(since: Int64) -> String {
        "/v1/spaces/\(space)/changes?since=\(since)&limit=500"
    }

    @Test("Refresh follows every page of changes, not just the first")
    func followsEveryPage() async {
        let a = UUID(), b = UUID()
        StubServer.answer(timelinePath, with: manifest(cursor: 10, count: 1))
        StubServer.answer(dayPath, with: TimelineBucketPage(
            key: day, zoom: .day, items: [photo(a, "2025-06-15T09:00:00Z", derived: false, space: space)]
        ))
        StubServer.answer(changesPath(since: 10), with: SpaceChanges(
            cursor: 11, hasMore: true,
            changes: [change(11, .insert, photo(b, "2025-06-15T10:00:00Z", space: space))]
        ))
        // The second page is the one that used to be skipped: the thumbnail
        // for the photo already on screen finishing.
        StubServer.answer(changesPath(since: 11), with: SpaceChanges(
            cursor: 12, hasMore: false,
            changes: [change(12, .update, photo(a, "2025-06-15T09:00:00Z", derived: true, space: space))]
        ))
        StubServer.answer(timelinePath, with: manifest(cursor: 12, count: 2))

        let store = TimelineStore(client: client, spaceID: space)
        await store.refresh()
        await store.loadBucket(day)
        await store.refresh()
        await store.revalidation?.value

        #expect(store.cursor == 12)
        #expect(store.items[day]?.map(\.id) == [a, b])
        #expect(store.items[day]?.first?.isDerived == true)
        #expect(StubServer.requests(matching: "/changes?since=11").count == 1)
    }

    @Test("Days restored from disk replay what changed while the app was closed")
    func restoredDaysReplayTheGap() async {
        let a = UUID(), b = UUID()
        TimelineSnapshotStore.save(
            manifest: manifest(cursor: 5, count: 2),
            items: [day: [photo(a, "2025-06-15T09:00:00Z", derived: false, space: space),
                          photo(b, "2025-06-15T10:00:00Z", space: space)]],
            cursor: 5, spaceID: space, zoom: .day
        )
        StubServer.answer(timelinePath, with: manifest(cursor: 7, count: 1))
        StubServer.answer(changesPath(since: 5), with: SpaceChanges(
            cursor: 7, hasMore: false,
            changes: [
                SpaceChange(seq: 6, op: .delete, entityID: b, item: nil),
                change(7, .update, photo(a, "2025-06-15T09:00:00Z", derived: true, space: space)),
            ]
        ))
        StubServer.answer(timelinePath, with: manifest(cursor: 7, count: 1))
        // The count check refetches the day as well; it agrees with the replay.
        StubServer.answer(dayPath, with: TimelineBucketPage(
            key: day, zoom: .day, items: [photo(a, "2025-06-15T09:00:00Z", derived: true, space: space)]
        ))

        let store = TimelineStore(client: client, spaceID: space)
        await store.refresh()
        await store.revalidation?.value

        #expect(store.cursor == 7)
        #expect(store.items[day]?.map(\.id) == [a])
        #expect(store.items[day]?.first?.isDerived == true)
        #expect(StubServer.requests(matching: changesPath(since: 5)).count == 1)
    }

    @Test("A server whose change log started over resets the days it can no longer update")
    func rebuiltServerResets() async {
        TimelineSnapshotStore.save(
            manifest: manifest(cursor: 50, count: 1),
            items: [day: [photo(UUID(), "2025-06-15T09:00:00Z", space: space)]],
            cursor: 50, spaceID: space, zoom: .day
        )
        StubServer.answer(timelinePath, with: manifest(cursor: 3, count: 1))

        let store = TimelineStore(client: client, spaceID: space)
        await store.refresh()

        #expect(store.cursor == 3)
        #expect(store.items.isEmpty)
    }
}
