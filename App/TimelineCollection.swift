#if os(iOS)
import FrameStationAPI
import FrameStationKit
import SwiftUI
import UIKit

// MARK: - Layout

/// Places every day heading and every tile from the manifest's counts, before a
/// single day has loaded.
///
/// This is the reason the grid is a collection view at all. The SwiftUI
/// grid it replaces was a `LazyVStack` of days, and a lazy stack only knows the
/// height of a day it has built; every other day's height is a guess, revised as
/// days are built and torn down. On his phone the revisions were continuous — +2,
/// +24, +185, +513 points while scrolling, a whole-library swing of about a third
/// as he moved back and forth, and twice a jump of a screen and a half at once —
/// and each one moved the photographs under his finger. The simulator never showed
/// it, because it restores every day from disk at launch and so never loads one
/// mid-scroll; with that snapshot cleared it reproduced at once: twenty-six height
/// changes and thirty-eight dropped frames across two flings.
///
/// A square grid needs nothing loaded to be measured. A day of `n` entries is a
/// heading and `ceil(n / columns)` rows of `side`, so this computes every position
/// up front and the content never changes size unless the library itself does.
/// Nothing is estimated, so nothing is revised, so nothing moves.
///
/// Square grids only: iPhone and iPad. The justified rows on the Mac and the
/// television are sized from aspect ratios that are unknown until a day loads,
/// so there is nothing exact to compute there and they keep the SwiftUI grid.
final class TimelineGridLayout: UICollectionViewLayout {
    static let libraryHeaderKind = "library-header"
    /// The line naming a place, inside a day spent in more than one.
    static let areaHeaderKind = "area-header"

    struct Shape: Equatable {
        /// Entries per day, in drawing order: loaded photographs, placeholders
        /// standing in for ones that aren't, and tiles still on this phone.
        var counts: [Int]
        /// For a day spent in more than one area, how many entries each area
        /// draws, in order. They add up to that day's count. Empty for every
        /// other day, which draws as one run, as days always did.
        var areas: [[Int]]
        /// Tiles across a phone at this zoom. A wider grid fits more — see
        /// `columnCount`.
        var columns: Int
        var spacing: CGFloat
        var headerHeight: CGFloat
        /// A place line's height, top padding to bottom.
        var areaHeaderHeight: CGFloat
        /// The library's count above the oldest day. Zero for none.
        var libraryHeaderHeight: CGFloat

        /// Whether `next` is this library with photographs added or taken
        /// away, as opposed to the same photographs drawn another way — a
        /// change of density, or of the headings' sizes. Only the first is
        /// animated; see `TimelineCollection.Coordinator.animatableChange`.
        func drawsLike(_ next: Shape) -> Bool {
            columns == next.columns && spacing == next.spacing
                && headerHeight == next.headerHeight
                && areaHeaderHeight == next.areaHeaderHeight
                && libraryHeaderHeight == next.libraryHeaderHeight
        }
    }

    /// One area's tiles within a day: its first entry, how many, and where its
    /// first row starts below the day's top.
    struct Run {
        let first: Int
        let count: Int
        let top: CGFloat
    }

    /// Where everything goes, for one shape at one width: what `prepare` works
    /// out, and everything that is asked of the layout is answered from it.
    ///
    /// A value rather than the layout's own properties so that the one on
    /// screen can be kept while the grid animates to the next — every tile
    /// that moves is moved from where this says it was. See `beginChange`.
    struct Placement {
        private(set) var shape: Shape
        private(set) var width: CGFloat = 0
        /// Tiles across, for the width the grid has now: `shape.columns` on a
        /// phone, more on an iPad. Worked out here, from the collection view's
        /// own width, so that turning an iPad or resizing it in Split View
        /// reflows the grid in the same layout pass that
        /// `TimelineCollectionView` holds the screen's place across.
        private(set) var columnCount = 1
        private(set) var side: CGFloat = 0
        /// Where each day's heading begins, in content coordinates.
        private(set) var starts: [CGFloat] = []
        /// The areas of each day spent in more than one, by section. Every
        /// other day is a single run starting under its heading, and isn't
        /// stored.
        private(set) var runs: [Int: [Run]] = [:]
        private(set) var height: CGFloat = 0
        private(set) var scale: CGFloat = 3
        /// Empty room above a library too short to fill the screen.
        ///
        /// The grid runs oldest to newest and opens on the newest, so a long
        /// library shows its newest photos resting on the bar at the bottom.
        /// One that fits on screen with room to spare used to start at the top
        /// instead. A shared album of nine photos showed them up under the
        /// clock with half a screen of nothing below, newest in the middle. The
        /// room goes above, so a short library looks the way the end of a long
        /// one does.
        private(set) var lead: CGFloat = 0

        init(shape: Shape) {
            self.shape = shape
        }

        /// Lays `shape` out across `width`, with `visible` points of screen
        /// between the bars for a short library to rest at the bottom of.
        mutating func place(_ shape: Shape, width: CGFloat, scale: CGFloat, visible: CGFloat) {
            self.shape = shape
            self.width = width
            self.scale = scale
            columnCount = PhotoGridMetrics.squareColumns(shape.columns, across: width)
            let columns = columnCount
            // The same arithmetic `PhotoGridSection` used, so the tiles come
            // out the size they always were.
            side = max((width - shape.spacing * CGFloat(columns - 1)) / CGFloat(columns), 1)
            // Before anything is measured: a day's height includes its areas'.
            runs.removeAll(keepingCapacity: true)
            for (section, areas) in shape.areas.enumerated() where areas.count > 1 {
                var laid: [Run] = []
                var first = 0
                var top = shape.headerHeight
                for (index, count) in areas.enumerated() {
                    if index > 0 { top += shape.areaHeaderHeight }
                    laid.append(Run(first: first, count: count, top: top))
                    first += count
                    top += rowsHeight(count)
                }
                runs[section] = laid
            }
            let natural = shape.counts.indices.reduce(shape.libraryHeaderHeight) { $0 + sectionHeight($1) }
            // On a whole device pixel, so every edge below it rounds the way it
            // would without it and the gaps stay crisp.
            let room = shape.counts.isEmpty ? 0 : max(visible - natural, 0)
            lead = (room * scale).rounded(.down) / scale
            starts.removeAll(keepingCapacity: true)
            starts.reserveCapacity(shape.counts.count)
            var y = lead + shape.libraryHeaderHeight
            for section in shape.counts.indices {
                starts.append(y)
                y += sectionHeight(section)
            }
            height = y
        }

        private func rows(_ count: Int) -> Int {
            let columns = columnCount
            return (max(count, 0) + columns - 1) / columns
        }

        /// The rows of `count` tiles, top of the first to bottom of the last.
        private func rowsHeight(_ count: Int) -> CGFloat {
            let rows = rows(count)
            return CGFloat(rows) * side + CGFloat(max(rows - 1, 0)) * shape.spacing
        }

        /// A day's heading, its rows, and the place line before each area
        /// after its first.
        func sectionHeight(_ section: Int) -> CGFloat {
            guard shape.counts.indices.contains(section) else { return 0 }
            if let last = runs[section]?.last { return last.top + rowsHeight(last.count) }
            return shape.headerHeight + rowsHeight(shape.counts[section])
        }

        /// A day's runs: its areas, or the whole day as one.
        func runs(in section: Int) -> [Run] {
            runs[section] ?? [Run(first: 0, count: shape.counts[section], top: shape.headerHeight)]
        }

        /// The run an entry belongs to. A day has a handful of areas at most,
        /// so a scan is all this needs.
        private func run(of item: Int, in section: Int) -> Run {
            let all = runs(in: section)
            return all.last { item >= $0.first } ?? all[0]
        }

        /// Whether this placement has a tile at `item` of `section`.
        func contains(item: Int, inSection section: Int) -> Bool {
            starts.indices.contains(section) && shape.counts.indices.contains(section)
                && item >= 0 && item < shape.counts[section]
        }

        /// The day holding a point in the content. A binary search, because
        /// this is asked every frame of a scroll and a library of 67,000
        /// photographs is a few thousand days.
        func section(at y: CGFloat) -> Int? {
            guard !starts.isEmpty else { return nil }
            if y <= starts[0] { return 0 }
            var low = 0
            var high = starts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if starts[mid] <= y { low = mid } else { high = mid - 1 }
            }
            return low
        }

        func sectionTop(_ section: Int) -> CGFloat? {
            starts.indices.contains(section) ? starts[section] : nil
        }

        /// The first tile of the row at a point inside a day, or nil when the
        /// point is on the day's heading. On a place line, the first tile of
        /// the area it starts.
        func item(at y: CGFloat, inSection section: Int) -> Int? {
            guard starts.indices.contains(section) else { return nil }
            let all = runs(in: section)
            guard y >= starts[section] + all[0].top else { return nil }
            let run = all.last { y >= starts[section] + $0.top - shape.areaHeaderHeight } ?? all[0]
            let gridTop = starts[section] + run.top
            guard y >= gridTop else { return run.count > 0 ? run.first : nil }
            let row = Int((y - gridTop) / (side + shape.spacing))
            let index = row * columnCount
            return index < run.count ? run.first + index : nil
        }

