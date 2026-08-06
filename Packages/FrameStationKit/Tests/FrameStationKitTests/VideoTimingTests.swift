import FrameStationKit
import XCTest

/// Transport arithmetic. Every case here is one that shows up on real footage
/// rather than one invented to pad a suite — an unknown duration while a stream
/// opens, a skip near either end, a clip long enough to grow an hours field.
final class VideoTimingTests: XCTestCase {

    // MARK: - Skipping

    func testSkipBackNearTheStartLandsAtZeroRatherThanRefusing() {
        // "Watch that bit again" four seconds in means "start again". A button
        // that declines to move reads as broken.
        XCTAssertEqual(
            VideoTiming.skipTarget(from: 4, by: -10, duration: 60), 0, accuracy: 0.001
        )
    }

    func testSkipForwardStopsShortOfTheVeryEnd() {
        let target = VideoTiming.skipTarget(from: 55, by: 10, duration: 60)
        XCTAssertLessThan(target, 60, "seeking to exactly the duration parks on a dead frame")
        XCTAssertGreaterThan(target, 59)
    }

    func testOrdinarySkipsAreExact() {
        XCTAssertEqual(
            VideoTiming.skipTarget(from: 30, by: -10, duration: 120), 20, accuracy: 0.001
        )
        XCTAssertEqual(
            VideoTiming.skipTarget(from: 30, by: 10, duration: 120), 40, accuracy: 0.001
        )
    }

    /// Repeatedly jumping back is the thing the controls exist for, so it has to
    /// stay stable rather than drift or stick.
    func testRepeatedSkipBackWalksToTheStartAndStays() {
        var position = 42.0
        for _ in 0..<10 {
            position = VideoTiming.skipTarget(
                from: position, by: -VideoTiming.skipInterval, duration: 60
            )
        }
        XCTAssertEqual(position, 0, accuracy: 0.001)
    }

    /// A stream whose duration hasn't arrived yet must still skip forward —
    /// only the start can be enforced.
    func testUnknownDurationStillAllowsSkipping() {
        XCTAssertEqual(
            VideoTiming.skipTarget(from: 5, by: 10, duration: 0), 15, accuracy: 0.001
        )
        XCTAssertEqual(
            VideoTiming.skipTarget(from: 5, by: -10, duration: 0), 0, accuracy: 0.001
        )
    }

    func testGarbageTimesDoNotEscape() {
        XCTAssertEqual(VideoTiming.skipTarget(from: .nan, by: 10, duration: 60), 0)
        XCTAssertEqual(VideoTiming.skipTarget(from: 10, by: .infinity, duration: 60), 0)
    }

    // MARK: - Scrub tolerance

    /// The whole point: never zero, or the decoder walks from the previous
    /// keyframe and the picture can't keep up with a thumb.
    func testScrubToleranceIsNeverZero() {
        for duration in [0.0, 0.5, 12, 90, 3600, 20000] {
            XCTAssertGreaterThan(VideoTiming.scrubTolerance(duration: duration), 0)
        }
    }

    func testShortClipsGetFinerToleranceThanLongOnes() {
        XCTAssertLessThan(
            VideoTiming.scrubTolerance(duration: 10),
            VideoTiming.scrubTolerance(duration: 3600)
        )
    }

    func testToleranceStaysWithinUsableBounds() {
        XCTAssertLessThanOrEqual(VideoTiming.scrubTolerance(duration: 100_000), 1.0)
        XCTAssertGreaterThanOrEqual(VideoTiming.scrubTolerance(duration: 0.1), 0.05)
    }

    // MARK: - Timecode

    func testTimecodeFormatsMinutesAndSeconds() {
        XCTAssertEqual(VideoTiming.timecode(0, duration: 60), "0:00")
        XCTAssertEqual(VideoTiming.timecode(7, duration: 60), "0:07")
        XCTAssertEqual(VideoTiming.timecode(271, duration: 600), "4:31")
    }

    /// The hours field keys off the clip length, not the position, so the label
    /// doesn't change width as it plays.
    func testHoursFieldIsDecidedByTheClipNotThePosition() {
        XCTAssertEqual(VideoTiming.timecode(5, duration: 4000), "0:00:05")
        XCTAssertEqual(VideoTiming.timecode(5, duration: 100), "0:05")
    }

    func testTimecodeSurvivesGarbage() {
        XCTAssertEqual(VideoTiming.timecode(.nan, duration: 60), "0:00")
        XCTAssertEqual(VideoTiming.timecode(-30, duration: 60), "0:00")
        XCTAssertEqual(VideoTiming.timecode(.infinity, duration: .nan), "0:00")
    }

    // MARK: - Frame rate

    /// "Various frame rates" includes containers that report nonsense; a zero
    /// here would divide the player out of existence.
    func testFrameDurationHandlesEveryRate() {
        XCTAssertEqual(VideoTiming.frameDuration(nominalFrameRate: 30), 1.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(VideoTiming.frameDuration(nominalFrameRate: 59.94), 1.0 / 59.94, accuracy: 1e-9)
        XCTAssertEqual(VideoTiming.frameDuration(nominalFrameRate: 0), 1.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(VideoTiming.frameDuration(nominalFrameRate: -1), 1.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(VideoTiming.frameDuration(nominalFrameRate: .nan), 1.0 / 30, accuracy: 1e-9)
    }

    // MARK: - Scrubber mapping

    func testFractionAndTimeRoundTrip() {
        let duration = 137.0
        for fraction in [0.0, 0.25, 0.5, 0.999, 1.0] {
            let time = VideoTiming.time(forFraction: fraction, duration: duration)
            XCTAssertEqual(
                VideoTiming.fraction(forTime: time, duration: duration), fraction, accuracy: 1e-9
            )
        }
    }

    func testMappingClampsAndSurvivesUnknownDuration() {
        XCTAssertEqual(VideoTiming.time(forFraction: 2, duration: 60), 60, accuracy: 0.001)
        XCTAssertEqual(VideoTiming.time(forFraction: -1, duration: 60), 0, accuracy: 0.001)
        // Divide-by-zero territory: an unknown duration must give 0, not NaN.
        XCTAssertEqual(VideoTiming.fraction(forTime: 10, duration: 0), 0)
        XCTAssertEqual(VideoTiming.time(forFraction: 0.5, duration: 0), 0)
    }
}
