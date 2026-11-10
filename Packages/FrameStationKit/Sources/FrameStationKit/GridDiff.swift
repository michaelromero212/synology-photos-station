import Foundation

/// How the library grid changed between two drawings of it: which days came
/// and went, and inside the days that stayed, which tiles came, went or moved.
///
/// This is what lets the grid animate a change instead of redrawing it. A
/// photograph deleted, or one arriving from a backup, used to reload the whole
/// grid, so every tile after it jumped to its new place in a single frame.
/// Photos slides them there instead, and closes the gap the way a hand would.
/// To do that a collection view has to be told exactly what happened, tile by
/// tile, and it checks the arithmetic: an update that doesn't add up stops the
/// app. So the bookkeeping is a pure function, here, where it can be tested
/// without UIKit.
///
/// It is worked out from each day's key and count, and only for the few days
/// whose count changed does it look at what the tiles are — a library of
/// sixty thousand photographs is thousands of days, and building every one's
/// tiles to compare them would cost more than the reload it replaces. A day
/// whose count didn't change keeps every tile where it was; whatever changed
/// inside it is redrawn in place, as before.
public struct GridDiff: Equatable, Sendable {
    /// A tile: its day, and its place in that day.
    public struct Path: Hashable, Sendable {
        public let section: Int
        public let item: Int

        public init(section: Int, item: Int) {
            self.section = section
            self.item = item
        }
    }

    /// A tile that is still there, somewhere else in the same day.
    public struct Move: Hashable, Sendable {
        public let from: Path
        public let to: Path
    }

    /// What the tiles of one day are, so a change can be told apart from a
    /// shuffle.
    public enum Tiles<ID: Hashable> {
        /// Each tile's identity, in order, before and after.
        case identified(old: [ID], new: [ID])
        /// Nothing to tell the tiles apart by: placeholders for a day that
        /// hasn't loaded. Position is identity then, so the first tiles stay
        /// where they are and the change is at the end.
        case positional
    }

    /// Each old day's index now, or nil if it's gone.
    public private(set) var sectionOldToNew: [Int?] = []
    /// Each new day's index before, or nil if it's new.
    public private(set) var sectionNewToOld: [Int?] = []
    /// For days that stayed and changed, each old tile's index now, or nil if
    /// it's gone. By the day's old index.
    private var itemsOldToNew: [Int: [Int?]] = [:]
    /// The same the other way: each new tile's index before, or nil if it's
    /// new. By the day's new index.
    private var itemsNewToOld: [Int: [Int?]] = [:]

    public private(set) var deletedSections = IndexSet()
    public private(set) var insertedSections = IndexSet()
    /// In days that stayed, the tiles that are gone, at their old places.
    public private(set) var deletedItems: [Path] = []
    /// In days that stayed, the tiles that are new, at their new places.
    public private(set) var insertedItems: [Path] = []
    /// In days that stayed, the tiles that changed places within their day —
    /// as opposed to the ones simply carried along by what came and went
    /// around them, which a collection view works out for itself.
    public private(set) var movedItems: [Move] = []

    /// The days that stayed and whose tiles changed, by their new index.
    public var changedSections: [Int] { itemsNewToOld.keys.sorted() }

    /// Whether anything at all comes, goes or moves.
    public var isEmpty: Bool {
        deletedSections.isEmpty && insertedSections.isEmpty
            && deletedItems.isEmpty && insertedItems.isEmpty && movedItems.isEmpty
    }

    // MARK: - Reading it

    public func newSection(forOld section: Int) -> Int? {
        sectionOldToNew.indices.contains(section) ? sectionOldToNew[section] : nil
    }

    public func oldSection(forNew section: Int) -> Int? {
        sectionNewToOld.indices.contains(section) ? sectionNewToOld[section] : nil
    }

    /// Where a tile that was there before has gone, or nil if it went, with
    /// its day or on its own.
    public func newPath(forOld path: Path) -> Path? {
        guard let section = newSection(forOld: path.section) else { return nil }
        guard let map = itemsOldToNew[path.section] else {
            return Path(section: section, item: path.item)
        }
        guard map.indices.contains(path.item), let item = map[path.item] else { return nil }
        return Path(section: section, item: item)
    }