        /// Frames land on whole device pixels, the way SwiftUI's did.
        /// Fractional edges would blur the two-point gaps into gray smears.
        private func pixel(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded() / scale
        }

        func frame(forItem item: Int, inSection section: Int) -> CGRect {
            let columns = columnCount
            let run = run(of: item, in: section)
            let row = (item - run.first) / columns
            let column = (item - run.first) % columns
            let gridTop = starts[section] + run.top
            let x = CGFloat(column) * (side + shape.spacing)
            let y = gridTop + CGFloat(row) * (side + shape.spacing)
            let minX = pixel(x), maxX = pixel(x + side)
            let minY = pixel(y), maxY = pixel(y + side)
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        func headerFrame(_ section: Int) -> CGRect? {
            guard starts.indices.contains(section) else { return nil }
            let top = starts[section]
            let minY = pixel(top)
            return CGRect(x: 0, y: minY, width: width, height: pixel(top + shape.headerHeight) - minY)
        }

        /// The place line above a day's `area`-th area, from the second on.
        func areaHeaderFrame(_ area: Int, inSection section: Int) -> CGRect? {
            guard starts.indices.contains(section),
                  let laid = runs[section], laid.indices.contains(area), area > 0
            else { return nil }
            let bottom = starts[section] + laid[area].top
            let minY = pixel(bottom - shape.areaHeaderHeight)
            return CGRect(x: 0, y: minY, width: width, height: pixel(bottom) - minY)
        }

        /// How many place lines a day has: one above each area after its
        /// first, at area indices 1 through this.
        func areaLines(_ section: Int) -> Int {
            max((runs[section]?.count ?? 1) - 1, 0)
        }

        /// The library's count, above the oldest day, if it has one.
        var libraryFrame: CGRect? {
            guard shape.libraryHeaderHeight > 0 else { return nil }
            return CGRect(x: 0, y: lead, width: width, height: shape.libraryHeaderHeight)
        }

        /// Any heading's frame, by the kind and index path a collection view
        /// names it with.
        func frame(ofSupplementary kind: String, at indexPath: IndexPath) -> CGRect? {
            switch kind {
            case TimelineGridLayout.libraryHeaderKind: return libraryFrame
            case TimelineGridLayout.areaHeaderKind:
                return areaHeaderFrame(indexPath.item, inSection: indexPath.section)
            default: return headerFrame(indexPath.section)
            }
        }
    }

    var shape: Shape {
        didSet { if shape != oldValue { invalidateLayout() } }
    }

    private var placement: Placement
    /// The height the grid was last laid out for. A short library rests on the
    /// bottom, so it moves when the bottom does.
    private var boundsHeight: CGFloat = 0

    init(shape: Shape) {
        self.shape = shape
        self.placement = Placement(shape: shape)
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let displayScale = collectionView.traitCollection.displayScale
        boundsHeight = collectionView.bounds.height
        placement.place(
            shape,
            width: collectionView.bounds.width,
            scale: displayScale > 0 ? displayScale : 3,
            visible: visibleHeight(collectionView, height: boundsHeight)
        )
    }

    /// How much of the grid's height is not under a bar: the content insets
    /// are the bars, set by hand. See `Coordinator.applyInsets`.
    private func visibleHeight(_ collectionView: UICollectionView, height: CGFloat) -> CGFloat {
        max(height - collectionView.contentInset.top - collectionView.contentInset.bottom, 0)
    }

    /// Whether the library is short enough to rest on the bottom at this much
    /// visible height, or was the last time it was laid out. Either way, a
    /// change to the bars or the screen moves it.
    func restsOnBottom(within visible: CGFloat) -> Bool {
        placement.lead > 0 || placement.height - placement.lead < visible
    }

    var columnCount: Int { placement.columnCount }

    func sectionHeight(_ section: Int) -> CGFloat { placement.sectionHeight(section) }

    var contentHeight: CGFloat { placement.height }

    override var collectionViewContentSize: CGSize {
        CGSize(width: placement.width, height: placement.height)
    }

    /// Told that the width is about to change, while everything here still
    /// describes the screen as it is. See `shouldInvalidateLayout`.
    var widthWillChange: (() -> Void)?

