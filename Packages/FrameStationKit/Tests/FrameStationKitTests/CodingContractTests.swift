import FrameStationAPI
import XCTest

/// Guards the client/server JSON contract.
///
/// These exist because of a real bug: Vapor encodes `Date` as ISO8601 while a
/// stock `JSONDecoder` uses `.deferredToDate` (seconds since 2001). A client
/// built on defaults sends `774662400` where the server expects
/// `"2026-07-24T19:28:00Z"`, and the only symptom is a 400 on every upload
/// commit carrying a capture date — on device, in the background, silently.
final class CodingContractTests: XCTestCase {
    func testCapturedAtEncodesAsISO8601NotSecondsSince2001() throws {
        let captured = Date(timeIntervalSince1970: 1_784_921_280)  // 2026-07-24T19:28:00Z
        let request = CommitUploadRequest(
            spaceID: UUID(),
            mediaType: .photo,
            mime: "image/heic",
            capturedAt: captured
        )

        let json = try FrameStationCoding.encoder.encode(request)
        let text = String(decoding: json, as: UTF8.self)

        XCTAssertTrue(
            text.contains("2026-07-24T19:28:00Z"),
            "capturedAt must serialize as an ISO8601 string, got: \(text)"
        )
        XCTAssertFalse(
            text.contains("original\":774"),
            "capturedAt must not serialize as a seconds-since-2001 number"
        )
    }

    func testCommitRequestRoundTrips() throws {
        let original = CommitUploadRequest(
            spaceID: UUID(),
            mediaType: .video,
            mime: "video/quicktime",
            width: 3840,
            height: 2160,
            durationMs: 12500,
            capturedAt: Date(timeIntervalSince1970: 1_784_921_280),
            capturedTZOffset: -14400,
            latitude: 38.3487,
            longitude: -77.9797,
            isRaw: false,
            burstID: "ABC-123",
            burstPick: true,
            sourceLocalID: "ABC-123/L0/001"
        )

        let data = try FrameStationCoding.encoder.encode(original)
        let decoded = try FrameStationCoding.decoder.decode(CommitUploadRequest.self, from: data)

        XCTAssertEqual(decoded.spaceID, original.spaceID)
        XCTAssertEqual(decoded.mediaType, original.mediaType)
        XCTAssertEqual(decoded.durationMs, original.durationMs)
        XCTAssertEqual(decoded.capturedTZOffset, original.capturedTZOffset)
        XCTAssertEqual(decoded.sourceLocalID, original.sourceLocalID)
        XCTAssertEqual(decoded.capturedAt?.timeIntervalSince1970,
                       original.capturedAt?.timeIntervalSince1970)
    }

    /// The millisecond travels beside the date, never inside it. A fractional
    /// "…:28:00.459Z" would be refused by the whole-second decoder every build
    /// before this one uses — a failed commit on an older server, an empty grid
    /// on an older phone.
    func testMillisecondsTravelBesideAWholeSecondDate() throws {
        let captured = Date(timeIntervalSince1970: 1_784_921_280.459)
        let request = CommitUploadRequest(
            spaceID: UUID(),
            mediaType: .photo,
            mime: "image/heic",
            capturedAt: captured,
            capturedAtMs: 1_784_921_280_459
        )

        let json = try FrameStationCoding.encoder.encode(request)
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertTrue(text.contains("\"2026-07-24T19:28:00Z\""), "got: \(text)")
        XCTAssertTrue(text.contains("\"capturedAtMs\":1784921280459"), "got: \(text)")

        let decoded = try FrameStationCoding.decoder.decode(CommitUploadRequest.self, from: json)
        XCTAssertEqual(decoded.capturedAtMs, 1_784_921_280_459)
        XCTAssertEqual(decoded.preciseCapturedAt?.timeIntervalSince1970 ?? 0, 1_784_921_280.459,
                       accuracy: 0.0005)
    }

