import FrameStationAPI
import XCTest

/// The server encodes these at ingest and the clients decode them while
/// scrolling, so what actually matters is that encode and decode agree and that
/// the result is perceptually close to the source. These tests assert both.
final class ThumbHashTests: XCTestCase {

    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255,
                       width: Int = 32, height: Int = 32) -> [UInt8] {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) { pixels.append(contentsOf: [r, g, b, a]) }
        return pixels
    }

    func testHashIsCompact() {
        let hash = ThumbHash.encode(width: 32, height: 32, rgba: solid(120, 80, 200))
        // The whole point is that this ships inside the timeline manifest.
        XCTAssertLessThanOrEqual(hash.count, 30, "ThumbHash should stay around 25 bytes")
        XCTAssertGreaterThanOrEqual(hash.count, 5)
    }

    func testAverageColourSurvivesRoundTrip() throws {
        let cases: [(UInt8, UInt8, UInt8)] = [
            (200, 40, 40),    // red
            (40, 180, 90),    // green
            (60, 90, 220),    // blue
            (240, 240, 240),  // near-white
            (20, 20, 20),     // near-black
        ]

        for (r, g, b) in cases {
            let hash = ThumbHash.encode(width: 32, height: 32, rgba: solid(r, g, b))
            let average = try XCTUnwrap(ThumbHash.averageRGBA(hash))

            XCTAssertEqual(average.r, Double(r) / 255, accuracy: 0.10,
                           "red channel drifted for \(r),\(g),\(b)")
            XCTAssertEqual(average.g, Double(g) / 255, accuracy: 0.10,
                           "green channel drifted for \(r),\(g),\(b)")
            XCTAssertEqual(average.b, Double(b) / 255, accuracy: 0.10,
                           "blue channel drifted for \(r),\(g),\(b)")
        }
    }

    func testDecodeProducesAnImageOfTheRightShape() throws {
        let landscape = ThumbHash.encode(width: 80, height: 45, rgba: solid(100, 150, 200, 255, width: 80, height: 45))
        let decodedLandscape = try XCTUnwrap(ThumbHash.decode(landscape, maxDimension: 32))
        XCTAssertGreaterThan(decodedLandscape.width, decodedLandscape.height,
                             "a landscape source should decode to a landscape placeholder")

        let portrait = ThumbHash.encode(width: 45, height: 80, rgba: solid(100, 150, 200, 255, width: 45, height: 80))
        let decodedPortrait = try XCTUnwrap(ThumbHash.decode(portrait, maxDimension: 32))
        XCTAssertGreaterThan(decodedPortrait.height, decodedPortrait.width,
                             "a portrait source should decode to a portrait placeholder")

        XCTAssertEqual(decodedPortrait.rgba.count, decodedPortrait.width * decodedPortrait.height * 4)
    }

    func testSolidImageDecodesToRoughlyThatColour() throws {
        let hash = ThumbHash.encode(width: 32, height: 32, rgba: solid(200, 60, 60))
        let decoded = try XCTUnwrap(ThumbHash.decode(hash, maxDimension: 16))

        var totalR = 0.0, totalG = 0.0, totalB = 0.0
        let count = decoded.width * decoded.height
        for i in 0..<count {
            totalR += Double(decoded.rgba[i * 4])
            totalG += Double(decoded.rgba[i * 4 + 1])
            totalB += Double(decoded.rgba[i * 4 + 2])
        }

        XCTAssertEqual(totalR / Double(count), 200, accuracy: 30)
        XCTAssertEqual(totalG / Double(count), 60, accuracy: 30)
        XCTAssertEqual(totalB / Double(count), 60, accuracy: 30)
    }

    func testHorizontalSplitPreservesLeftRightStructure() throws {
        // Left half dark, right half bright. A placeholder that loses this is
        // worse than useless — it would flash the wrong composition.
        let width = 32, height = 32
        var pixels: [UInt8] = []
        for _ in 0..<height {
            for x in 0..<width {
                let value: UInt8 = x < width / 2 ? 20 : 235
                pixels.append(contentsOf: [value, value, value, 255])
            }
        }

        let hash = ThumbHash.encode(width: width, height: height, rgba: pixels)
        let decoded = try XCTUnwrap(ThumbHash.decode(hash, maxDimension: 24))

        var leftTotal = 0.0, rightTotal = 0.0, leftCount = 0.0, rightCount = 0.0
        for y in 0..<decoded.height {
            for x in 0..<decoded.width {
                let luminance = Double(decoded.rgba[(x + y * decoded.width) * 4])
                if x < decoded.width / 2 {
                    leftTotal += luminance; leftCount += 1
                } else {
                    rightTotal += luminance; rightCount += 1
                }
            }
        }

        XCTAssertLessThan(leftTotal / leftCount, rightTotal / rightCount - 40,
                          "the dark half must stay clearly darker after a round trip")
    }

    func testEmptyHashDecodesToNil() {
        XCTAssertNil(ThumbHash.decode([]))
        XCTAssertNil(ThumbHash.decode([1, 2]))
        XCTAssertNil(ThumbHash.averageRGBA([1, 2, 3]))
    }
}