    /// Only a change of width changes anything, or of height for a library
    /// resting on the bottom. Scrolling changes nothing.
    ///
    /// Also the one moment to take the screen's place before a new width
    /// moves it. By the time the collection view lays itself out, this layout
    /// has already been prepared for the new width — asked for its content
    /// size along the way — and a place read then describes the new layout at
    /// the old offset: measured, it named whatever had moved under the old
    /// offset, and putting that back moved nothing.
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        if newBounds.width != placement.width {
            widthWillChange?()
            return true
        }
        guard newBounds.height != boundsHeight, let collectionView else { return false }
        return restsOnBottom(within: visibleHeight(collectionView, height: newBounds.height))
    }

    func section(at y: CGFloat) -> Int? { placement.section(at: y) }

    func sectionTop(_ section: Int) -> CGFloat? { placement.sectionTop(section) }

    func item(at y: CGFloat, inSection section: Int) -> Int? {
        placement.item(at: y, inSection: section)
    }

    func frame(forItem item: Int, inSection section: Int) -> CGRect {
        placement.frame(forItem: item, inSection: section)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var result: [UICollectionViewLayoutAttributes] = []
        let placed = placement
        if let library = placed.libraryFrame, rect.minY < library.maxY, rect.maxY > library.minY {
            let attributes = UICollectionViewLayoutAttributes(
                forSupplementaryViewOfKind: Self.libraryHeaderKind, with: IndexPath(item: 0, section: 0)
            )
            attributes.frame = library
            attributes.zIndex = Self.headingZIndex
            result.append(attributes)
        }
        guard var section = placed.section(at: max(rect.minY, 0)) else { return result }
        let columns = placed.columnCount
        let pitch = placed.side + placed.shape.spacing
        while section < placed.starts.count, placed.starts[section] < rect.maxY {
            let top = placed.starts[section]
            if top + placed.sectionHeight(section) > rect.minY {
                if top + placed.shape.headerHeight > rect.minY, let frame = placed.headerFrame(section) {
                    let header = UICollectionViewLayoutAttributes(
                        forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                        with: IndexPath(item: 0, section: section)
                    )
                    header.frame = frame
                    header.zIndex = Self.headingZIndex
                    result.append(header)
                }
                for (area, run) in placed.runs(in: section).enumerated() {
                    let gridTop = top + run.top
                    if area > 0, let line = placed.areaHeaderFrame(area, inSection: section),
                       line.maxY > rect.minY, line.minY < rect.maxY {
                        let header = UICollectionViewLayoutAttributes(
                            forSupplementaryViewOfKind: Self.areaHeaderKind,
                            with: IndexPath(item: area, section: section)
                        )
                        header.frame = line
                        header.zIndex = Self.headingZIndex
                        result.append(header)
                    }
                    let totalRows = (max(run.count, 0) + columns - 1) / columns
                    guard totalRows > 0 else { continue }
                    let first = max(0, Int(floor((rect.minY - gridTop) / pitch)))
                    let last = min(totalRows - 1, Int(floor((rect.maxY - gridTop) / pitch)))
                    guard first <= last else { continue }
                    for row in first...last {
                        for column in 0..<columns {
                            let index = row * columns + column
                            guard index < run.count else { break }
                            let item = run.first + index
                            let attributes = UICollectionViewLayoutAttributes(
                                forCellWith: IndexPath(item: item, section: section)
                            )
                            attributes.frame = placed.frame(forItem: item, inSection: section)
                            result.append(attributes)
                        }
                    }
                }
            }
            section += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard placement.contains(item: indexPath.item, inSection: indexPath.section) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = placement.frame(forItem: indexPath.item, inSection: indexPath.section)
        return attributes
    }

    /// Nil for a heading that isn't there: an area line whose day is down to
    /// one area, a day that has gone.
    override func layoutAttributesForSupplementaryView(
        ofKind kind: String, at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard let frame = placement.frame(ofSupplementary: kind, at: indexPath) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(
            forSupplementaryViewOfKind: kind, with: indexPath
        )
        attributes.frame = frame
        attributes.zIndex = Self.headingZIndex
        return attributes
    }

    /// The library's shape as the scrubber reads it, in this layout's own
    /// coordinates so the two can never disagree about where a day is.
    func span(keys: [String]) -> LibrarySpan {
        var start: [String: Double] = [:]
        var height: [String: Double] = [:]
        start.reserveCapacity(keys.count)
        height.reserveCapacity(keys.count)
        for (index, key) in keys.enumerated() where placement.starts.indices.contains(index) {
            start[key] = Double(placement.starts[index])
            height[key] = Double(placement.sectionHeight(index))
        }
        return LibrarySpan(
            total: Double(placement.height), start: start, height: height,
            order: keys, header: Double(placement.shape.headerHeight)
        )
    }

    // MARK: Animating a change

    /// Where the screen comes to rest once a change has played, in the new
    /// library's terms.
    enum Rest {
        /// On the newest row, which is where the library opens and where it
        /// stays as new photographs arrive.
        case bottom
        /// With this tile's row at the top, as far into it as before.
        case item(section: Int, item: Int, delta: CGFloat)
        /// With this day at the top, as far into it as before.
        case section(Int, delta: CGFloat)
    }

    /// The change being played: where everything was, and how to find each
    /// tile and heading again on the other side.
    private struct Change {
        let from: Placement
        let diff: GridDiff
        let rest: Rest?
        /// The scroll before the change, and after it once the collection
        /// view has asked where to rest — see `targetContentOffset`.
        let fromOffset: CGFloat
        var toOffset: CGFloat?

        /// How far the change scrolls the grid. What comes and goes does so
        /// where it is on screen, so it is moved this far in the content to
        /// stand still while the scroll goes by — a photograph deleted on
        /// screen fades where you were looking at it, rather than drifting
        /// over its neighbors on the way out.
        var scroll: CGFloat { (toOffset ?? fromOffset) - fromOffset }
    }

    private var change: Change?

    /// A heading, as the collection view names it.
    struct Heading: Hashable {
        let kind: String
        let indexPath: IndexPath
    }

    /// The headings the collection view asked to animate out during the
    /// change being worked out. See `Coordinator.animate` for the ones it
    /// doesn't ask about.
    private(set) var headingsAnimatedOut: Set<Heading> = []

    /// Keeps where everything is now, just before a batch update, so each
    /// tile and heading can be animated from there to its new place. Called
    /// with the grid laid out for what is on screen.
    func beginChange(_ diff: GridDiff, resting rest: Rest?) {
        change = Change(
            from: placement, diff: diff, rest: rest,
            fromOffset: collectionView?.contentOffset.y ?? 0
        )
        headingsAnimatedOut.removeAll()
    }

    /// How far the change being played scrolls the grid. See `Change.scroll`.
    var changeScroll: CGFloat { change?.scroll ?? 0 }

    /// The batch update has been worked out and its animations are running;
    /// nothing here is asked about it again.
    func endChange() {
        change = nil
        headingsAnimatedOut.removeAll()
    }

    /// The screen held where it was — the day at the top kept at the top, or
    /// the newest row kept on the bar — in the same animation that moves the
    /// tiles, so a change above the screen moves nothing you can see.
    override func targetContentOffset(forProposedContentOffset proposed: CGPoint) -> CGPoint {
        guard change != nil else {
            return super.targetContentOffset(forProposedContentOffset: proposed)
        }
        let target = resting(proposed)
        change?.toOffset = target.y
        return target
    }

    private func resting(_ proposed: CGPoint) -> CGPoint {
        guard let rest = change?.rest, let collectionView else { return proposed }
        let inset = collectionView.contentInset
        let lowest = -inset.top
        let highest = max(placement.height + inset.bottom - collectionView.bounds.height, lowest)
        let y: CGFloat
        switch rest {
        case .bottom:
            y = highest
        case .item(let section, let item, let delta):
            guard placement.contains(item: item, inSection: section) else { return proposed }
            y = placement.frame(forItem: item, inSection: section).minY + delta - inset.top
        case .section(let section, let delta):
            guard let top = placement.sectionTop(section) else { return proposed }
            y = top + delta - inset.top
        }
        return CGPoint(x: proposed.x, y: min(max(y, lowest), highest))
    }

    /// The headings a change takes away. A collection view works out which
    /// tiles go with a deleted day, but a custom layout names the headings
    /// that come and go itself. The one heading this isn't enough for is the
    /// newest day's — see `Coordinator.droppedHeadings`.
    override func indexPathsToDeleteForSupplementaryView(ofKind kind: String) -> [IndexPath] {
        guard let change else { return super.indexPathsToDeleteForSupplementaryView(ofKind: kind) }
        let diff = change.diff
        switch kind {
        case UICollectionView.elementKindSectionHeader:
            return diff.deletedSections.map { IndexPath(item: 0, section: $0) }
        case Self.areaHeaderKind:
            var paths: [IndexPath] = []
            for old in diff.sectionOldToNew.indices {
                let before = change.from.areaLines(old)
                let after = diff.newSection(forOld: old).map { placement.areaLines($0) } ?? 0
                guard before > after else { continue }
                for area in (after + 1)...before { paths.append(IndexPath(item: area, section: old)) }
            }
            return paths
        case Self.libraryHeaderKind:
            // On the first day's index path, so it is handed to a new view
            // whenever the first day is a different one.
            return change.from.libraryFrame != nil && diff.newSection(forOld: 0) != 0
                ? [IndexPath(item: 0, section: 0)] : []
        default:
            return []
        }
    }

    /// The headings a change brings. See `indexPathsToDeleteForSupplementaryView`.
    override func indexPathsToInsertForSupplementaryView(ofKind kind: String) -> [IndexPath] {
        guard let change else { return super.indexPathsToInsertForSupplementaryView(ofKind: kind) }
        let diff = change.diff
        switch kind {
        case UICollectionView.elementKindSectionHeader:
            return diff.insertedSections.map { IndexPath(item: 0, section: $0) }
        case Self.areaHeaderKind:
            var paths: [IndexPath] = []
            for new in diff.sectionNewToOld.indices {
                let after = placement.areaLines(new)
                let before = diff.oldSection(forNew: new).map { change.from.areaLines($0) } ?? 0
                guard after > before else { continue }
                for area in (before + 1)...after { paths.append(IndexPath(item: area, section: new)) }
            }
            return paths
        case Self.libraryHeaderKind:
            return placement.libraryFrame != nil && diff.oldSection(forNew: 0) != 0
                ? [IndexPath(item: 0, section: 0)] : []
        default:
            return []
        }
    }

    /// A tile coming into view: from where it was, if it was anywhere, or
    /// fading in where it now is if it's new.
    ///
    /// Asked about new tiles, and about tiles the change itself pulls on
    /// screen from somewhere off it — which slide in from there rather than
    /// appear in place. Tiles already on screen the collection view moves
    /// without asking.
    override func initialLayoutAttributesForAppearingItem(
        at itemIndexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard let change, let attributes = layoutAttributesForItem(at: itemIndexPath) else {
            return super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)
        }
        let new = GridDiff.Path(section: itemIndexPath.section, item: itemIndexPath.item)
        if let old = change.diff.oldPath(forNew: new),
           change.from.contains(item: old.item, inSection: old.section) {
            attributes.frame = change.from.frame(forItem: old.item, inSection: old.section)
        } else {
            attributes.frame.origin.y -= change.scroll
            attributes.alpha = 0
        }
        return attributes
    }

    /// Headings sit beneath the tiles. They never overlap at rest, but in a
    /// change the tiles sliding up into a new day's place pass over its
    /// heading as it fades in, rather than under it.
    static let headingZIndex = -1
    /// Beneath everything else, for whatever is fading out: the tiles sliding
    /// into a gap pass over what is leaving it. Something fading in takes its
    /// resting place in the order at once, whatever it starts with.
    static let fadingZIndex = -2

    /// A tile leaving the screen: to where it is going, or fading out where
    /// it was if it's gone.
    override func finalLayoutAttributesForDisappearingItem(
        at itemIndexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard let change else {
            return super.finalLayoutAttributesForDisappearingItem(at: itemIndexPath)
        }
        let old = GridDiff.Path(section: itemIndexPath.section, item: itemIndexPath.item)
        let attributes = UICollectionViewLayoutAttributes(forCellWith: itemIndexPath)
        if let new = change.diff.newPath(forOld: old),
           placement.contains(item: new.item, inSection: new.section) {
            attributes.frame = placement.frame(forItem: new.item, inSection: new.section)
        } else if change.from.contains(item: old.item, inSection: old.section) {
            attributes.frame = change.from.frame(forItem: old.item, inSection: old.section)
                .offsetBy(dx: 0, dy: change.scroll)
            attributes.alpha = 0
            attributes.zIndex = Self.fadingZIndex
        } else {
            return super.finalLayoutAttributesForDisappearingItem(at: itemIndexPath)
        }
        return attributes
    }

    /// The same for headings: a day's heading moves with its day, and comes
    /// and goes with it.
    override func initialLayoutAttributesForAppearingSupplementaryElement(
        ofKind kind: String, at elementIndexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard let change, let attributes = layoutAttributesForSupplementaryView(
            ofKind: kind, at: elementIndexPath
        ) else {
            return super.initialLayoutAttributesForAppearingSupplementaryElement(
                ofKind: kind, at: elementIndexPath
            )
        }
        if let old = change.diff.oldSection(forNew: elementIndexPath.section)
            ?? (kind == Self.libraryHeaderKind ? 0 : nil),
           let frame = change.from.frame(
               ofSupplementary: kind, at: IndexPath(item: elementIndexPath.item, section: old)
           ) {
            attributes.frame = frame
        } else {
            attributes.frame.origin.y -= change.scroll
            attributes.alpha = 0
        }
        return attributes
    }

    override func finalLayoutAttributesForDisappearingSupplementaryElement(
        ofKind kind: String, at elementIndexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard let change else {
            return super.finalLayoutAttributesForDisappearingSupplementaryElement(
                ofKind: kind, at: elementIndexPath
            )
        }
        headingsAnimatedOut.insert(Heading(kind: kind, indexPath: elementIndexPath))
        let attributes = UICollectionViewLayoutAttributes(
            forSupplementaryViewOfKind: kind, with: elementIndexPath
        )
        attributes.zIndex = Self.headingZIndex
        if let new = change.diff.newSection(forOld: elementIndexPath.section)
            ?? (kind == Self.libraryHeaderKind ? 0 : nil),
           let frame = placement.frame(
               ofSupplementary: kind, at: IndexPath(item: elementIndexPath.item, section: new)
           ) {
            attributes.frame = frame
            // The count's line can be handed over to a new view when days
            // come and go below it, and the two say different numbers.
            if kind == Self.libraryHeaderKind { attributes.alpha = 0 }
        } else if let frame = change.from.frame(ofSupplementary: kind, at: elementIndexPath) {
            attributes.frame = frame.offsetBy(dx: 0, dy: change.scroll)
            attributes.alpha = 0
            attributes.zIndex = Self.fadingZIndex
        } else {
            return super.finalLayoutAttributesForDisappearingSupplementaryElement(
                ofKind: kind, at: elementIndexPath
            )
        }
        return attributes
    }
}

