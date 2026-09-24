import FrameStationKit
import XCTest

/// The arithmetic the scrubber steers by.
///
/// Worth testing rather than eyeballing, because every way of getting it wrong
/// looks plausible on screen. Aim at the wrong day and the grid still moves, and
/// still moves in roughly the right direction — it just stops agreeing with the
/// finger, which is the exact complaint this code exists to answer. The ends are
/// worse: an off-by-one-screen at the bottom reads as "the last few days can't
/// be reached", and nothing about that says arithmetic.
final class LibrarySpanTests: XCTestCase {
    /// A library of days of a given height, laid out head to tail.
    private func span(_ heights: [Double], header: Double = 34) -> LibrarySpan {
        var start: [String: Double] = [:]
        var height: [String: Double] = [:]
        var order: [String] = []
        var running: Double = 0
        for (i, h) in heights.enumerated() {
            let key = String(format: "day-%03d", i)
            start[key] = running
            height[key] = h
            order.append(key)
            running += h
        }
        return LibrarySpan(
            total: running, start: start, height: height,
            order: order, header: header
        )
    }

    private let screen: Double = 800

    // MARK: - Naming the day

    func testTheTopOfTheTrackIsTheOldestDay() {
        let library = span(Array(repeating: 200, count: 50))
        XCTAssertEqual(
            library.target(atFraction: 0, viewport: screen)?.day, "day-000"
        )
    }

    func testTheBottomOfTheTrackIsTheLastScreen() {
        // Not the last *day*: at the bottom of the track the final screen is on
        // screen, so the day named is the one a screen short of the end.
        let library = span(Array(repeating: 200, count: 50))
        let target = library.target(atFraction: 1, viewport: screen)
        // 50 days of 200 is 10,000; less one 800-point screen is 9,200, which
        // falls in day 46 (9,200 / 200).
        XCTAssertEqual(target?.day, "day-046")
    }

    func testTheDayIsChosenByHeightRatherThanByCount() {
        // One enormous day at the head, then a run of small ones. Halfway down
        // the track is still inside the big day even though almost every
        // *photograph* after it lives in the small ones.
        let library = span([6000] + Array(repeating: 100, count: 40))
        let target = library.target(atFraction: 0.25, viewport: screen)
        XCTAssertEqual(target?.day, "day-000")
    }

    func testAFractionPastTheEndsIsHeldAtThem() {
        let library = span(Array(repeating: 200, count: 10))
        XCTAssertEqual(
            library.target(atFraction: -3, viewport: screen)?.day, "day-000"
        )
        XCTAssertEqual(
            library.target(atFraction: 7, viewport: screen)?.day,
            library.target(atFraction: 1, viewport: screen)?.day
        )
    }

    // MARK: - Landing inside the day

    func testATallDayIsSweptThrough() {
        // The case that used to lurch worst: one day several screens tall. Two
        // nearby points on the track must land on that day at two different
        // depths, not both at its heading.
        let library = span([8000] + Array(repeating: 100, count: 20))
        let near = library.target(atFraction: 0.20, viewport: screen)
        let far = library.target(atFraction: 0.30, viewport: screen)
        XCTAssertEqual(near?.rows, "day-000")
        XCTAssertEqual(far?.rows, "day-000")
        XCTAssertGreaterThan(far!.unit, near!.unit)
    }

    func testEqualThumbMovementIsEqualGridMovement() {
        // What "smooth" means, stated as arithmetic: three evenly spaced points
        // on the track must resolve to three evenly spaced points in the
        // library. The grid is then put there by `scrollTo`, so if this holds
        // and the anchor is honoured, the drag cannot lurch.
        let library = span([12000], header: 34)
        let travel = library.total - screen
        let points = [0.2, 0.4, 0.6].map { f -> Double in
            let t = library.target(atFraction: f, viewport: screen)!
            let begin = library.start[t.rows!]! + library.header
            let room = library.height[t.rows!]! - library.header - screen
            return begin + t.unit * room
        }
        XCTAssertEqual(points[0], 0.2 * travel, accuracy: 0.001)
        XCTAssertEqual(points[1], 0.4 * travel, accuracy: 0.001)
        XCTAssertEqual(points[2], 0.6 * travel, accuracy: 0.001)
    }

    func testAShortDayIsReachedThroughTheOneAfterIt() {
        // A day shorter than the screen cannot be scrolled *into* — the anchor
        // arithmetic runs backwards inside it. The wanted point is reached by
        // pulling a *later* day up instead, which is why the search looks ahead.
        let library = span(Array(repeating: 150, count: 60))
        let target = library.target(atFraction: 0.5, viewport: screen)!
        XCTAssertNotNil(target.rows)
        XCTAssertNotEqual(
            target.rows, target.day,
            "a short day should be reached through a later one"
        )
        // And it must still land where it was asked to.
        let begin = library.start[target.rows!]! + library.header
        let room = library.height[target.rows!]! - library.header - screen
        let landed = begin + target.unit * room
        XCTAssertEqual(landed, 0.5 * (library.total - screen), accuracy: 0.001)
    }

    func testTheAnchorStaysInsideTheViewItAnchors() {
        // `scrollTo` clamps an anchor to 0…1, so a target outside that range is
        // not a near miss — it is a jump to wherever the clamp lands, which is
        // how this went wrong the first time.
        let library = span(
            [3000] + Array(repeating: 120, count: 80) + [5000]
        )
        for step in 0...100 {
            let target = library.target(
                atFraction: Double(step) / 100, viewport: screen
            )
            guard let target, target.rows != nil else { continue }
            XCTAssertGreaterThanOrEqual(target.unit, 0)
            XCTAssertLessThanOrEqual(target.unit, 1)
        }
    }

    func testTheDayNeverGoesBackwardsAsTheThumbGoesDown() {
        // Monotonic, which the first two attempts at this were not: aiming at
        // the whole library by fraction gave a different answer depending on
        // where you had already been, so a steady drag wandered.
        let library = span(
            (0..<120).map { Double(80 + ($0 * 37) % 900) }
        )
        var last = ""
        for step in 0...200 {
            let target = library.target(
                atFraction: Double(step) / 200, viewport: screen
            )!
            XCTAssertGreaterThanOrEqual(target.day, last)
            last = target.day
        }
    }

    func testTheOffsetIsTheExactPointTheThumbAskedFor() {
        // What the collection-view grid scrolls to directly. It has to be the
        // thumb's own fraction of the travel — the library less one screen —
        // at every point, or the grid and the thumb disagree about where the
        // library ends.
        let library = span([900, 120, 4000, 300] + Array(repeating: 150, count: 30))
        let travel = library.total - screen
        for step in 0...20 {
            let fraction = Double(step) / 20
            let target = library.target(atFraction: fraction, viewport: screen)!
            XCTAssertEqual(target.offset, fraction * travel, accuracy: 0.001)
        }
    }

    // MARK: - Nothing to go on

    func testAnUnmeasuredLibraryHasNoTarget() {
        // Before the manifest lands there is nothing honest to say, and the grid
        // falls back to landing on whole days.
        XCTAssertNil(LibrarySpan.empty.target(atFraction: 0.5, viewport: screen))
        XCTAssertNil(
            span(Array(repeating: 200, count: 4)).target(
                atFraction: 0.5, viewport: 0
            )
        )
    }
}
