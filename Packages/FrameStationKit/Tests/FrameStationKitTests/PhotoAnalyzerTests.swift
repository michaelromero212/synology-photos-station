import CoreGraphics
import CoreText
import FrameStationAnalysis
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// The analyzer runs end to end on a picture with nothing in it.
///
/// Not a test of what Vision recognizes; that's judged on real photographs, on
/// the device. This checks that the analyzer produces an answer of the shape
/// the server expects: strongest first, nothing below the floor, no more than
/// the cap, and nobody in an empty picture.
@available(iOS 18.0, macOS 15.0, tvOS 18.0, *)
final class PhotoAnalyzerTests: XCTestCase {
    /// A 512-pixel gradient, encoded as the JPEG a thumbnail would be.
    private func gradientJPEG() throws -> Data {
        let size = 512
        let context = try XCTUnwrap(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let colors = [
            CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1),
            CGColor(red: 0.9, green: 0.8, blue: 0.5, alpha: 1),
        ] as CFArray
        let gradient = try XCTUnwrap(CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]
        ))
        context.drawLinearGradient(
            gradient, start: .zero, end: CGPoint(x: 0, y: size), options: []
        )
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testAnEmptyPictureGetsAWellFormedAnswer() async throws {
        let observation = try await PhotoAnalyzer().analyze(imageData: try gradientJPEG())

        XCTAssertLessThanOrEqual(observation.labels.count, 30)
        XCTAssertTrue(observation.labels.allSatisfy { $0.confidence >= 0.1 })
        XCTAssertEqual(
            observation.labels.map(\.confidence),
            observation.labels.map(\.confidence).sorted(by: >),
            "Labels must arrive strongest first"
        )
        XCTAssertEqual(observation.peopleCount, 0)
        XCTAssertFalse(PhotoAnalyzer.modelVersion.isEmpty)
    }

    // MARK: - The age written in a birthday photo

    func testAnAgeIsReadFromDigitsOrdinalsAndWords() {
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["2"]), [2])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["Happy 2nd Birthday Thomas!"]), [2])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["TWO"]), [2])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["Happy Second Birthday"]), [2])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["Sweet 16"]), [16])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["Wild ONE"]), [1])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["Three-Rex"]), [3])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["Thomas is 2 years old"]), [2])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["(2)", "\u{201C}Two\u{201D}"]), [2], "One age, said twice")
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["Happy Birthday Thomas"]), [])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: []), [])
    }

    func testWritingThatMightNotBeAnAgeSaysNothing() {
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["4", "0"]), [], "A 40th, its candles read apart")
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["40"]), [])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["2", "5"]), [], "A 25th, or two children's cakes")
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["Happy 2nd Birthday", "2026"]), [])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["2", "3:45"]), [])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["$5"]), [])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["#7"]), [])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["2.5"]), [])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["2\u{00BD}"]), [])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["Twenty-One"]), [])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["Happy 6 Months"]), [])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["Happy Half Birthday", "6"]), [])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["Happy 2nd Anniversary"]), [])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["Happy 4th of July"]), [])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["July 4th"]), [])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["May 12"]), [])
    }

    /// The restaurant example, 2026-11-10: a cupcake with a single candle is
    /// nobody's first birthday.
    func testAPlainCandleIsNotAOne() {
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["1"]), [])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["11"]), [])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["1", "2"]), [], "A 12th, its candles read apart")
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["1", "Happy 1st Birthday"]), [1])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["11th"]), [11])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["Eleven"]), [11])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["No one does it better"]), [])
        XCTAssertEqual(PhotoAnalyzer.numbers(in: ["The one and only"]), [])
    }

    /// A made-up picture, drawn here and never saved: a "2" candle's worth of
    /// digit and a line of writing on a cake, at the full-screen size the
    /// phone reads. Not a test of how well Vision reads icing, which only
    /// real photos can judge; this checks the reading runs end to end and
    /// comes back as one number.
    func testAPictureOfACakeReadsAsItsAge() async throws {
        let width = 1536, height = 2048
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.97, green: 0.93, blue: 0.88, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        func draw(_ text: String, size: CGFloat, y: CGFloat) {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let attributes = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 1),
            ] as [NSAttributedString.Key: Any]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            context.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2 - bounds.minX, y: y)
            CTLineDraw(line, context)
        }
        draw("2", size: 240, y: 1300)
        draw("Happy 2nd Birthday Thomas", size: 48, y: 900)
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let analyzer = PhotoAnalyzer()
        let age = try await analyzer.readNumbers(imageData: data as Data)
        XCTAssertEqual(age, [2])
        let nothing = try await analyzer.readNumbers(imageData: try gradientJPEG())
        XCTAssertEqual(nothing, [])
    }
}