// MARK: - Commands

/// How the timeline moves the grid.
///
/// A handle rather than state: a jump is an instruction, not a value to keep in
/// sync, and the SwiftUI grid's history is a lesson in what happens when scroll
/// position is two-way state — every write-back became a re-scroll.
@MainActor
final class TimelineGridController {
    fileprivate weak var coordinator: TimelineCollection.Coordinator?

    /// Puts a day's heading at the top of the screen, just under the floating
    /// bar. Waits for the day to exist if it doesn't yet — a density change
    /// swaps every day for new ones, and the jump arrives alongside them.
    func jump(toDay key: String) {
        coordinator?.jump(toDay: key)
    }

    /// Puts an exact point in the library at the top of the screen. The
    /// scrubber's target, in the layout's own coordinates.
    func scroll(toContentY y: Double) {
        coordinator?.scroll(toContentY: CGFloat(y))
    }

    /// Brings one tile on screen, centered, if it isn't already — and leaves
    /// the grid exactly where it is if it is. Returns whether the tile is on
    /// screen afterward.
    ///
    /// For the viewer, which keeps the grid underneath it following the photo
    /// on screen: moved while it can't be seen, the grid is already in place
    /// when the viewer closes, and the photo zooms straight back into its own
    /// tile.
    @discardableResult
    func reveal(item: Int, inDay key: String) -> Bool {
        coordinator?.reveal(item: item, inDay: key) ?? false
    }

    /// Where a tile is on screen, in window coordinates, after bringing it on
    /// screen. What a photo closing in the viewer flies back to.
    func frameOnScreen(item: Int, inDay key: String) -> CGRect? {
        coordinator?.frameOnScreen(item: item, inDay: key)
    }
}

// MARK: - The grid

/// The library grid on iPhone and iPad: a collection view with SwiftUI cells.
///
/// Everything a tile draws and does is still SwiftUI, built by `TimelineView`
/// exactly as before — the tap, the long press, the selection mark. What moved
/// to UIKit is only the container, which is the part that was estimating.
struct TimelineCollection: UIViewRepresentable {
    struct Section: Equatable {
        let bucket: TimelineBucket
        /// How many tiles the day draws — see `TimelineGridLayout.Shape.counts`.
        let count: Int
        /// A day spent in more than one area, area by area. Empty for any
        /// other day.
        var areas: [Area] = []
    }

    /// One area of a day: how many of its tiles, and the place line above it,
    /// which the first area doesn't have because the day's heading names it.
    struct Area: Equatable {
        let count: Int
        let title: String?
    }

    let sections: [Section]
    let columns: Int
    let spacing: CGFloat
    let headerHeight: CGFloat
    let areaHeaderHeight: CGFloat
    let libraryHeaderHeight: CGFloat
    /// Top: under the floating bar. Bottom: over the tab bar, plus whichever
    /// bar is standing in its place. Applied as the collection view's own
    /// insets, never as a resize — see `Coordinator.update`.
    let topInset: CGFloat
    let bottomInset: CGFloat
    let progress: ScrollProgress
    let controller: TimelineGridController
    let selection: GridSelection
    /// Anything a tile draws that is handed in by value rather than observed —
    /// the moved photo being pointed at, today. A change redraws what's visible.
    let cellContext: AnyHashable?
    let entries: (TimelineBucket) -> [GridEntry]
    let dayItems: (TimelineBucket) -> [TimelineItem]
    let cell: (GridEntry, CGSize, [TimelineItem]) -> AnyView
    let header: (TimelineBucket) -> AnyView
    /// The place line inside a day spent in more than one area.
    let areaHeader: (String) -> AnyView
    let libraryHeader: () -> AnyView
    /// Fetches a day and warms its thumbnails.
    let load: (String) async -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> TimelineCollectionView {
        let layout = TimelineGridLayout(shape: context.coordinator.shape(for: self))
        let view = TimelineCollectionView(frame: .zero, collectionViewLayout: layout)
        context.coordinator.install(on: view, layout: layout)
        return view
    }

    func updateUIView(_ view: TimelineCollectionView, context: Context) {
        context.coordinator.update(from: self)
    }

    static func dismantleUIView(_ view: TimelineCollectionView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate,
        UIGestureRecognizerDelegate {
        private(set) var parent: TimelineCollection
        private weak var view: TimelineCollectionView?
        private var layout: TimelineGridLayout?

        private var keys: [String] = []
        private var sectionIndex: [String: Int] = [:]
        /// Each visible day's entries, worked out once per update rather than
        /// once per tile — a day of three hundred photographs would otherwise
        /// rebuild its list three hundred times as it scrolled in.
        private var entryCache: [Int: [GridEntry]] = [:]
        private var lastContext: AnyHashable?
        private var lastInsets = UIEdgeInsets.zero
        /// Opened on the newest photograph yet. Once, on first layout.
        private var hasLanded = false
        /// What was at the top of the screen as the width began to change.
        /// See `widthWillChange`.
        private var placeBeforeWidthChange: Anchor?
        /// Inside `update`, where reporting has to wait — see `update`.
        private var isUpdating = false
        private var deferredJump: String?
        /// Days being fetched because they are on screen or about to be.
        private var loads: [String: Task<Void, Never>] = [:]
        /// What each day's tiles were the last time they were drawn, by day:
        /// what a change is told against, when a day's count changes. See
        /// `animatableChange`.
        private var drawn: [String: DrawnTiles] = [:]
        /// Bumped for a day each time a change is animated through it. A tile
        /// keeps its cell through a change, and with it the list of the day's
        /// photographs it was built with — the one the viewer walks when the
        /// tile is opened — so a cell built before the change is rebuilt when
        /// it next shows. See `configure`.
        private var dayRevisions: [String: Int] = [:]

        private var sweep: UIPanGestureRecognizer?
        private var sweeping = false
        private var visited: Set<UUID> = []

        private static let cellID = "tile"
        private static let headerID = "day"
        private static let areaID = "area"
        private static let libraryID = "library"

        init(parent: TimelineCollection) {
            self.parent = parent
        }

        func shape(for parent: TimelineCollection) -> TimelineGridLayout.Shape {
            TimelineGridLayout.Shape(
                counts: parent.sections.map(\.count),
                areas: parent.sections.map { $0.areas.count > 1 ? $0.areas.map(\.count) : [] },
                columns: parent.columns,
                spacing: parent.spacing,
                headerHeight: parent.headerHeight,
                areaHeaderHeight: parent.areaHeaderHeight,
                libraryHeaderHeight: parent.libraryHeaderHeight
            )
        }

        func install(on view: TimelineCollectionView, layout: TimelineGridLayout) {
            self.view = view
            self.layout = layout
            view.coordinator = self
            layout.widthWillChange = { [weak self] in self?.widthWillChange() }
            view.register(TimelineTileCell.self, forCellWithReuseIdentifier: Self.cellID)
            view.register(
                TimelineTileCell.self,
                forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                withReuseIdentifier: Self.headerID
            )
            view.register(
                TimelineTileCell.self,
                forSupplementaryViewOfKind: TimelineGridLayout.libraryHeaderKind,
                withReuseIdentifier: Self.libraryID
            )
            view.register(
                TimelineTileCell.self,
                forSupplementaryViewOfKind: TimelineGridLayout.areaHeaderKind,
                withReuseIdentifier: Self.areaID
            )
            view.dataSource = self
            view.delegate = self
            view.backgroundColor = .clear
            // Every inset is set by hand. The grid runs edge to edge under the
            // clock and the tab bar, and what it must keep clear of is known
            // exactly — the automatic adjustment would add the safe area a
            // second time, or change it mid-scroll when a bar comes and goes.
            view.contentInsetAdjustmentBehavior = .never
            view.showsVerticalScrollIndicator = false
            view.alwaysBounceVertical = true

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSweep(_:)))
            pan.delegate = self
            pan.isEnabled = false
            view.addGestureRecognizer(pan)
            sweep = pan

            keys = parent.sections.map(\.bucket.key)
            rebuildIndex()
            parent.controller.coordinator = self
            applyInsets(to: view)
        }

