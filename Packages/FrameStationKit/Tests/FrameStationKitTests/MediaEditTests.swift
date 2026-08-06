import FrameStationAPI
import FrameStationKit
import XCTest

/// Both halves of "edit this photo's record" are arithmetic, and both have a
/// failure mode that is quiet and awful: a transposed orientation puts a
/// handful of photos sideways, and a bad shift moves a whole holiday to the
/// wrong week. Neither shows up in a build.
final class MediaEditTests: XCTestCase {

    private func item(_ offsetSeconds: TimeInterval, ratio: Double = 1) -> TimelineItem {
        TimelineItem(
            id: UUID(), spaceID: UUID(), assetID: UUID(),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + offsetSeconds),
            aspectRatio: ratio, mediaType: .photo, durationMs: nil, thumbHash: nil,
            isFavorite: false, uploadedBy: UUID(), isDerived: true
        )
    }

    // MARK: - Orientation

    /// Four right turns is where you started. Any table with a typo in it fails
    /// this for at least one starting orientation.
    func testFourQuarterTurnsReturnToStart() {
        for start in 1...8 {
            var value = start
            for _ in 0..<4 { value = ExifOrientation.rotated(value, by: .right) }
            XCTAssertEqual(value, start, "right turns from \(start)")

            value = start
            for _ in 0..<4 { value = ExifOrientation.rotated(value, by: .left) }
            XCTAssertEqual(value, start, "left turns from \(start)")
        }
    }

    func testLeftAndRightAreInverses() {
        for start in 1...8 {
            let there = ExifOrientation.rotated(start, by: .right)
            XCTAssertEqual(ExifOrientation.rotated(there, by: .left), start)
        }
    }

    func testUpsideDownIsTwoRightTurns() {
        for start in 1...8 {
            let twice = ExifOrientation.rotated(
                ExifOrientation.rotated(start, by: .right), by: .right
            )
            XCTAssertEqual(ExifOrientation.rotated(start, by: .upsideDown), twice)
        }
    }

    /// Mirrored orientations are rare but real — front cameras and scanners
    /// produce them — and a table that drops them un-mirrors someone's photo
    /// the first time they straighten it.
    func testMirroredOrientationsStayMirrored() {
        let mirrored: Set<Int> = [2, 4, 5, 7]
        for start in mirrored {
            for rotation in MediaRotation.allCases {
                XCTAssertTrue(
                    mirrored.contains(ExifOrientation.rotated(start, by: rotation)),
                    "\(start) rotated \(rotation) should stay mirrored"
                )
            }
        }
    }

    func testMissingOrGarbageOrientationIsTreatedAsUnrotated() {
        XCTAssertEqual(ExifOrientation.normalize(nil), 1)
        XCTAssertEqual(ExifOrientation.normalize(0), 1)
        XCTAssertEqual(ExifOrientation.normalize(99), 1)
        XCTAssertEqual(ExifOrientation.rotated(nil, by: .right), 6)
    }

    /// The bug this whole helper exists for: a portrait iPhone photo is stored
    /// 4032×3024 with orientation 6, and reporting that ratio straight through
    /// lays every portrait shot out landscape in the justified grid.
    func testPortraitPhotoReportsAPortraitRatio() {
        let ratio = try? XCTUnwrap(
            ExifOrientation.aspectRatio(width: 4032, height: 3024, orientation: 6)
        )
        XCTAssertNotNil(ratio)
        XCTAssertLessThan(ratio ?? 99, 1, "orientation 6 is a quarter turn — this is portrait")

        // And an unrotated landscape photo is left alone.
        XCTAssertEqual(
            ExifOrientation.aspectRatio(width: 4032, height: 3024, orientation: 1) ?? 0,
            4032.0 / 3024.0, accuracy: 0.0001
        )
    }

    func testAspectRatioIsNilWhenDimensionsAreUnknown() {
        XCTAssertNil(ExifOrientation.aspectRatio(width: nil, height: 100, orientation: 1))
        XCTAssertNil(ExifOrientation.aspectRatio(width: 0, height: 100, orientation: 1))
    }

    // MARK: - Capture time

    func testShiftMovesEverythingAndKeepsTheGaps() {
        let items = [item(0), item(60), item(3600)]
        let anchor = try? XCTUnwrap(CaptureTimeEdit.anchor(in: items))
        let target = (anchor?.capturedAt ?? .now).addingTimeInterval(-7200)

        let plan = CaptureTimeEdit.plan(items: items, mode: .shift, target: target)
        XCTAssertEqual(plan.count, 3)

        // Anchor lands exactly on the target…
        XCTAssertEqual(
            plan[0].capturedAt.timeIntervalSince1970, target.timeIntervalSince1970,
            accuracy: 0.001
        )
        // …and the original spacing survives.
        XCTAssertEqual(
            plan[1].capturedAt.timeIntervalSince(plan[0].capturedAt), 60, accuracy: 0.001
        )
        XCTAssertEqual(
            plan[2].capturedAt.timeIntervalSince(plan[0].capturedAt), 3600, accuracy: 0.001
        )
    }

    func testSetAllCollapsesEverythingOntoOneMoment() {
        let items = [item(0), item(60), item(3600)]
        let target = Date(timeIntervalSince1970: 1_600_000_000)
        let plan = CaptureTimeEdit.plan(items: items, mode: .setAll, target: target)

        XCTAssertEqual(plan.count, 3)
        for entry in plan {
            XCTAssertEqual(
                entry.capturedAt.timeIntervalSince1970, target.timeIntervalSince1970,
                accuracy: 0.001
            )
        }
    }

    /// The anchor is the earliest shot, not whichever was tapped first, so the
    /// same selection always produces the same edit.
    func testAnchorIsTheEarliestRegardlessOfOrder() {
        let early = item(0), middle = item(60), late = item(3600)
        XCTAssertEqual(CaptureTimeEdit.anchor(in: [late, early, middle])?.id, early.id)
        XCTAssertEqual(CaptureTimeEdit.anchor(in: [early, middle, late])?.id, early.id)
    }

    func testEmptySelectionPlansNothing() {
        XCTAssertNil(CaptureTimeEdit.anchor(in: []))
        XCTAssertTrue(CaptureTimeEdit.plan(items: [], mode: .shift, target: .now).isEmpty)
    }

    func testEveryPlannedItemKeepsItsOwnAssetID() {
        let items = [item(0), item(60)]
        let plan = CaptureTimeEdit.plan(items: items, mode: .shift, target: .now)
        XCTAssertEqual(Set(plan.map(\.assetID)), Set(items.map(\.assetID)))
    }
}
