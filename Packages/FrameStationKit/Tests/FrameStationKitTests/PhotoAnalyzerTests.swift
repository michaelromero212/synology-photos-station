import CoreGraphics
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
}