    /// Where a tile that is there now was before, or nil if it's new.
    public func oldPath(forNew path: Path) -> Path? {
        guard let section = oldSection(forNew: path.section) else { return nil }
        guard let map = itemsNewToOld[path.section] else {
            return Path(section: section, item: path.item)
        }
        guard map.indices.contains(path.item), let item = map[path.item] else { return nil }
        return Path(section: section, item: item)
    }

    // MARK: - Working it out

    /// The change from one library to the next, or nil when it isn't one the
    /// grid should animate — days out of order, or too much of the library
    /// changed at once to be worth watching. A reload is right for those, and
    /// is what they always had.
    ///
    /// `tiles` is asked about each day that stayed and whose count changed,
    /// with its key and both counts, and only those.
    public static func between<ID: Hashable>(
        oldKeys: [String], oldCounts: [Int],
        newKeys: [String], newCounts: [Int],
        maximumChangedDays: Int = 64,
        tiles: (_ key: String, _ oldCount: Int, _ newCount: Int) -> Tiles<ID>
    ) -> GridDiff? {
        guard oldKeys.count == oldCounts.count, newKeys.count == newCounts.count,
              !oldCounts.contains(where: { $0 < 0 }), !newCounts.contains(where: { $0 < 0 })
        else { return nil }
        var oldIndex: [String: Int] = [:]
        oldIndex.reserveCapacity(oldKeys.count)
        for (index, key) in oldKeys.enumerated() {
            guard oldIndex.updateValue(index, forKey: key) == nil else { return nil }
        }
        var newIndex: [String: Int] = [:]
        newIndex.reserveCapacity(newKeys.count)
        for (index, key) in newKeys.enumerated() {
            guard newIndex.updateValue(index, forKey: key) == nil else { return nil }
        }

        var diff = GridDiff()
        diff.sectionOldToNew = oldKeys.map { newIndex[$0] }
        diff.sectionNewToOld = newKeys.map { oldIndex[$0] }

        // The days that stayed keep their order. A collection view can move
        // whole days, but days are dates and never trade places, so a library
        // where they did is not a change worth animating.
        var last = -1
        for case let index? in diff.sectionOldToNew {
            guard index > last else { return nil }
            last = index
        }
        // And some of them stayed. A library where none did — a change of
        // density, every day become a month — is a different library, not a
        // change to this one.
        guard last >= 0 || oldKeys.isEmpty || newKeys.isEmpty else { return nil }

        for (index, new) in diff.sectionOldToNew.enumerated() where new == nil {
            diff.deletedSections.insert(index)
        }
        for (index, old) in diff.sectionNewToOld.enumerated() where old == nil {
            diff.insertedSections.insert(index)
        }
        var changedDays = diff.deletedSections.count + diff.insertedSections.count
        guard changedDays <= maximumChangedDays else { return nil }

        for (old, new) in diff.sectionOldToNew.enumerated() {
            guard let new, oldCounts[old] != newCounts[new] else { continue }
            changedDays += 1
            guard changedDays <= maximumChangedDays else { return nil }
            let oldCount = oldCounts[old], newCount = newCounts[new]
            let maps: Maps
            switch tiles(oldKeys[old], oldCount, newCount) {
            case .identified(let before, let after)
                where before.count == oldCount && after.count == newCount
                    // A sequence diff costs the product of the two counts at
                    // worst. A day this big that changed is told by position.
                    && oldCount + newCount <= 4000:
                maps = identified(before, after)
            default:
                maps = positional(oldCount, newCount)
            }
            diff.itemsOldToNew[old] = maps.oldToNew
            diff.itemsNewToOld[new] = maps.newToOld
            for (item, to) in maps.oldToNew.enumerated() {
                guard let to else {
                    diff.deletedItems.append(Path(section: old, item: item))
                    continue
                }
                if maps.moved.contains(item) {
                    diff.movedItems.append(Move(
                        from: Path(section: old, item: item), to: Path(section: new, item: to)
                    ))
                }
            }
            for (item, from) in maps.newToOld.enumerated() where from == nil {
                diff.insertedItems.append(Path(section: new, item: item))
            }
        }
        return diff
    }

