import FrameStationKit
import XCTest

/// The bookkeeping behind the grid's animated changes.
///
/// A collection view checks every batch update against the counts before and
/// after, and an update that doesn't add up ends the app rather than the
/// animation. So these test the arithmetic directly, and the last of them
/// throws a few thousand random libraries at it to make sure nothing it
/// produces can ever be one of those.
final class GridDiffTests: XCTestCase {
    private typealias Path = GridDiff.Path

    /// A library described as days of tile names.
    private func diff(
        _ before: [(String, [String])], _ after: [(String, [String])],
        maximumChangedDays: Int = 64
    ) -> GridDiff? {
        let old = Dictionary(uniqueKeysWithValues: before)
        let new = Dictionary(uniqueKeysWithValues: after)
        return GridDiff.between(
            oldKeys: before.map(\.0), oldCounts: before.map(\.1.count),
            newKeys: after.map(\.0), newCounts: after.map(\.1.count),
            maximumChangedDays: maximumChangedDays
        ) { key, _, _ in
            .identified(old: old[key] ?? [], new: new[key] ?? [])
        }
    }

    private func assertConsistent(
        _ diff: GridDiff?, _ before: [(String, [String])], _ after: [(String, [String])],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let diff else { return XCTFail("no diff", file: file, line: line) }
        XCTAssertTrue(
            diff.isConsistent(oldCounts: before.map(\.1.count), newCounts: after.map(\.1.count)),
            file: file, line: line
        )
    }

    func testAnUnchangedLibraryChangesNothing() throws {
        let library = [("2026-11-01", ["a", "b"]), ("2026-11-02", ["c"])]
        let diff = try XCTUnwrap(self.diff(library, library))
        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(diff.newPath(forOld: Path(section: 1, item: 0)), Path(section: 1, item: 0))
        assertConsistent(diff, library, library)
    }

    func testADeletedPhotoClosesItsGap() throws {
        let before = [("2026-11-01", ["a", "b", "c", "d"]), ("2026-11-02", ["e"])]
        let after = [("2026-11-01", ["a", "c", "d"]), ("2026-11-02", ["e"])]
        let diff = try XCTUnwrap(self.diff(before, after))
        XCTAssertEqual(diff.deletedItems, [Path(section: 0, item: 1)])
        XCTAssertTrue(diff.insertedItems.isEmpty)
        XCTAssertTrue(diff.movedItems.isEmpty)
        // Everything after it moves back one place; nothing before it moves.
        XCTAssertEqual(diff.newPath(forOld: Path(section: 0, item: 0)), Path(section: 0, item: 0))
        XCTAssertNil(diff.newPath(forOld: Path(section: 0, item: 1)))
        XCTAssertEqual(diff.newPath(forOld: Path(section: 0, item: 3)), Path(section: 0, item: 2))
        XCTAssertEqual(diff.oldPath(forNew: Path(section: 0, item: 1)), Path(section: 0, item: 2))
        XCTAssertEqual(diff.newPath(forOld: Path(section: 1, item: 0)), Path(section: 1, item: 0))
        XCTAssertEqual(diff.changedSections, [0])
        assertConsistent(diff, before, after)
    }

    func testANewPhotoOpensAPlace() throws {
        let before = [("2026-11-09", ["a", "b"])]
        let after = [("2026-11-09", ["a", "new", "b"])]
        let diff = try XCTUnwrap(self.diff(before, after))
        XCTAssertEqual(diff.insertedItems, [Path(section: 0, item: 1)])
        XCTAssertNil(diff.oldPath(forNew: Path(section: 0, item: 1)))
        XCTAssertEqual(diff.oldPath(forNew: Path(section: 0, item: 2)), Path(section: 0, item: 1))
        assertConsistent(diff, before, after)
    }

    func testTheFirstPhotoOfADayBringsTheDay() throws {
        let before = [("2026-11-07", ["a"]), ("2026-11-08", ["b"])]
        let after = [("2026-11-07", ["a"]), ("2026-11-08", ["b"]), ("2026-11-09", ["c"])]
        let diff = try XCTUnwrap(self.diff(before, after))
        XCTAssertEqual(diff.insertedSections, IndexSet([2]))
        XCTAssertTrue(diff.insertedItems.isEmpty, "a new day's tiles come with it")
        XCTAssertNil(diff.oldPath(forNew: Path(section: 2, item: 0)))
        assertConsistent(diff, before, after)
    }

    func testTheLastPhotoOfADayTakesTheDay() throws {
        let before = [("2026-11-07", ["a"]), ("2026-11-08", ["b"]), ("2026-11-09", ["c"])]
        let after = [("2026-11-07", ["a"]), ("2026-11-09", ["c"])]
        let diff = try XCTUnwrap(self.diff(before, after))
        XCTAssertEqual(diff.deletedSections, IndexSet([1]))
        XCTAssertNil(diff.newPath(forOld: Path(section: 1, item: 0)))
        XCTAssertEqual(diff.newPath(forOld: Path(section: 2, item: 0)), Path(section: 1, item: 0))
        XCTAssertEqual(diff.oldSection(forNew: 1), 2)
        assertConsistent(diff, before, after)
    }

    func testAnUploadFinishingInPlaceMovesNothing() throws {
        // The local tile and the server's copy share an identity, and the
        // count doesn't change, so the day isn't even looked at.
        var asked = 0
        let diff = try XCTUnwrap(GridDiff.between(
            oldKeys: ["2026-11-09"], oldCounts: [3],
            newKeys: ["2026-11-09"], newCounts: [3]
        ) { _, _, _ -> GridDiff.Tiles<String> in
            asked += 1
            return .positional
        })
        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(asked, 0)
    }