    /// What a phone from before `capturedAtMs` sends, and what a server from
    /// before it returns: both still decode, and fall back to the second.
    func testPayloadsWithoutMillisecondsStillDecode() throws {
        let commit = """
        {"spaceID":"9A4C4021-1DE7-428C-BE59-5D8EA41C711A","mediaType":"photo",\
        "mime":"image/heic","capturedAt":"2026-07-24T19:28:00Z","isRaw":false,\
        "burstPick":false}
        """.data(using: .utf8)!
        let request = try FrameStationCoding.decoder.decode(CommitUploadRequest.self, from: commit)
        XCTAssertNil(request.capturedAtMs)
        XCTAssertEqual(request.preciseCapturedAt, request.capturedAt)

        let item = """
        {"id":"9A4C4021-1DE7-428C-BE59-5D8EA41C711A",\
        "spaceID":"9A4C4021-1DE7-428C-BE59-5D8EA41C711B",\
        "assetID":"9A4C4021-1DE7-428C-BE59-5D8EA41C711C",\
        "capturedAt":"2026-07-24T19:28:00Z","aspectRatio":1.5,"mediaType":"photo",\
        "isFavorite":false,"uploadedBy":"9A4C4021-1DE7-428C-BE59-5D8EA41C711D",\
        "isDerived":true,"isBurst":false}
        """.data(using: .utf8)!
        let decoded = try FrameStationCoding.decoder.decode(TimelineItem.self, from: item)
        XCTAssertNil(decoded.capturedAtMs)
        XCTAssertEqual(decoded.preciseCapturedAt, decoded.capturedAt)
    }

    /// Two photographs in the same second, in the order they were taken.
    func testPreciseCaptureTimeOrdersWithinASecond() {
        func item(_ ms: Int64?) -> TimelineItem {
            TimelineItem(
                id: UUID(), spaceID: UUID(), assetID: UUID(),
                capturedAt: Date(timeIntervalSince1970: 1_784_921_280),
                aspectRatio: 1, mediaType: .photo, durationMs: nil, thumbHash: nil,
                isFavorite: false, uploadedBy: UUID(), isDerived: true,
                capturedAtMs: ms
            )
        }
        let later = item(1_784_921_280_900)
        let earlier = item(1_784_921_280_100)
        XCTAssertLessThan(earlier.preciseCapturedAt, later.preciseCapturedAt)
        XCTAssertEqual(earlier.capturedAt, later.capturedAt)
    }

    func testProbeResponseDecodesServerShape() throws {
        // Byte-for-byte what the server returned during the M1a smoke test.
        let json = """
        {"status":"partial","assetID":null,"uploadID":"9A4C4021-1DE7-428C-BE59-5D8EA41C711A",\
        "chunkSize":16777216,"chunkCount":3,"missingChunks":[1]}
        """.data(using: .utf8)!

        let response = try FrameStationCoding.decoder.decode(UploadProbeResponse.self, from: json)

        XCTAssertEqual(response.status, .partial)
        XCTAssertNil(response.assetID)
        XCTAssertEqual(response.chunkCount, 3)
        XCTAssertEqual(response.missingChunks, [1])
    }

    /// A share answered by a server from before `alreadySharedAssetIDs` still
    /// decodes, with nil there rather than an empty list. The app counts the
    /// photos that didn't arrive when it can't name them, and an empty list
    /// would mean "the server checked, and none were there already".
    func testShareResponseFromAnOlderServerHasNoAlreadyShared() throws {
        let json = """
        {"shared":0,"assetIDs":[],"sourceAssetIDs":[],\
        "destinationSpaceID":"9A4C4021-1DE7-428C-BE59-5D8EA41C711A"}
        """.data(using: .utf8)!

        let response = try FrameStationCoding.decoder.decode(ShareAssetsResponse.self, from: json)

        XCTAssertEqual(response.shared, 0)
        XCTAssertNil(response.alreadySharedAssetIDs)
    }

    func testShareResponseNamesWhatWasAlreadyThere() throws {
        let already = UUID()
        let original = ShareAssetsResponse(
            shared: 1, assetIDs: [UUID()], sourceAssetIDs: [UUID()],
            destinationSpaceID: UUID(), alreadySharedAssetIDs: [already]
        )

        let data = try FrameStationCoding.encoder.encode(original)
        let decoded = try FrameStationCoding.decoder.decode(ShareAssetsResponse.self, from: data)

        XCTAssertEqual(decoded.alreadySharedAssetIDs, [already])
        XCTAssertEqual(decoded, original)
    }

