import FrameStationAPI
import XCTest

/// Byte-for-byte a real server response. Optional fields the server had nothing
/// for (filename, description, rating, placeName) are absent rather than null,
/// which is exactly the shape that broke the Information panel in the simulator.
final class AssetDetailDecodingTests: XCTestCase {
    func testDecodesRealServerResponse() throws {
        let json = """
        {"lens":"iPhone 16 Pro Max back camera 6.765mm f/1.78","exposureBias":0,
        "mediaType":"photo","capturedAt":"2026-07-18T16:00:00Z","isRaw":false,
        "longitude":-77.9797,"spaceID":"47AE9DC9-419D-4EC1-8F48-568CC7E7888D",
        "uploadedAt":"2026-07-29T23:25:05Z","onDevice":true,
        "aperture":1.7799999713897705,"byteSize":593861,"tags":[],
        "latitude":38.3487,"mime":"image/jpeg","cameraMake":"Apple",
        "assetID":"B08073AD-E28C-475A-AB74-47FD03D075BC","focalLength":24,
        "dynamicRange":"standard","isFavorite":false,
        "uploadedBy":{"id":"1092CC90-7BB7-4B20-9994-1E4C62DB761D","displayName":"Michael"},
        "capturedTZOffset":-14400,"isSharedSpace":false,"iso":64,
        "cameraModel":"iPhone 16 Pro Max","shutter":"1/268 s","height":5712,
        "id":"07C681CA-C4E3-4F59-9241-30BB8041E21D","width":4284}
        """.data(using: .utf8)!

        let detail = try FrameStationCoding.decoder.decode(AssetDetail.self, from: json)

        XCTAssertEqual(detail.cameraModel, "iPhone 16 Pro Max")
        XCTAssertEqual(detail.iso, 64)
        XCTAssertEqual(detail.shutter, "1/268 s")
        XCTAssertEqual(detail.width, 4284)
        XCTAssertNil(detail.filename)
        XCTAssertNil(detail.description)
        XCTAssertEqual(detail.megapixels ?? 0, 24.5, accuracy: 0.5)
    }
}