        func tearDown() {
            for task in loads.values { task.cancel() }
            loads.removeAll()
        }

        // MARK: Updating

        /// Called whenever the timeline re-renders. Does as little as the
        /// change allows, in order of cost:
        ///
        /// Photographs arriving or leaving — a backup, a delete, another
        /// phone's upload — animate: the tiles slide to their new places and
        /// close the gap, as Photos does, holding whatever was on screen where
        /// it was. See `animate`.
        ///
        /// A shape drawn another way — a density change — or a change too big
        /// to be worth watching reloads, holding the screen's place the same
        /// way. The phone turning is neither: that is the layout's own.
        ///
        /// The same shape with different contents — a day finishing loading, a
        /// pending tile starting to send — redraws only the days whose tiles
        /// changed, in place, with nothing moving.
        func update(from next: TimelineCollection) {
            parent = next
            next.controller.coordinator = self
            guard let view, let layout else { return }
            entryCache.removeAll(keepingCapacity: true)
            // Anything in here that moves the grid makes UIKit call
            // `scrollViewDidScroll` on the spot — still inside the update
            // SwiftUI is watching. See the note at the end.
            isUpdating = true
            defer { isUpdating = false }

            // Both read against the old shape and the old insets — they describe
            // what is on screen *now*, which is what has to survive the change.
            let wasAtBottom = hasLanded && isAtBottom
            let anchor = hasLanded ? captureAnchor() : nil

            let insetsChanged = applyInsets(to: view)
            let nextKeys = next.sections.map(\.bucket.key)
            let nextShape = shape(for: next)
            let reshaped = nextShape != layout.shape || nextKeys != keys

            if reshaped {
                if !insetsChanged,
                   let diff = animatableChange(to: nextShape, keys: nextKeys, from: next) {
                    animate(diff, keys: nextKeys, shape: nextShape, wasAtBottom: wasAtBottom, anchor: anchor)
                } else {
                    keys = nextKeys
                    rebuildIndex()
                    layout.shape = nextShape
                    view.reloadData()
                    view.layoutIfNeeded()
                    // At the newest, a new photograph arriving should come
                    // into view rather than land out of sight below it.
                    // Anywhere else, whatever was at the top of the screen
                    // stays there.
                    if wasAtBottom {
                        scrollToBottom()
                    } else if let anchor {
                        restore(anchor)
                    }
                }
                forgetDaysNotIn(nextKeys)
            } else {
                // A bar appearing at the bottom — selecting, a review — would
                // otherwise cover the newest row until you scrolled.
                if insetsChanged, wasAtBottom { scrollToBottom() }
                refreshVisible(forceAll: next.cellContext != lastContext)
            }
            lastContext = next.cellContext

            sweep?.isEnabled = next.selection.isActive
            if !next.selection.isActive { endSweep() }

            if reshaped || next.progress.span == nil {
                next.progress.span = layout.span(keys: keys)
            }
            if let key = deferredJump, sectionIndex[key] != nil {
                deferredJump = nil
                jump(toDay: key)
            }
            // After this update rather than during it, and that is load-bearing.
            // SwiftUI watches what `updateUIView` reads, and reporting reads the
            // scrubber's position — so reporting in here made every frame of a
            // scroll schedule another full update, measured at one per frame.
            // Deferred, the read happens outside the watch.
            DispatchQueue.main.async { [weak self] in
                self?.report()
                self?.updateLoads()
            }
        }

        @discardableResult
        private func applyInsets(to view: UICollectionView) -> Bool {
            let insets = UIEdgeInsets(
                top: parent.topInset, left: 0, bottom: parent.bottomInset, right: 0
            )
            guard insets != lastInsets else { return false }
            lastInsets = insets
            view.contentInset = insets
            // A library resting on the bottom moves with it: a bar arriving
            // there lifts the newest row clear of it, the way scrolling to the
            // end does for a long one. Laid out now, so that anything measuring
            // the content next measures the new height.
            if let layout,
               layout.restsOnBottom(within: max(view.bounds.height - insets.top - insets.bottom, 0)) {
                layout.invalidateLayout()
                view.layoutIfNeeded()
            }
            return true
        }

        private func rebuildIndex() {
            sectionIndex.removeAll(keepingCapacity: true)
            for (index, key) in keys.enumerated() { sectionIndex[key] = index }
        }

        private func entries(_ section: Int) -> [GridEntry] {
            if let cached = entryCache[section] { return cached }
            guard parent.sections.indices.contains(section) else { return [] }
            let bucket = parent.sections[section].bucket
            let built = parent.entries(bucket)
            entryCache[section] = built
            drawn[bucket.key] = DrawnTiles(built)
            return built
        }

        // MARK: Animating a change

        /// One day's tiles as they were drawn, as identities. Hashes, not the
        /// entries themselves: they are kept for every day that has been on
        /// screen, which after a fling through a big library is most of it.
        struct DrawnTiles {
            let ids: [Int]
            /// Placeholders among them: a day that hasn't loaded, whose tiles
            /// are told apart only by position.
            let positional: Bool

            init(_ entries: [GridEntry]) {
                var positional = false
                ids = entries.map { entry in
                    var hasher = Hasher()
                    switch entry {
                    case .item(let item):
                        // A photograph this phone uploaded is the same tile
                        // as the one that stood for it while it was on the
                        // way — finishing an upload swaps the picture and
                        // moves nothing. See `TimelineView.stillQueued`.
                        if let local = item.sourceLocalID {
                            hasher.combine(0)
                            hasher.combine(local)
                        } else {
                            hasher.combine(1)
                            hasher.combine(item.id)
                        }
                    case .placeholder(let index):
                        positional = true
                        hasher.combine(2)
                        hasher.combine(index)
                    case .pending(let local, _):
                        hasher.combine(0)
                        hasher.combine(local)
                    }
                    return hasher.finalize()
                }
                self.positional = positional
            }
        }

        /// How long a change takes to play. Photos is a little quicker than
        /// UIKit's default, and settles without overshooting.
        private static let changeDuration: TimeInterval = 0.4

        /// What changed, worked out well enough to animate, or nil when the
        /// grid should reload instead: before it has opened, while it is off
        /// screen or turning, when the same photographs are drawn another way,
        /// and when the change is too big to be worth watching — see
        /// `GridDiff.between`.
        private func animatableChange(
            to nextShape: TimelineGridLayout.Shape, keys nextKeys: [String], from next: TimelineCollection
        ) -> GridDiff? {
            guard let view, let layout, hasLanded, view.window != nil, view.bounds.height > 0,
                  placeBeforeWidthChange == nil, layout.shape.drawsLike(nextShape)
            else { return nil }
            var newIndex: [String: Int] = [:]
            newIndex.reserveCapacity(nextKeys.count)
            for (index, key) in nextKeys.enumerated() { newIndex[key] = index }
            let oldCounts = layout.shape.counts
            let diff = GridDiff.between(
                oldKeys: keys, oldCounts: oldCounts, newKeys: nextKeys, newCounts: nextShape.counts
            ) { key, oldCount, _ -> GridDiff.Tiles<Int> in
                // Only a day that was drawn, at the count it had, can be told
                // tile by tile — and every day that was on screen was.
                guard let before = drawn[key], before.ids.count == oldCount, !before.positional,
                      let section = newIndex[key], next.sections.indices.contains(section)
                else { return .positional }
                let after = DrawnTiles(next.entries(next.sections[section].bucket))
                drawn[key] = after
                return after.positional ? .positional : .identified(old: before.ids, new: after.ids)
            }
            // Checked here as well as by construction: an update that doesn't
            // add up is a crash, and a reload is only a jump.
            guard let diff, diff.isConsistent(oldCounts: oldCounts, newCounts: nextShape.counts)
            else { return nil }
            return diff
        }