    /// Whether the change takes the old counts to the new ones exactly — the
    /// arithmetic a collection view checks before it will animate anything.
    /// The grid asks before every animated update and reloads instead if not.
    public func isConsistent(oldCounts: [Int], newCounts: [Int]) -> Bool {
        guard sectionOldToNew.count == oldCounts.count,
              sectionNewToOld.count == newCounts.count
        else { return false }
        for (old, new) in sectionOldToNew.enumerated() {
            guard let new else { continue }
            guard sectionNewToOld.indices.contains(new), sectionNewToOld[new] == old else { return false }
        }
        for (new, old) in sectionNewToOld.enumerated() {
            guard let old else { continue }
            guard sectionOldToNew.indices.contains(old), sectionOldToNew[old] == new else { return false }
        }
        var deleted: [Int: Set<Int>] = [:]
        for path in deletedItems {
            guard oldCounts.indices.contains(path.section),
                  (0..<oldCounts[path.section]).contains(path.item),
                  newSection(forOld: path.section) != nil,
                  deleted[path.section, default: []].insert(path.item).inserted
            else { return false }
        }
        var inserted: [Int: Set<Int>] = [:]
        for path in insertedItems {
            guard newCounts.indices.contains(path.section),
                  (0..<newCounts[path.section]).contains(path.item),
                  oldSection(forNew: path.section) != nil,
                  inserted[path.section, default: []].insert(path.item).inserted
            else { return false }
        }
        var movedFrom: [Int: Set<Int>] = [:]
        var movedTo: [Int: Set<Int>] = [:]
        for move in movedItems {
            guard oldCounts.indices.contains(move.from.section),
                  (0..<oldCounts[move.from.section]).contains(move.from.item),
                  newCounts.indices.contains(move.to.section),
                  (0..<newCounts[move.to.section]).contains(move.to.item),
                  newSection(forOld: move.from.section) == move.to.section,
                  !deleted[move.from.section, default: []].contains(move.from.item),
                  !inserted[move.to.section, default: []].contains(move.to.item),
                  movedFrom[move.from.section, default: []].insert(move.from.item).inserted,
                  movedTo[move.to.section, default: []].insert(move.to.item).inserted
            else { return false }
        }
        // Every day that stayed ends up with exactly its new count.
        for (old, new) in sectionOldToNew.enumerated() {
            guard let new else { continue }
            let gone = deleted[old]?.count ?? 0
            let came = inserted[new]?.count ?? 0
            guard oldCounts[old] - gone + came == newCounts[new] else { return false }
        }
        return true
    }

    // MARK: - One day

    private struct Maps {
        var oldToNew: [Int?]
        var newToOld: [Int?]
        /// Old places of the tiles matched up as moves.
        var moved: Set<Int> = []
    }

    /// Tile maps from identities: a sequence diff, with tiles that changed
    /// places within the day matched up as moves.
    private static func identified<ID: Hashable>(_ before: [ID], _ after: [ID]) -> Maps {
        var maps = Maps(
            oldToNew: [Int?](repeating: nil, count: before.count),
            newToOld: [Int?](repeating: nil, count: after.count)
        )
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in after.difference(from: before).inferringMoves() {
            switch change {
            case .remove(let offset, _, let associated):
                removed.insert(offset)
                if let associated {
                    maps.oldToNew[offset] = associated
                    maps.newToOld[associated] = offset
                    maps.moved.insert(offset)
                }
            case .insert(let offset, _, let associated):
                inserted.insert(offset)
                if let associated {
                    maps.oldToNew[associated] = offset
                    maps.newToOld[offset] = associated
                    maps.moved.insert(associated)
                }
            }
        }
        // What the diff didn't touch is the same tiles in the same order on
        // both sides: pair them off.
        var next = 0
        for old in before.indices where !removed.contains(old) {
            while next < after.count, inserted.contains(next) { next += 1 }
            guard next < after.count else { break }
            maps.oldToNew[old] = next
            maps.newToOld[next] = old
            next += 1
        }
        return maps
    }

    /// Tile maps by position: the first tiles stay, the rest come or go.
    private static func positional(_ oldCount: Int, _ newCount: Int) -> Maps {
        let common = min(oldCount, newCount)
        return Maps(
            oldToNew: (0..<oldCount).map { $0 < common ? $0 : nil },
            newToOld: (0..<newCount).map { $0 < common ? $0 : nil }
        )
    }
}
