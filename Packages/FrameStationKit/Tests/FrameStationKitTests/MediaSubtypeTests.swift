import Foundation
import Testing

@testable import FrameStationAPI

@Suite("Media subtypes cross the wire safely")
struct MediaSubtypeTests {
    /// The failure this guards is the one `CodingContractTests` was written
    /// for: a decode error on upload commit, on device, in the background,
    /// showing up only as uploads that never land.
    ///
    /// Swift's synthesized `Decodable` throws on a missing key rather than
    /// falling back to the property's default, so a build that predates
    /// `mediaSubtypes` must still decode.
    @Test("A commit without mediaSubtypes still decodes")
    func missingFieldDecodes() throws {
        let json = """
        {"spaceID":"\(UUID().uuidString)","mediaType":"photo","mime":"image/heic",
         "isRaw":false,"burstPick":false}
        """
        let request = try FrameStationCoding.decoder.decode(
            CommitUploadRequest.self, from: Data(json.utf8)
        )
        #expect(request.mediaSubtypes == nil)
        #expect(request.subtypes.isEmpty)
    }

    @Test("Subtypes survive a round trip")
    func roundTrip() throws {
        let original = CommitUploadRequest(
            spaceID: UUID(), mediaType: .photo, mime: "image/png",
            mediaSubtypes: [.screenshot, .portrait]
        )
        let data = try FrameStationCoding.encoder.encode(original)
        let decoded = try FrameStationCoding.decoder.decode(
            CommitUploadRequest.self, from: data
        )
        #expect(decoded.subtypes == [.screenshot, .portrait])
    }

    /// The raw values are written into `assets.media_subtypes` and matched by
    /// SQL string literals, so renaming a case silently empties an album
    /// rather than failing to build.
    @Test("Raw values are the strings the database stores")
    func rawValuesAreStable() {
        #expect(MediaSubtype.screenshot.rawValue == "screenshot")
        #expect(MediaSubtype.screenRecording.rawValue == "screenRecording")
        #expect(MediaSubtype.panorama.rawValue == "panorama")
        #expect(MediaSubtype.slomo.rawValue == "slomo")
        #expect(MediaSubtype.timelapse.rawValue == "timelapse")
        #expect(MediaSubtype.portrait.rawValue == "portrait")
        #expect(MediaSubtype.cinematic.rawValue == "cinematic")
    }

    /// Media type keys go out in the collections page and come back as a filter
    /// key, so every subtype must survive that round trip or opening the album
    /// returns the whole library.
    @Test("Every subtype maps back from its key")
    func keysRoundTrip() {
        for subtype in MediaSubtype.allCases {
            #expect(MediaSubtype(rawValue: subtype.rawValue) == subtype)
            #expect(!subtype.title.isEmpty)
        }
    }
}
