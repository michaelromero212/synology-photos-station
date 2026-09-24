import FrameStationKit
import XCTest

/// The ledger's keys, which decide what backup sends and what it recognizes as
/// already sent.
///
/// Worth pinning because a wrong answer fails silently. A key that doesn't lead
/// back to its photo means the file is never found and never sent; an edit key
/// that changes when nothing changed means the same edit is re-read and re-hashed
/// on every scan; one that *doesn't* change when the photo is edited again means
/// the new edit never reaches the NAS.
final class BackupKeyTests: XCTestCase {
    private let photo = "8F3A2C71-1B2D-4E5F-9A0B-1C2D3E4F5A6B/L0/001"
    private let edited = Date(timeIntervalSince1970: 1_790_000_123.75)

    func testEveryKeyLeadsBackToItsPhoto() {
        for key in [
            photo,
            BackupKey.pairedVideo(of: photo),
            BackupKey.edit(of: photo, editedAt: edited),
        ] {
            XCTAssertEqual(BackupKey.photo(key), photo)
        }
    }

    func testEachKeyKnowsWhatItIs() {
        XCTAssertEqual(BackupKey.kind(photo), .main)
        XCTAssertEqual(BackupKey.kind(BackupKey.pairedVideo(of: photo)), .pairedVideo)
        XCTAssertEqual(BackupKey.kind(BackupKey.edit(of: photo, editedAt: edited)), .edit)
    }

    func testLivePhotoKeysFromBeforeEditsStillRead() {
        // Queues on phones today hold video halves under this exact key. They
        // have to keep resolving to their photo, or those uploads stall.
        let queued = photo + "#pairedVideo"
        XCTAssertEqual(BackupKey.pairedVideo(of: photo), queued)
        XCTAssertEqual(BackupKey.kind(queued), .pairedVideo)
        XCTAssertEqual(BackupKey.photo(queued), photo)
    }

    func testTheKeysOfOnePhotoAreAllDifferent() {
        let keys = [
            photo,
            BackupKey.pairedVideo(of: photo),
            BackupKey.edit(of: photo, editedAt: edited),
        ]
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testTheSameEditIsTheSameKey() {
        // Re-finding an edit on the next scan must not look like a new one. The
        // date comes back through PhotoKit with its fraction of a second intact
        // or not; either way it is the same edit.
        let again = Date(timeIntervalSince1970: 1_790_000_123.02)
        XCTAssertEqual(
            BackupKey.edit(of: photo, editedAt: edited),
            BackupKey.edit(of: photo, editedAt: again)
        )
    }

    func testALaterEditIsANewKey() {
        XCTAssertNotEqual(
            BackupKey.edit(of: photo, editedAt: edited),
            BackupKey.edit(of: photo, editedAt: edited.addingTimeInterval(60))
        )
    }

    func testEditsAreNamedTheWayAppleNamesThem() {
        XCTAssertEqual(
            BackupKey.editedFilename(original: "IMG_1234.HEIC", renderExtension: "jpeg"),
            "IMG_E1234.JPEG"
        )
        XCTAssertEqual(
            BackupKey.editedFilename(original: "IMG_1234.heic", renderExtension: "HEIC"),
            "IMG_E1234.heic"
        )
        // A trimmed video keeps its container.
        XCTAssertEqual(
            BackupKey.editedFilename(original: "IMG_0042.MOV", renderExtension: "mov"),
            "IMG_E0042.MOV"
        )
    }

    func testTheSameFormatKeepsTheOriginalsSpelling() {
        // What PhotoKit actually reports for an edited JPEG: `.jpeg`, beside a
        // camera's `.JPG`. Seen on the simulator, where it went up as
        // `p3_E.jpeg` beside `p3.jpg`.
        XCTAssertEqual(
            BackupKey.editedFilename(original: "IMG_0127.JPG", renderExtension: "jpeg"),
            "IMG_E0127.JPG"
        )
        XCTAssertEqual(
            BackupKey.editedFilename(original: "p3.jpg", renderExtension: "jpeg"),
            "p3_E.jpg"
        )
        XCTAssertEqual(
            BackupKey.renderFilename(original: "IMG_0127.JPG", renderExtension: "jpeg"),
            "IMG_0127.JPG"
        )
    }

    func testAPhotoEditedBeforeItWentUpKeepsItsOwnName() {
        XCTAssertEqual(
            BackupKey.renderFilename(original: "IMG_1234.HEIC", renderExtension: "jpeg"),
            "IMG_1234.JPEG"
        )
        XCTAssertEqual(
            BackupKey.renderFilename(original: "IMG_1234.heic", renderExtension: "HEIC"),
            "IMG_1234.heic"
        )
        XCTAssertEqual(
            BackupKey.renderFilename(original: "IMG_0042.MOV", renderExtension: "mov"),
            "IMG_0042.MOV"
        )
    }

    func testANameNotInApplesShapeStillReadsAsAnEdit() {
        XCTAssertEqual(
            BackupKey.editedFilename(original: "DSC_0099.JPG", renderExtension: "jpg"),
            "DSC_0099_E.JPG"
        )
        XCTAssertEqual(
            BackupKey.editedFilename(original: "screenshot", renderExtension: "png"),
            "screenshot_E.png"
        )
    }
}