    /// What a phone sends about a birthday photo's writing: an id and the
    /// numbers, and no field that could carry the writing itself.
    func testWrittenNumbersTravelAsNumbersOnly() throws {
        let original = SubmitWrittenNumbersRequest(
            readingVersion: 1, photos: [WrittenNumbers(assetID: UUID(), numbers: [2])]
        )
        let data = try FrameStationCoding.encoder.encode(original)
        XCTAssertEqual(try FrameStationCoding.decoder.decode(SubmitWrittenNumbersRequest.self, from: data), original)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["readingVersion", "photos"])
        let photo = try XCTUnwrap((json["photos"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(photo.keys), ["assetID", "numbers"])
        XCTAssertEqual(photo["numbers"] as? [Int], [2])
    }

    /// An album list from a server before cover versions still decodes, each
    /// cover at version 0, which is what the app asked for before. A newer
    /// one says each album's and each library's version beside its cover.
    func testAlbumCoversCarryTheirThumbnailVersion() throws {
        let album = UUID(uuidString: "9A4C4021-1DE7-428C-BE59-5D8EA41C7201")!
        let library = UUID(uuidString: "9A4C4021-1DE7-428C-BE59-5D8EA41C7202")!
        let cover = UUID(uuidString: "9A4C4021-1DE7-428C-BE59-5D8EA41C7203")!
        func list(albumVersion: String, libraryVersion: String) -> Data {
            """
            {"albums":[{"id":"\(album)","name":"Beach","itemCount":3,"coverAssetID":"\(cover)",\(albumVersion)\
            "createdAt":"2026-07-24T19:28:00Z","updatedAt":"2026-07-24T19:28:00Z"},\
            {"id":"\(UUID())","name":"Empty","itemCount":0,"coverAssetID":null,\
            "createdAt":"2026-07-24T19:28:00Z","updatedAt":"2026-07-24T19:28:00Z"}],\
            "libraries":[{"id":"\(library)","name":"Family","memberCount":3,"itemCount":40,\
            \(libraryVersion)"coverAssetID":"\(cover)"}]}
            """.data(using: .utf8)!
        }

        let older = try FrameStationCoding.decoder.decode(
            AlbumListResponse.self, from: list(albumVersion: "", libraryVersion: "")
        )
        XCTAssertNil(older.albums.first?.coverVersion)
        XCTAssertEqual(older.albums.first?.cover, CoverThumbnail(assetID: cover, version: 0))
        XCTAssertNil(older.albums.last?.cover)
        XCTAssertEqual(older.libraries?.first?.cover, CoverThumbnail(assetID: cover, version: 0))

        let newer = try FrameStationCoding.decoder.decode(
            AlbumListResponse.self,
            from: list(albumVersion: "\"coverVersion\":5,", libraryVersion: "\"coverVersion\":4,")
        )
        XCTAssertEqual(newer.albums.first?.cover, CoverThumbnail(assetID: cover, version: 5))
        XCTAssertNil(newer.albums.last?.cover)
        XCTAssertEqual(newer.libraries?.first?.cover, CoverThumbnail(assetID: cover, version: 4))
    }

    func testAlbumListRoundTripsWithCoverVersions() throws {
        let made = Date(timeIntervalSince1970: 1_784_921_280)
        let original = AlbumListResponse(
            albums: [AlbumDTO(
                id: UUID(), name: "Beach", itemCount: 3, coverAssetID: UUID(), coverVersion: 5,
                createdAt: made, updatedAt: made
            )],
            includesFamilyAlbums: true,
            libraries: [SharedLibrarySummary(
                id: UUID(), name: "Family", memberCount: 3, itemCount: 40, coverAssetID: UUID(),
                coverVersion: 4
            )],
            includesPeopleAlbums: true
        )

        let data = try FrameStationCoding.encoder.encode(original)
        let decoded = try FrameStationCoding.decoder.decode(AlbumListResponse.self, from: data)

        XCTAssertEqual(decoded.albums, original.albums)
        XCTAssertEqual(decoded.libraries, original.libraries)
        XCTAssertEqual(decoded.albums.first?.coverVersion, 5)
        XCTAssertEqual(decoded.libraries?.first?.coverVersion, 4)
    }

    func testPlatformCoversEveryClientTarget() {
        // The server CHECK constraint on devices.platform must stay in step.
        XCTAssertEqual(
            Set(Platform.allCases.map(\.rawValue)),
            ["ios", "ipados", "macos", "tvos"]
        )
    }
}
