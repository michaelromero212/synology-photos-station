import FrameStationAPI
import XCTest

/// The arithmetic behind "stay where you were when the density changes".
///
/// Worth testing rather than eyeballing: the mapping is string-prefix work over
/// three key shapes, and getting it wrong doesn't crash — it silently returns
/// you to the top of the library, which is exactly the bug it exists to fix.
final class BucketAnchorTests: XCTestCase {
    private func buckets(_ pairs: [(String, Int)]) -> [TimelineBucket] {
        pairs.map { TimelineBucket(key: $0.0, count: $0.1, place: nil) }
    }

    private let days = [
        ("2026-08-12", 3), ("2026-08-11", 10), ("2012-06-14", 40), ("2012-06-02", 5),
    ]
    private let months = [("2026-08", 13), ("2012-06", 45)]
    private let years = [("2026", 13), ("2012", 45)]

    // MARK: - Zooming out

    func testDayAnchorsToItsMonth() {
        XCTAssertEqual(buckets(months).counterpart(of: "2012-06-14"), "2012-06")
    }

    func testDayAnchorsToItsYear() {
        XCTAssertEqual(buckets(years).counterpart(of: "2012-06-14"), "2012")
    }

    func testMonthAnchorsToItsYear() {
        XCTAssertEqual(buckets(years).counterpart(of: "2012-06"), "2012")
    }

    // MARK: - Zooming in

    /// Newest-first ordering means the first match is the most recent day in
    /// that year — the edge of the year you were nearest.
    func testYearAnchorsToItsNewestDay() {
        XCTAssertEqual(buckets(days).counterpart(of: "2012"), "2012-06-14")
    }

    func testMonthAnchorsToItsNewestDay() {
        XCTAssertEqual(buckets(days).counterpart(of: "2012-06"), "2012-06-14")
    }

    // MARK: - Degenerate cases

    func testExactKeySurvivesUnchanged() {
        XCTAssertEqual(buckets(days).counterpart(of: "2026-08-11"), "2026-08-11")
    }

    /// A library that no longer contains the anchor — the photos were removed
    /// while you were zoomed out — must not land you anywhere arbitrary.
    func testMissingAnchorReturnsNil() {
        XCTAssertNil(buckets(years).counterpart(of: "1999-01-01"))
    }

    func testEmptyLibraryReturnsNil() {
        XCTAssertNil([TimelineBucket]().counterpart(of: "2012"))
    }

    /// `2012` must not be dragged into `2012-06` by a careless contains-check,
    /// and a year key must never match a *different* year that shares digits.
    func testYearDoesNotMatchAnUnrelatedYear() {
        XCTAssertNil(buckets([("2020", 1), ("2021", 1)]).counterpart(of: "2012"))
    }

    // MARK: - Weighted position

    /// Weighted by count, so the busy bucket owns most of the range.
    func testFractionIsWeightedByItemCount() {
        let list = buckets([("2026-08-12", 1), ("2026-08-11", 99)])
        XCTAssertEqual(list.bucket(atFraction: 0.0)?.key, "2026-08-12")
        XCTAssertEqual(list.bucket(atFraction: 0.5)?.key, "2026-08-11")
        XCTAssertEqual(list.bucket(atFraction: 1.0)?.key, "2026-08-11")
    }

    func testFractionClampsOutOfRangeInput() {
        let list = buckets(days)
        XCTAssertEqual(list.bucket(atFraction: -5)?.key, "2026-08-12")
        XCTAssertEqual(list.bucket(atFraction: 5)?.key, "2012-06-02")
    }

    /// Empty buckets still occupy a slot — `max(count, 1)` — so a library of
    /// them doesn't divide by zero or collapse to one reachable section.
    func testZeroCountBucketsAreStillReachable() {
        let list = buckets([("2026", 0), ("2025", 0)])
        XCTAssertEqual(list.bucket(atFraction: 0.0)?.key, "2026")
        XCTAssertEqual(list.bucket(atFraction: 1.0)?.key, "2025")
    }
}