        /// Plays a change: every tile slides from where it was to where it now
        /// goes, what's gone fades where it was, and what's new fades in where
        /// it lands — one batch update, in one spring.
        ///
        /// The screen is held the way a reload holds it, but inside the same
        /// animation (`TimelineGridLayout.targetContentOffset`): the newest
        /// row stays on the bar if that's where the grid was, and otherwise
        /// the row at the top of the screen stays at the top. So a photograph
        /// deleted on screen closes its gap, one arriving opens a place, and a
        /// change somewhere off screen moves nothing you can see.
        private func animate(
            _ diff: GridDiff, keys nextKeys: [String], shape nextShape: TimelineGridLayout.Shape,
            wasAtBottom: Bool, anchor: Anchor?
        ) {
            guard let view, let layout else { return }
            let rest: TimelineGridLayout.Rest? = wasAtBottom
                ? .bottom : anchor.flatMap { rest(for: $0, through: diff) }
            for section in diff.changedSections where nextKeys.indices.contains(section) {
                dayRevisions[nextKeys[section], default: 0] += 1
            }
            // Laid out for what is on screen, so that is what it animates from.
            view.layoutIfNeeded()
            let headings = headingsOnScreen()
            var dropped: [TimelineTileCell] = []
            layout.beginChange(diff, resting: rest)
            UIView.animate(
                springDuration: Self.changeDuration, bounce: 0, initialSpringVelocity: 0,
                delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                view.performBatchUpdates {
                    self.keys = nextKeys
                    self.rebuildIndex()
                    layout.shape = nextShape
                    if !diff.deletedSections.isEmpty { view.deleteSections(diff.deletedSections) }
                    if !diff.insertedSections.isEmpty { view.insertSections(diff.insertedSections) }
                    if !diff.deletedItems.isEmpty {
                        view.deleteItems(at: diff.deletedItems.map { IndexPath(item: $0.item, section: $0.section) })
                    }
                    if !diff.insertedItems.isEmpty {
                        view.insertItems(at: diff.insertedItems.map { IndexPath(item: $0.item, section: $0.section) })
                    }
                    for move in diff.movedItems {
                        view.moveItem(
                            at: IndexPath(item: move.from.item, section: move.from.section),
                            to: IndexPath(item: move.to.item, section: move.to.section)
                        )
                    }
                }
                // Still inside the spring: what the update dropped fades in it.
                dropped = self.droppedHeadings(headings, animatedOut: layout.headingsAnimatedOut)
                let scroll = layout.changeScroll
                for heading in dropped {
                    view.sendSubviewToBack(heading)
                    heading.alpha = 0
                    heading.frame.origin.y += scroll
                }
            } completion: { [weak view] _ in
                guard let view else { return }
                let kept = Set(Self.headingKinds.flatMap { view.visibleSupplementaryViews(ofKind: $0) }
                    .map(ObjectIdentifier.init))
                for heading in dropped
                where heading.superview === view && !kept.contains(ObjectIdentifier(heading)) {
                    heading.removeFromSuperview()
                }
            }
            layout.endChange()
            // Outside the animation: what the tiles that stayed show is
            // redrawn, not animated, and they still carry the day as it was.
            refreshVisible(forceAll: false)
        }

        private static let headingKinds = [
            UICollectionView.elementKindSectionHeader,
            TimelineGridLayout.areaHeaderKind,
            TimelineGridLayout.libraryHeaderKind,
        ]

