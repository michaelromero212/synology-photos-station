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

    struct Shape: Equatable {
        /// Entries per day, in drawing order: loaded photographs, placeholders
        /// standing in for ones that aren't, and tiles still on this phone.
        var counts: [Int]
        /// Tiles across a phone at this zoom. A wider grid fits more — see
        /// `columnCount`.
        var columns: Int
        var spacing: CGFloat
        var headerHeight: CGFloat
        /// The library's count above the oldest day. Zero for none.
        var libraryHeaderHeight: CGFloat
    }

    var shape: Shape {
        didSet { if shape != oldValue { invalidateLayout() } }
    }

    private var width: CGFloat = 0
    /// Tiles across, for the width the grid has now: `shape.columns` on a
    /// phone, more on an iPad. Worked out here, from the collection view's own
    /// width, so that turning an iPad or resizing it in Split View reflows the
    /// grid in the same layout pass that `TimelineCollectionView` holds the
    /// screen's place across.
    private(set) var columnCount = 1
    private var side: CGFloat = 0
    /// Where each day's heading begins, in content coordinates.
    private var starts: [CGFloat] = []
    private var height: CGFloat = 0
    private var scale: CGFloat = 3

    init(shape: Shape) {
        self.shape = shape
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        width = collectionView.bounds.width
        let displayScale = collectionView.traitCollection.displayScale
        scale = displayScale > 0 ? displayScale : 3
        columnCount = PhotoGridMetrics.squareColumns(shape.columns, across: width)
        let columns = columnCount
        // The same arithmetic `PhotoGridSection` used, so the tiles come out the
        // size they always were.
        side = max((width - shape.spacing * CGFloat(columns - 1)) / CGFloat(columns), 1)
        starts.removeAll(keepingCapacity: true)
        starts.reserveCapacity(shape.counts.count)
        var y = shape.libraryHeaderHeight
        for count in shape.counts {
            starts.append(y)
            y += sectionHeight(count)
        }
        height = y
    }

    private func rows(_ count: Int) -> Int {
        let columns = columnCount
        return (max(count, 0) + columns - 1) / columns
    }

    func sectionHeight(_ count: Int) -> CGFloat {
        let rows = rows(count)
        return shape.headerHeight + CGFloat(rows) * side
            + CGFloat(max(rows - 1, 0)) * shape.spacing
    }

    var contentHeight: CGFloat { height }

    override var collectionViewContentSize: CGSize {
        CGSize(width: width, height: height)
    }

    /// Told that the width is about to change, while everything here still
    /// describes the screen as it is. See `shouldInvalidateLayout`.
    var widthWillChange: (() -> Void)?

    /// Only a change of width changes anything; scrolling changes nothing.
    ///
    /// Also the one moment to take the screen's place before a new width
    /// moves it. By the time the collection view lays itself out, this layout
    /// has already been prepared for the new width — asked for its content
    /// size along the way — and a place read then describes the new layout at
    /// the old offset: measured, it named whatever had moved under the old
    /// offset, and putting that back moved nothing.
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard newBounds.width != width else { return false }
        widthWillChange?()
        return true
    }

    /// The day holding a point in the content. A binary search, because this is
    /// asked every frame of a scroll and a library of 67,000 photographs is a few
    /// thousand days.
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

    /// The first tile of the row at a point inside a day, or nil when the point
    /// is on the day's heading.
    func item(at y: CGFloat, inSection section: Int) -> Int? {
        guard starts.indices.contains(section) else { return nil }
        let gridTop = starts[section] + shape.headerHeight
        guard y >= gridTop else { return nil }
        let row = Int((y - gridTop) / (side + shape.spacing))
        let item = row * columnCount
        return item < shape.counts[section] ? item : nil
    }

    /// Frames land on whole device pixels, the way SwiftUI's did. Fractional
    /// edges would blur the two-point gaps into gray smears.
    private func pixel(_ value: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    func frame(forItem item: Int, inSection section: Int) -> CGRect {
        let columns = columnCount
        let row = item / columns
        let column = item % columns
        let gridTop = starts[section] + shape.headerHeight
        let x = CGFloat(column) * (side + shape.spacing)
        let y = gridTop + CGFloat(row) * (side + shape.spacing)
        let minX = pixel(x), maxX = pixel(x + side)
        let minY = pixel(y), maxY = pixel(y + side)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func headerFrame(_ section: Int) -> CGRect {
        let top = starts[section]
        let minY = pixel(top)
        return CGRect(x: 0, y: minY, width: width, height: pixel(top + shape.headerHeight) - minY)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var result: [UICollectionViewLayoutAttributes] = []
        if shape.libraryHeaderHeight > 0, rect.minY < shape.libraryHeaderHeight,
           let library = layoutAttributesForSupplementaryView(
               ofKind: Self.libraryHeaderKind, at: IndexPath(item: 0, section: 0)
           ) {
            result.append(library)
        }
        guard var section = section(at: max(rect.minY, 0)) else { return result }
        let columns = columnCount
        let pitch = side + shape.spacing
        while section < starts.count, starts[section] < rect.maxY {
            let top = starts[section]
            let count = shape.counts[section]
            if top + sectionHeight(count) > rect.minY {
                if top + shape.headerHeight > rect.minY {
                    let header = UICollectionViewLayoutAttributes(
                        forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                        with: IndexPath(item: 0, section: section)
                    )
                    header.frame = headerFrame(section)
                    result.append(header)
                }
                let gridTop = top + shape.headerHeight
                let totalRows = rows(count)
                if totalRows > 0 {
                    let first = max(0, Int(floor((rect.minY - gridTop) / pitch)))
                    let last = min(totalRows - 1, Int(floor((rect.maxY - gridTop) / pitch)))
                    if first <= last {
                        for row in first...last {
                            for column in 0..<columns {
                                let item = row * columns + column
                                guard item < count else { break }
                                let attributes = UICollectionViewLayoutAttributes(
                                    forCellWith: IndexPath(item: item, section: section)
                                )
                                attributes.frame = frame(forItem: item, inSection: section)
                                result.append(attributes)
                            }
                        }
                    }
                }
            }
            section += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard shape.counts.indices.contains(indexPath.section),
              starts.indices.contains(indexPath.section),
              indexPath.item < shape.counts[indexPath.section]
        else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = frame(forItem: indexPath.item, inSection: indexPath.section)
        return attributes
    }

    override func layoutAttributesForSupplementaryView(
        ofKind kind: String, at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        let attributes = UICollectionViewLayoutAttributes(
            forSupplementaryViewOfKind: kind, with: indexPath
        )
        if kind == Self.libraryHeaderKind {
            guard shape.libraryHeaderHeight > 0 else { return nil }
            attributes.frame = CGRect(x: 0, y: 0, width: width, height: shape.libraryHeaderHeight)
            return attributes
        }
        guard starts.indices.contains(indexPath.section) else { return nil }
        attributes.frame = headerFrame(indexPath.section)
        return attributes
    }

    /// The library's shape as the scrubber reads it, in this layout's own
    /// coordinates so the two can never disagree about where a day is.
    func span(keys: [String]) -> LibrarySpan {
        var start: [String: Double] = [:]
        var height: [String: Double] = [:]
        start.reserveCapacity(keys.count)
        height.reserveCapacity(keys.count)
        for (index, key) in keys.enumerated() where starts.indices.contains(index) {
            start[key] = Double(starts[index])
            height[key] = Double(sectionHeight(shape.counts[index]))
        }
        return LibrarySpan(
            total: Double(self.height), start: start, height: height,
            order: keys, header: Double(shape.headerHeight)
        )
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
    /// screen afterwards.
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
    }

    let sections: [Section]
    let columns: Int
    let spacing: CGFloat
    let headerHeight: CGFloat
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

        private var sweep: UIPanGestureRecognizer?
        private var sweeping = false
        private var visited: Set<UUID> = []

        private static let cellID = "tile"
        private static let headerID = "day"
        private static let libraryID = "library"

        init(parent: TimelineCollection) {
            self.parent = parent
        }

        func shape(for parent: TimelineCollection) -> TimelineGridLayout.Shape {
            TimelineGridLayout.Shape(
                counts: parent.sections.map(\.count),
                columns: parent.columns,
                spacing: parent.spacing,
                headerHeight: parent.headerHeight,
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
        /// A different shape — a day added, a photograph arriving, a density
        /// change, the phone turning — reloads, holding whatever was on screen
        /// where it was. The only time the content changes size.
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
                keys = nextKeys
                rebuildIndex()
                layout.shape = nextShape
                view.reloadData()
                view.layoutIfNeeded()
                // At the newest, a new photograph arriving should come into
                // view rather than land out of sight below it. Anywhere else,
                // whatever was at the top of the screen stays there.
                if wasAtBottom {
                    scrollToBottom()
                } else if let anchor {
                    restore(anchor)
                }
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
            return true
        }

        private func rebuildIndex() {
            sectionIndex.removeAll(keepingCapacity: true)
            for (index, key) in keys.enumerated() { sectionIndex[key] = index }
        }

        private func entries(_ section: Int) -> [GridEntry] {
            if let cached = entryCache[section] { return cached }
            guard parent.sections.indices.contains(section) else { return [] }
            let built = parent.entries(parent.sections[section].bucket)
            entryCache[section] = built
            return built
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
                if forceAll || cell?.shown != all[path.item] {
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
            if indexPath.item < all.count, cell.shown != all[indexPath.item] {
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
    /// The same for a heading: the day it was drawn for, place name included.
    var shownDay: TimelineBucket?
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
