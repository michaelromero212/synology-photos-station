import FrameStationKit
import XCTest

/// The grid's whole promise is a flush right edge and honest shapes. Both are
/// arithmetic, so both are testable without a screen — which is the reason this
/// lives in the package rather than next to the view.
final class JustifiedLayoutTests: XCTestCase {

    private let width = 1000.0
    private let spacing = 4.0

    /// The width a row actually occupies once laid out.
    private func occupied(_ row: JustifiedRow, ratios: [Double]) -> Double {
        let widths = ratios[row.range].map {
            JustifiedLayout.width(forRatio: $0, height: row.height)
        }
        return widths.reduce(0, +) + spacing * Double(row.range.count - 1)
    }

    func testEveryFullRowFillsTheWidthExactly() {
        // Mixed shapes, so rows break at different counts.
        let ratios = [1.5, 0.75, 1.0, 1.77, 0.66, 1.33, 1.0, 0.75, 1.5, 1.77, 0.8, 1.2]
        let rows = JustifiedLayout.rows(
            aspectRatios: ratios, width: width, targetHeight: 200, spacing: spacing
        )
        XCTAssertGreaterThan(rows.count, 1, "this fixture should break into several rows")

        // Every row but the last is stretched to land on the width exactly.
        for row in rows.dropLast() {
            XCTAssertEqual(occupied(row, ratios: ratios), width, accuracy: 0.001)
        }
    }

    func testRowsCoverEveryItemExactlyOnce() {
        let ratios = Array(repeating: 1.0, count: 37)
        let rows = JustifiedLayout.rows(
            aspectRatios: ratios, width: width, targetHeight: 150, spacing: spacing
        )
        XCTAssertEqual(rows.flatMap { Array($0.range) }, Array(0..<37))
    }

    /// The regression this guards: a day ending on one landscape photo used to
    /// close with that frame stretched across the full width, taller than
    /// everything above it and reading as a banner.
    func testShortLastRowIsNotStretched() {
        let rows = JustifiedLayout.rows(
            aspectRatios: [1.5], width: width, targetHeight: 200, spacing: spacing
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].height, 200, accuracy: 0.001)
        XCTAssertLessThan(occupied(rows[0], ratios: [1.5]), width)
    }

    func testLandscapeComesOutWiderThanPortrait() {
        // The point of the whole layout: shape survives.
        let ratios = [1.77, 0.5625]
        let rows = JustifiedLayout.rows(
            aspectRatios: ratios, width: width, targetHeight: 200, spacing: spacing
        )
        let row = try? XCTUnwrap(rows.first)
        let height = row?.height ?? 0
        XCTAssertGreaterThan(
            JustifiedLayout.width(forRatio: 1.77, height: height),
            JustifiedLayout.width(forRatio: 0.5625, height: height)
        )
    }

    /// A 10:1 panorama laid out honestly is a slit. Clamping keeps the row
    /// usable; the cell centre-crops the rest.
    func testExtremePanoramaIsClamped() {
        XCTAssertEqual(JustifiedLayout.normalized(10), JustifiedLayout.ratioBounds.upperBound)
        XCTAssertEqual(JustifiedLayout.normalized(0.05), JustifiedLayout.ratioBounds.lowerBound)
    }

    func testGarbageRatiosBecomeSquares() {
        XCTAssertEqual(JustifiedLayout.normalized(0), 1)
        XCTAssertEqual(JustifiedLayout.normalized(-3), 1)
        XCTAssertEqual(JustifiedLayout.normalized(.nan), 1)
        // Infinity is nonsense rather than a very wide photo, so it lands on
        // the square guess with the rest of the garbage — not on the clamp.
        XCTAssertEqual(JustifiedLayout.normalized(.infinity), 1)
    }

    func testDegenerateInputsDoNotCrashOrProduceRows() {
        XCTAssertTrue(JustifiedLayout.rows(
            aspectRatios: [], width: width, targetHeight: 200, spacing: spacing
        ).isEmpty)
        XCTAssertTrue(JustifiedLayout.rows(
            aspectRatios: [1, 1], width: 0, targetHeight: 200, spacing: spacing
        ).isEmpty)
        XCTAssertTrue(JustifiedLayout.rows(
            aspectRatios: [1, 1], width: width, targetHeight: 0, spacing: spacing
        ).isEmpty)
    }

    /// A narrow window — iPad split view — must still lay out, one per row if
    /// that's what fits, and never with a negative or zero height.
    func testNarrowWidthStillProducesUsableRows() {
        let ratios = Array(repeating: 1.5, count: 6)
        let rows = JustifiedLayout.rows(
            aspectRatios: ratios, width: 120, targetHeight: 200, spacing: spacing
        )
        XCTAssertEqual(rows.flatMap { Array($0.range) }, Array(0..<6))
        for row in rows { XCTAssertGreaterThan(row.height, 0) }
    }

    /// The same photos in a wider window should give the same row height, and
    /// simply fit more per row. That's what makes the grid read consistently
    /// on a phone-sized split view and a TV.
    func testWiderContainerAddsColumnsRatherThanEnlargingRows() {
        let ratios = Array(repeating: 1.0, count: 60)
        let narrow = JustifiedLayout.rows(
            aspectRatios: ratios, width: 600, targetHeight: 150, spacing: spacing
        )
        let wide = JustifiedLayout.rows(
            aspectRatios: ratios, width: 1800, targetHeight: 150, spacing: spacing
        )
        XCTAssertGreaterThan(wide[0].range.count, narrow[0].range.count)
        XCTAssertEqual(narrow[0].height, wide[0].height, accuracy: 12)
    }
}