        /// Every heading on screen, by the kind and index path it is shown at.
        private func headingsOnScreen() -> [TimelineGridLayout.Heading: TimelineTileCell] {
            guard let view else { return [:] }
            var found: [TimelineGridLayout.Heading: TimelineTileCell] = [:]
            for kind in Self.headingKinds {
                for path in view.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
                    guard let heading = view.supplementaryView(forElementKind: kind, at: path)
                        as? TimelineTileCell
                    else { continue }
                    found[TimelineGridLayout.Heading(kind: kind, indexPath: path)] = heading
                }
            }
            return found
        }

        /// Headings a batch update let go of without animating them out.
        ///
        /// When the newest day goes — the day most often emptied, by a delete
        /// at the bottom of the library — the collection view never asks for
        /// its heading's way out. The heading stays where it was, opaque and
        /// no longer tracked: on screen over the tab bar, and still there once
        /// the day came back, under the new one. Deleting any other day asks,
        /// and so does everything else this grid changes. Measured in the
        /// simulator; it was the same whether the heading was a cell or a
        /// plain reusable view, whatever the layout answered for the old
        /// index path, and with or without the spring around the update.
        ///
        /// So whatever was on screen, isn't any more, and wasn't asked about
        /// fades out here, in the same spring, where it stands on screen — as
        /// the collection view would have done — and is taken away after.
        private func droppedHeadings(
            _ before: [TimelineGridLayout.Heading: TimelineTileCell],
            animatedOut: Set<TimelineGridLayout.Heading>
        ) -> [TimelineTileCell] {
            guard let view, !before.isEmpty else { return [] }
            let kept = Set(Self.headingKinds.flatMap { view.visibleSupplementaryViews(ofKind: $0) }
                .map(ObjectIdentifier.init))
            return before.compactMap { key, heading in
                guard !animatedOut.contains(key), !kept.contains(ObjectIdentifier(heading)),
                      heading.superview === view, !heading.isHidden
                else { return nil }
                return heading
            }
        }

        /// The anchor taken before the change, in the library after it: the
        /// same tile — or, if it went, the first after it in its day that
        /// stayed — or failing that the next day that stayed.
        private func rest(for anchor: Anchor, through diff: GridDiff) -> TimelineGridLayout.Rest? {
            guard let layout, let old = sectionIndex[anchor.key] else { return nil }
            if let section = diff.newSection(forOld: old) {
                guard let item = anchor.item else { return .section(section, delta: anchor.delta) }
                let count = layout.shape.counts.indices.contains(old) ? layout.shape.counts[old] : 0
                for candidate in item..<max(count, item) {
                    if let now = diff.newPath(forOld: GridDiff.Path(section: old, item: candidate)) {
                        return .item(section: now.section, item: now.item, delta: anchor.delta)
                    }
                }
                return .section(section, delta: 0)
            }
            for later in (old + 1)..<max(diff.sectionOldToNew.count, old + 1) {
                if let section = diff.newSection(forOld: later) { return .section(section, delta: 0) }
            }
            return .bottom
        }

        /// Lets go of what was drawn for days the library no longer has.
        private func forgetDaysNotIn(_ keys: [String]) {
            guard drawn.count > keys.count || dayRevisions.count > keys.count else { return }
            let live = Set(keys)
            drawn = drawn.filter { live.contains($0.key) }
            dayRevisions = dayRevisions.filter { live.contains($0.key) }
        }

        private func revision(ofSection section: Int) -> Int {
            keys.indices.contains(section) ? dayRevisions[keys[section]] ?? 0 : 0
        }

        /// Redraws the visible tiles whose entries changed, and the headings.
        ///
        /// Tile by tile rather than day by day: the tiles of one day can have
        /// been drawn at different moments — some before the day loaded, some
        /// after — and only comparing each against what it shows catches that.
        private func refreshVisible(forceAll: Bool) {
            guard let view else { return }
            var stale: [IndexPath] = []
            for path in view.indexPathsForVisibleItems where keys.indices.contains(path.section) {
                let all = entries(path.section)
                guard path.item < all.count else { continue }
                let cell = view.cellForItem(at: path) as? TimelineTileCell
                if forceAll || cell?.shown != all[path.item]
                    || cell?.shownRevision != revision(ofSection: path.section) {
                    stale.append(path)
                }
            }
            if !stale.isEmpty { view.reconfigureItems(at: stale) }

            // Headings carry the place name, which can change when a day's
            // photographs finish being geocoded — redrawn only when it has.
            for path in view.indexPathsForVisibleSupplementaryElements(
                ofKind: UICollectionView.elementKindSectionHeader
            ) {
                guard let header = view.supplementaryView(
                    forElementKind: UICollectionView.elementKindSectionHeader, at: path
                ) as? TimelineTileCell,
                    parent.sections.indices.contains(path.section),
                    header.shownDay != parent.sections[path.section].bucket
                else { continue }
                configureHeader(header, section: path.section)
            }
            // And a place line can name another place once a day's areas
            // change, which a reload used to redraw and a change carries over.
            for path in view.indexPathsForVisibleSupplementaryElements(
                ofKind: TimelineGridLayout.areaHeaderKind
            ) {
                guard let line = view.supplementaryView(
                    forElementKind: TimelineGridLayout.areaHeaderKind, at: path
                ) as? TimelineTileCell,
                    line.shownArea != areaTitle(at: path)
                else { continue }
                configureArea(line, at: path)
            }
        }

        // MARK: Data source

        func numberOfSections(in collectionView: UICollectionView) -> Int { keys.count }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            layout?.shape.counts.indices.contains(section) == true
                ? layout?.shape.counts[section] ?? 0 : 0
        }

        func collectionView(
            _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: Self.cellID, for: indexPath
            ) as! TimelineTileCell
            configure(cell, at: indexPath)
            return cell
        }

        private func configure(_ cell: TimelineTileCell, at indexPath: IndexPath) {
            guard let layout, keys.indices.contains(indexPath.section) else { return }
            let all = entries(indexPath.section)
            guard indexPath.item < all.count else {
                cell.contentConfiguration = nil
                cell.shown = nil
                return
            }
            let entry = all[indexPath.item]
            let size = layout.frame(forItem: indexPath.item, inSection: indexPath.section).size
            let items = parent.dayItems(parent.sections[indexPath.section].bucket)
            let build = parent.cell
            cell.contentConfiguration = UIHostingConfiguration {
                // Built inside a view's body, so the tile follows the selection
                // and the upload badges by observation, the way it did in the
                // SwiftUI grid — no reconfiguring on every tap.
                //
                // `.id` is not decoration. A reused cell keeps the hosted
                // view's identity, and with it every `@State` inside it — so
                // without this a tile scrolled onto a new photograph would keep
                // showing the old one's picture until the new one loaded.
                TileHost { build(entry, size, items) }
                    .id(entry.id)
            }
            .margins(.all, 0)
            cell.shown = entry
            cell.shownRevision = revision(ofSection: indexPath.section)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            viewForSupplementaryElementOfKind kind: String,
            at indexPath: IndexPath
        ) -> UICollectionReusableView {
            if kind == TimelineGridLayout.libraryHeaderKind {
                let view = collectionView.dequeueReusableSupplementaryView(
                    ofKind: kind, withReuseIdentifier: Self.libraryID, for: indexPath
                ) as! TimelineTileCell
                let build = parent.libraryHeader
                view.contentConfiguration = UIHostingConfiguration { TileHost { build() } }
                    .margins(.all, 0)
                return view
            }
            if kind == TimelineGridLayout.areaHeaderKind {
                let view = collectionView.dequeueReusableSupplementaryView(
                    ofKind: kind, withReuseIdentifier: Self.areaID, for: indexPath
                ) as! TimelineTileCell
                configureArea(view, at: indexPath)
                return view
            }
            let view = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind, withReuseIdentifier: Self.headerID, for: indexPath
            ) as! TimelineTileCell
            configureHeader(view, section: indexPath.section)
            return view
        }

        private func configureHeader(_ view: TimelineTileCell, section: Int) {
            guard parent.sections.indices.contains(section) else { return }
            let bucket = parent.sections[section].bucket
            let build = parent.header
            view.contentConfiguration = UIHostingConfiguration {
                TileHost { build(bucket) }
                    .accessibilityAddTraits(.isHeader)
            }
            .margins(.all, 0)
            view.shownDay = bucket
        }

        /// The place an area line names: the day's `item`-th area.
        private func areaTitle(at indexPath: IndexPath) -> String {
            let areas = parent.sections.indices.contains(indexPath.section)
                ? parent.sections[indexPath.section].areas : []
            return (areas.indices.contains(indexPath.item) ? areas[indexPath.item].title : nil) ?? ""
        }

        private func configureArea(_ view: TimelineTileCell, at indexPath: IndexPath) {
            let title = areaTitle(at: indexPath)
            let build = parent.areaHeader
            view.contentConfiguration = UIHostingConfiguration {
                TileHost { build(title) }
            }
            .margins(.all, 0)
            view.shownArea = title
        }

        // MARK: Delegate

        func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool { false }
        func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool { false }

        /// A cell prepared ahead of time can be a frame behind the data — a day
        /// that finished loading while it waited. Checked as it appears, so it
        /// never shows a placeholder for a photograph that has arrived.
        func collectionView(
            _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
            forItemAt indexPath: IndexPath
        ) {
            guard let cell = cell as? TimelineTileCell else { return }
            let all = entries(indexPath.section)
            if indexPath.item < all.count,
               cell.shown != all[indexPath.item]
                || cell.shownRevision != revision(ofSection: indexPath.section) {
                configure(cell, at: indexPath)
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            report()
            updateLoads()
        }

        // MARK: Reporting

        /// The viewport's top, measured in content — the coordinates the layout
        /// and the scrubber share.
        private var contentY: CGFloat {
            guard let view else { return 0 }
            return view.contentOffset.y + view.contentInset.top
        }

        /// How much content fits on screen between the two insets.
        private var viewport: CGFloat {
            guard let view else { return 0 }
            return max(view.bounds.height - view.contentInset.top - view.contentInset.bottom, 0)
        }

        /// Hands the scrubber and the chrome where the grid is.
        ///
        /// Exact, where the SwiftUI grid had to approximate: `offset / scrollable`
        /// was untrustworthy there because the scrollable height was a guess, so
        /// `ScrollProgress` built the position from the manifest instead. Here
        /// the content height *is* the manifest, so the plain ratio is right —
        /// and `topKey` is left unset, which is what sends `ScrollProgress` down
        /// that path.
        private func report() {
            guard !isUpdating, let view, let layout, view.bounds.height > 0 else { return }
            let height = layout.contentHeight
            let offset = contentY
            let report = ScrollReport(
                offset: Double(offset),
                scrollable: Double(max(height - viewport, 0)),
                toEnd: Double(height - (offset + viewport)),
                contentHeight: Double(height),
                container: Double(viewport),
                insetTop: Double(view.contentInset.top)
            )
            parent.progress.apply(report)
            // The day just under the bar: `contentY` is the line the top inset
            // ends on, which is where the floating bar's bottom edge sits.
            if let section = layout.section(at: max(offset, 0)), keys.indices.contains(section) {
                parent.progress.noteTopDay(keys[section])
            }
            LayoutWatch.shared.saw(report, from: parent.progress.scrollID)
        }

        // MARK: Loading

        /// Fetches the days on screen, and a screen's worth either side.
        ///
        /// Ahead of time, which the SwiftUI grid could not do: it fetched a day
        /// once the day was built, so a fling outran its own photographs. Here
        /// the layout knows which days are a screen away before any of them is
        /// drawn.
        ///
        /// Each fetch waits a beat before starting and is called off if its day
        /// leaves the range first. A normal scroll never notices — the days are
        /// a screen away when they are asked for. A scrub notices a great deal:
        /// it crosses hundreds of days in a second, each on screen for a frame,
        /// and without the wait every one of them would be a query against a
        /// NAS with spinning disks, for a day nobody was going to look at.
        private func updateLoads() {
            guard !isUpdating, let view, let layout, !keys.isEmpty, view.bounds.height > 0
            else { return }
            let margin = view.bounds.height
            let top = contentY
            guard let first = layout.section(at: max(top - margin, 0)),
                  let last = layout.section(at: top + viewport + margin)
            else { return }
            var wanted = Set<String>()
            for section in first...max(first, last) where keys.indices.contains(section) {
                wanted.insert(keys[section])
            }
            for (key, task) in loads where !wanted.contains(key) {
                task.cancel()
                loads[key] = nil
            }
            let load = parent.load
            for key in wanted where loads[key] == nil {
                loads[key] = Task {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard !Task.isCancelled else { return }
                    await load(key)
                }
            }
        }

        // MARK: Moving

        private var maxContentOffsetY: CGFloat {
            guard let view, let layout else { return 0 }
            return max(
                layout.contentHeight + view.contentInset.bottom - view.bounds.height,
                -view.contentInset.top
            )
        }

        private var isAtBottom: Bool {
            guard let view else { return false }
            return view.contentOffset.y >= maxContentOffsetY - 2
        }

        private func setContentY(_ y: CGFloat) {
            guard let view else { return }
            let offset = min(max(y - view.contentInset.top, -view.contentInset.top), maxContentOffsetY)
            view.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        }

        private func scrollToBottom() {
            guard let view else { return }
            view.setContentOffset(CGPoint(x: 0, y: maxContentOffsetY), animated: false)
        }

        func jump(toDay key: String) {
            guard let layout, let section = sectionIndex[key],
                  let top = layout.sectionTop(section), hasLanded
            else {
                deferredJump = key
                return
            }
            setContentY(top)
            report()
            updateLoads()
        }

        func scroll(toContentY y: CGFloat) {
            guard hasLanded else { return }
            setContentY(y)
        }

        func reveal(item: Int, inDay key: String) -> Bool {
            guard hasLanded, let view, let layout, let section = sectionIndex[key],
                  section < view.numberOfSections,
                  item >= 0, item < view.numberOfItems(inSection: section)
            else { return false }
            let frame = layout.frame(forItem: item, inSection: section)
            // The band tiles are actually seen in: under the floating bar at the
            // top, over the tab bar at the bottom.
            let top = view.contentOffset.y + view.contentInset.top
            let bottom = view.contentOffset.y + view.bounds.height - view.contentInset.bottom
            guard frame.minY < top || frame.maxY > bottom else { return true }
            // Centered rather than just nudged into view, the way Photos leaves
            // its grid: the photo you come back to is in the middle of what
            // surrounds it, not pinned against an edge.
            setContentY(frame.midY - (bottom - top) / 2)
            // Laid out now rather than on the next pass, so the tile is where
            // the viewer is about to fly its photo.
            view.layoutIfNeeded()
            report()
            updateLoads()
            return true
        }

        /// A tile's frame in window coordinates, after bringing it on screen.
        func frameOnScreen(item: Int, inDay key: String) -> CGRect? {
            guard reveal(item: item, inDay: key), let view, let layout,
                  let section = sectionIndex[key]
            else { return nil }
            return view.convert(layout.frame(forItem: item, inSection: section), to: nil)
        }

        /// The newest photograph, on first layout — the way Photos opens.
        fileprivate func landIfNeeded() {
            guard !hasLanded, let view, let layout,
                  view.bounds.height > 0, layout.contentHeight > 0
            else { return }
            hasLanded = true
            scrollToBottom()
            if let key = deferredJump {
                deferredJump = nil
                jump(toDay: key)
            }
            report()
            updateLoads()
        }

        // MARK: Holding a place

        /// What is at the top of the screen, precisely enough to put it back:
        /// a day, the first tile of the row at the top if there is one, and how
        /// far into it the screen had scrolled.
        struct Anchor {
            let key: String
            let item: Int?
            let delta: CGFloat
        }

        fileprivate func captureAnchor() -> Anchor? {
            guard let layout else { return nil }
            let y = max(contentY, 0)
            guard let section = layout.section(at: y), keys.indices.contains(section),
                  let top = layout.sectionTop(section)
            else { return nil }
            if let item = layout.item(at: y, inSection: section) {
                let frame = layout.frame(forItem: item, inSection: section)
                return Anchor(key: keys[section], item: item, delta: y - frame.minY)
            }
            return Anchor(key: keys[section], item: nil, delta: y - top)
        }

        fileprivate func restore(_ anchor: Anchor) {
            guard let layout, let section = sectionIndex[anchor.key],
                  let top = layout.sectionTop(section)
            else { return }
            if let item = anchor.item, item < layout.shape.counts[section] {
                setContentY(layout.frame(forItem: item, inSection: section).minY + anchor.delta)
            } else {
                setContentY(top + anchor.delta)
            }
        }

        /// Takes the screen's place as the width is about to change. The first
        /// capture stands until it is put back: a turn can pass through more
        /// than one width before the grid is laid out again.
        fileprivate func widthWillChange() {
            guard hasLanded, placeBeforeWidthChange == nil else { return }
            placeBeforeWidthChange = captureAnchor()
        }

        /// Puts back the place taken before the width changed, now that the
        /// tiles have moved to their new columns.
        fileprivate func restorePlaceAfterWidthChange() {
            guard let place = placeBeforeWidthChange else { return }
            placeBeforeWidthChange = nil
            restore(place)
        }

        /// After the grid has changed width — an iPad turned, or resized in
        /// Split View — and been laid out again for it.
        ///
        /// Every tile has a new size and often a new column, and two things
        /// only hear about a change of shape, not of width: the tiles on screen,
        /// whose picture is drawn at the size it was built with, and the
        /// scrubber, whose map of where each day starts is the layout's. Both
        /// are brought up to date here. Never on a phone, which doesn't turn.
        fileprivate func widthDidChange() {
            guard let layout, hasLanded else { return }
            parent.progress.span = layout.span(keys: keys)
            refreshVisible(forceAll: true)
            report()
            updateLoads()
        }


        // MARK: Drag to select

        /// Dragging across tiles adds them to the selection, the way it did in
        /// the SwiftUI grid — only while selecting, only ever adding, each tile
        /// once per drag, and alongside the scroll rather than instead of it.
        /// See `SelectionSweep` for why each of those is so.
        ///
        /// A recognizer on the collection view rather than frames reported by
        /// each tile: the tiles are hosted separately now, and the layout
        /// already knows what is under any point.
        @objc private func handleSweep(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            switch gesture.state {
            case .began, .changed:
                guard parent.selection.isActive else { return }
                if !sweeping {
                    let travel = gesture.translation(in: view)
                    // The same fourteen points as before: less, and the press
                    // that toggles one photo also sweeps it straight back.
                    guard hypot(travel.x, travel.y) >= 14 else { return }
                    sweeping = true
                }
                let point = gesture.location(in: view)
                guard let path = view.indexPathForItem(at: point) else { return }
                let all = entries(path.section)
                guard path.item < all.count, case .item(let item) = all[path.item] else { return }
                guard visited.insert(item.id).inserted else { return }
                guard !parent.selection.contains(item) else { return }
                parent.selection.toggle(item)
                UISelectionFeedbackGenerator().selectionChanged()
            default:
                endSweep()
            }
        }

        private func endSweep() {
            sweeping = false
            visited.removeAll()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

/// Holds its place when it changes width, and opens on the newest photograph.
///
/// Both are finished once a layout pass has run: the place is taken just
/// before the width changes (see `TimelineGridLayout.widthWillChange`) and put
/// back here, after the tiles have moved.
final class TimelineCollectionView: UICollectionView {
    fileprivate weak var coordinator: TimelineCollection.Coordinator?
    private var lastWidth: CGFloat = 0

    /// The grid has no safe area, and neither does anything inside it.
    ///
    /// This is what keeps every tile inside its own slot, and it was found on
    /// his phone: tiles near the bottom of the screen slid *up* out of their
    /// slots as they scrolled toward the home indicator, over the gap and into
    /// the row above — and at the top, under the bars, they slid down. The grid
    /// runs edge to edge, so the cells there overlap the window's safe area, and
    /// UIKit hands each such cell the overlap as its own safe-area inset. The
    /// view that `matchedTransitionSource` wraps every tile in — the zoom's
    /// anchor — lays itself out inside that inset, centered, so a tile hanging
    /// thirty-four points into the home indicator's strip was drawn seventeen
    /// points high. Measured exactly that: frame y −17.0 in a cell with a bottom
    /// inset of 34.
    ///
    /// Telling SwiftUI to ignore the safe area only halved it (−17 → −8.7) —
    /// the wrapping view is UIKit's and places itself before SwiftUI's modifiers
    /// apply. Removing the inset at its source fixed it outright: every cell
    /// reads zero and every tile's frame starts at 0. Nothing here needs a safe
    /// area — the grid sets every inset it keeps clear of by hand.
    ///
    /// Tiles no longer carry that zoom anchor — a photo opens over the grid
    /// now, see `ViewerStage` — but a hosted root handed an inset is how a tile
    /// went astray, and ruling it out costs nothing.
    override var safeAreaInsets: UIEdgeInsets { .zero }

    override func layoutSubviews() {
        let widthChanged = lastWidth != 0 && bounds.width != lastWidth
        lastWidth = bounds.width
        super.layoutSubviews()
        coordinator?.restorePlaceAfterWidthChange()
        coordinator?.landIfNeeded()
        // The next turn rather than now: redrawing the tiles reconfigures
        // cells, which is not something to start from inside this pass.
        if widthChanged {
            DispatchQueue.main.async { [weak self] in self?.coordinator?.widthDidChange() }
        }
    }
}

/// One tile or heading. Remembers what it was last drawn from, so a cell that
/// was prepared ahead of time can tell it has gone stale.
final class TimelineTileCell: UICollectionViewCell {
    /// None, ever — see `TimelineCollectionView.safeAreaInsets`.
    override var safeAreaInsets: UIEdgeInsets { .zero }
    var shown: GridEntry?
    /// Which of its day's changes the tile was built after. See
    /// `Coordinator.dayRevisions`.
    var shownRevision = 0
    /// The same for a heading: the day it was drawn for, place name included.
    var shownDay: TimelineBucket?
    /// And for a place line, the place.
    var shownArea: String?
}


/// Runs its content's builder in a view's body, filling its cell.
///
/// The body is what lets a hosted tile follow `@Observable` state — the
/// selection, the upload badges — on its own: reads made in a body are observed,
/// reads made while building a configuration are not.
///
/// Filling the cell and ignoring the safe area is the SwiftUI half of keeping a
/// tile in its slot. It is not the half that fixed it — that is
/// `TimelineCollectionView.safeAreaInsets` — but a hosted root that centered
/// itself in whatever inset it was handed is how a tile first went astray, and
/// it costs nothing to rule out here too.
private struct TileHost<Content: View>: View {
    let content: () -> Content
    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
    }
}
#endif