    func testAPhotoThatChangedPlacesIsAMove() throws {
        let before = [("2026-11-09", ["a", "b", "c", "d"])]
        let after = [("2026-11-09", ["a", "c", "d", "b", "e"])]
        let diff = try XCTUnwrap(self.diff(before, after))
        XCTAssertEqual(diff.insertedItems, [Path(section: 0, item: 4)])
        XCTAssertTrue(diff.deletedItems.isEmpty)
        XCTAssertEqual(diff.movedItems.count, 1)
        // Whichever the diff chose to call the move, every tile lands in its
        // new place.
        for (old, name) in before[0].1.enumerated() {
            let new = try XCTUnwrap(diff.newPath(forOld: Path(section: 0, item: old)))
            XCTAssertEqual(after[0].1[new.item], name)
        }
        assertConsistent(diff, before, after)
    }

    func testPlaceholdersChangeAtTheEnd() throws {
        let diff = try XCTUnwrap(GridDiff.between(
            oldKeys: ["2026-11-09"], oldCounts: [5],
            newKeys: ["2026-11-09"], newCounts: [3]
        ) { _, _, _ -> GridDiff.Tiles<String> in .positional })
        XCTAssertEqual(diff.deletedItems, [Path(section: 0, item: 3), Path(section: 0, item: 4)])
        XCTAssertEqual(diff.newPath(forOld: Path(section: 0, item: 2)), Path(section: 0, item: 2))
        XCTAssertTrue(diff.isConsistent(oldCounts: [5], newCounts: [3]))
    }

    func testIdentitiesThatDisagreeWithTheCountsFallBackToPosition() throws {
        // The tiles say three before; the layout counted four. The counts are
        // what the collection view checks, so they win.
        let diff = try XCTUnwrap(GridDiff.between(
            oldKeys: ["d"], oldCounts: [4],
            newKeys: ["d"], newCounts: [2]
        ) { _, _, _ in .identified(old: ["a", "b", "c"], new: ["a", "c"]) })
        XCTAssertEqual(diff.deletedItems, [Path(section: 0, item: 2), Path(section: 0, item: 3)])
        XCTAssertTrue(diff.isConsistent(oldCounts: [4], newCounts: [2]))
    }

    func testDuplicateIdentitiesStillAddUp() throws {
        let before = [("d", ["a", "a", "b", "a"])]
        let after = [("d", ["a", "b", "a", "a", "a"])]
        let diff = try XCTUnwrap(self.diff(before, after))
        assertConsistent(diff, before, after)
    }

    func testDaysOutOfOrderAreAReload() {
        let before = [("a", ["1"]), ("b", ["2"])]
        let after = [("b", ["2"]), ("a", ["1"])]
        XCTAssertNil(diff(before, after))
    }

    func testRepeatedKeysAreAReload() {
        XCTAssertNil(GridDiff.between(
            oldKeys: ["a", "a"], oldCounts: [1, 1],
            newKeys: ["a"], newCounts: [1]
        ) { _, _, _ -> GridDiff.Tiles<String> in .positional })
    }

    func testTooMuchAtOnceIsAReload() {
        let before = (0..<10).map { (String(format: "d%02d", $0), ["x"]) }
        let after = (0..<10).map { (String(format: "d%02d", $0), ["x", "y"]) }
        XCTAssertNil(diff(before, after, maximumChangedDays: 5))
        XCTAssertNotNil(diff(before, after, maximumChangedDays: 10))
    }

    func testADensityChangeIsAReload() {
        // Every day replaced by months: all of it changed at once.
        let before = (1...30).map { (String(format: "2026-10-%02d", $0), ["x"]) }
        let after = [("2026-10", Array(repeating: "x", count: 30))]
        XCTAssertNil(diff(before, after))
    }

    /// Random libraries, random changes: whatever comes out must add up, and
    /// every tile must be found again from either side.
    func testEveryChangeAddsUp() {
        var generator = SeededGenerator(seed: 0x5EED)
        for _ in 0..<2000 {
            var before: [(String, [String])] = []
            var after: [(String, [String])] = []
            var serial = 0
            func tile() -> String {
                serial += 1
                return "t\(serial)"
            }
            for day in 0..<Int.random(in: 0...8, using: &generator) {
                let key = String(format: "2026-%03d", day)
                var tiles = (0..<Int.random(in: 0...12, using: &generator)).map { _ in tile() }
                // Now and then a name twice, the way two copies of one photo
                // can share where they came from.
                if tiles.count > 2, Bool.random(using: &generator) { tiles[1] = tiles[0] }
                let keep = Int.random(in: 0..<5, using: &generator) != 0
                if Int.random(in: 0..<6, using: &generator) != 0 { before.append((key, tiles)) }
                guard keep else { continue }
                var changed = tiles.filter { _ in Int.random(in: 0..<4, using: &generator) != 0 }
                for _ in 0..<Int.random(in: 0...3, using: &generator) {
                    changed.insert(tile(), at: Int.random(in: 0...changed.count, using: &generator))
                }
                if changed.count > 1, Bool.random(using: &generator) { changed.shuffle(using: &generator) }
                after.append((key, changed))
            }
            guard let diff = diff(before, after) else { continue }
            assertConsistent(diff, before, after)
            for (section, day) in before.enumerated() {
                for item in day.1.indices {
                    let old = Path(section: section, item: item)
                    guard let new = diff.newPath(forOld: old) else { continue }
                    XCTAssertEqual(diff.oldPath(forNew: new), old)
                }
            }
        }
    }
}

/// The same random libraries every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
