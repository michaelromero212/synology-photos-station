#if os(macOS)
import FrameStationAPI
import FrameStationKit
import SwiftUI

// MARK: - Layout

/// Every row of the Mac library, placed before any of them is drawn.
///
/// The Mac grid used to be a `LazyVStack` of days, each a `LazyVStack` of
/// justified rows, and a lazy stack only knows the height of what it has built.
/// Everything else was a guess, revised as days were built and torn down, and
/// three complaints were that one fact seen from three sides:
///
/// - Coming back to the grid from another page left a band of empty window
///   under the newest day until you scrolled. The stack opened at its
///   *estimated* bottom, then measured the real days, which were shorter.
/// - A fast scroll was jerky. Every day crossing the edge was measured for the
///   first time and corrected the content height under the scroll.
/// - Opening or closing the sidebar stuttered. Each frame of the animation was
///   a new width, and a new width re-measured every realized row of every
///   realized day.
///
/// This works the way the iPhone's collection view does: the whole library is
/// laid out up front, from the photographs' shapes where a day has loaded and
/// from square placeholders where it has not, so the scroll view knows exactly
/// how tall it is. Only the rows on screen, and a margin around them, exist as
/// views at all.
struct MacGridMetrics: Equatable {
    var width: CGFloat
    var targetHeight: CGFloat
    var spacing: CGFloat
    var headerHeight: CGFloat
    var areaHeaderHeight: CGFloat
    /// The library's count, above the oldest day. Zero for none.
    var libraryHeaderHeight: CGFloat
    /// Room under the newest row so the window's rounded corners don't clip it.
    var bottomClearance: CGFloat
}

struct MacGridRow: Identifiable {
    enum Kind {
        case library
        case day
        case area(String)
        case tiles(Range<Int>, height: CGFloat)
    }

    let id: String
    /// Index into `MacGridLayout.days`, or -1 for the library's own heading.
    let day: Int
    let kind: Kind
    let y: CGFloat
    let height: CGFloat
}

struct MacGridDay {
    let bucket: TimelineBucket
    /// What the day draws, in order: its photographs, or placeholders.
    let entries: [GridEntry]
    /// The loaded photographs, for the viewer to step through.
    let items: [TimelineItem]
    let start: CGFloat
    let height: CGFloat
    /// Changes whenever anything this day draws does — its photographs, their
    /// details, its heading. A row compares this rather than the photographs
    /// themselves; see `MacGridRowView`.
    let version: Int
}

struct MacGridLayout {
    var days: [MacGridDay] = []
    var rows: [MacGridRow] = []
    var total: CGFloat = 0
    /// Where each day starts, by key.
    var dayIndex: [String: Int] = [:]
    /// Bumped whenever anything above moved, so the scroller can keep its place.
    var revision = 0

    /// The rows overlapping `top..<bottom`, by binary search on their tops.
    func rows(from top: CGFloat, to bottom: CGFloat) -> Range<Int> {
        guard !rows.isEmpty else { return 0..<0 }
        var low = 0, high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid].y + rows[mid].height <= top { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < rows.count, rows[end].y < bottom { end += 1 }
        return low..<end
    }

    /// The day under a point in the content, or the nearest one.
    func day(at y: CGFloat) -> Int? {
        guard !days.isEmpty else { return nil }
        var low = 0, high = days.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if days[mid].start <= y { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The library as the scrubber measures it: every day's start and height
    /// in content coordinates, exact rather than estimated.
    /// The day and photograph at a point, if it is on one.
    ///
    /// Walks the one row the point falls in, adding up the same widths the
    /// row is drawn with — so it agrees with the picture exactly, gaps
    /// included.
    func hit(_ point: CGPoint) -> (day: Int, entry: Int)? {
        for index in rows(from: point.y, to: point.y + 0.5) {
            let row = rows[index]
            guard row.y <= point.y, point.y < row.y + row.height,
                  case .tiles(let range, let height) = row.kind else { continue }
            let entries = days[row.day].entries
            var x: CGFloat = 0
            for entry in range {
                let width = JustifiedLayout.width(
                    forRatio: entries[entry].aspectRatio, height: Double(height)
                )
                if point.x >= x, point.x < x + width { return (row.day, entry) }
                x += width + PhotoGridMetrics.spacing
                if point.x < x { return nil }
            }
        }
        return nil
    }

    func span(header: CGFloat) -> LibrarySpan {
        var start: [String: Double] = [:]
        var height: [String: Double] = [:]
        for day in days {
            start[day.bucket.key] = Double(day.start)
            height[day.bucket.key] = Double(day.height)
        }
        return LibrarySpan(
            total: Double(total), start: start, height: height,
            order: days.map(\.bucket.key), header: Double(header)
        )
    }
}

/// Keeps each day's rows between layouts, so a day arriving re-lays out that
/// day and not the whole library.
///
/// A reference, and not an observable one: it is a cache read and written while
/// the grid's body runs, and nothing draws from it changing.
@MainActor
final class MacGridLayoutCache {
    private struct DaySignature: Equatable {
        let count: Int
        let loaded: Int
        let first: UUID?
        let last: UUID?
        let areas: Int
    }

    private enum Piece {
        case area(String)
        case tiles(Range<Int>, height: CGFloat)
    }

    private struct DayPieces {
        let signature: DaySignature
        var bucket: TimelineBucket
        var items: [TimelineItem]
        var entries: [GridEntry]
        let pieces: [Piece]
        var version: Int
    }

    private var versions = 0

    private var cache: [String: DayPieces] = [:]
    private var cachedMetrics: MacGridMetrics?
    private var lastSignatures: [DaySignature] = []
    private var lastKeys: [String] = []
    private(set) var layout = MacGridLayout()

    func layout(
        buckets: [TimelineBucket], items: [String: [TimelineItem]], metrics: MacGridMetrics
    ) -> MacGridLayout {
        guard metrics.width > 0 else { return layout }
        if metrics != cachedMetrics {
            cache.removeAll(keepingCapacity: true)
        }

        var signatures: [DaySignature] = []
        signatures.reserveCapacity(buckets.count)
        // A photograph changed in place — favorited, rotated, redated within
        // its day — keeps the day's shape, so its rows stay where they are, but
        // what they draw is new. Without this the grid kept showing the old one.
        var edited = false
        for bucket in buckets {
            let loaded = items[bucket.key]
            let signature = DaySignature(
                count: bucket.count, loaded: loaded?.count ?? -1,
                first: loaded?.first?.id, last: loaded?.last?.id,
                areas: bucket.areas?.count ?? 0
            )
            signatures.append(signature)
            if var cached = cache[bucket.key], cached.signature == signature,
               cached.bucket != bucket || !Self.same(cached.items, loaded ?? []) {
                versions += 1
                cached.bucket = bucket
                if let loaded {
                    cached.items = loaded
                    cached.entries = loaded.map(GridEntry.item)
                }
                cached.version = versions
                cache[bucket.key] = cached
                edited = true
            }
        }
        let keys = buckets.map(\.key)
        if !edited, metrics == cachedMetrics, signatures == lastSignatures, keys == lastKeys {
            return layout
        }
        cachedMetrics = metrics

        var next = MacGridLayout()
        next.revision = layout.revision + 1
        next.days.reserveCapacity(buckets.count)
        var y: CGFloat = 0

        if metrics.libraryHeaderHeight > 0 {
            next.rows.append(MacGridRow(
                id: "library", day: -1, kind: .library, y: 0,
                height: metrics.libraryHeaderHeight
            ))
            y = metrics.libraryHeaderHeight
        }

        for (index, bucket) in buckets.enumerated() {
            let signature = signatures[index]
            let pieces: DayPieces
            if let cached = cache[bucket.key], cached.signature == signature {
                pieces = cached
            } else {
                versions += 1
                pieces = Self.pieces(
                    for: bucket, items: items[bucket.key], signature: signature,
                    metrics: metrics, version: versions
                )
                cache[bucket.key] = pieces
            }

            let start = y
            let key = bucket.key
            next.rows.append(MacGridRow(
                id: "\(key)|h", day: index, kind: .day, y: y, height: metrics.headerHeight
            ))
            y += metrics.headerHeight
            var previousWasTiles = false
            for (n, piece) in pieces.pieces.enumerated() {
                switch piece {
                case .area(let name):
                    next.rows.append(MacGridRow(
                        id: "\(key)|a\(n)", day: index, kind: .area(name), y: y,
                        height: metrics.areaHeaderHeight
                    ))
                    y += metrics.areaHeaderHeight
                    previousWasTiles = false
                case .tiles(let range, let height):
                    if previousWasTiles { y += metrics.spacing }
                    next.rows.append(MacGridRow(
                        id: "\(key)|r\(n)", day: index, kind: .tiles(range, height: height),
                        y: y, height: height
                    ))
                    y += height
                    previousWasTiles = true
                }
            }
            next.dayIndex[key] = index
            next.days.append(MacGridDay(
                bucket: pieces.bucket, entries: pieces.entries, items: pieces.items,
                start: start, height: y - start, version: pieces.version
            ))
        }
        y += metrics.bottomClearance
        next.total = y

        // Days that left the library take their rows with them.
        if cache.count > buckets.count * 2 {
            let live = Set(keys)
            cache = cache.filter { live.contains($0.key) }
        }
        lastSignatures = signatures
        lastKeys = keys
        layout = next
        return next
    }

    /// Whether two runs of photographs are the same, checking storage first:
    /// a day nothing happened to hands back the very array it did last time,
    /// so the common case costs a pointer comparison rather than a walk.
    private static func same(_ a: [TimelineItem], _ b: [TimelineItem]) -> Bool {
        let shared = a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress && a.count == b.count }
        }
        return shared || a == b
    }

    private static func pieces(
        for bucket: TimelineBucket, items: [TimelineItem]?, signature: DaySignature,
        metrics: MacGridMetrics, version: Int
    ) -> DayPieces {
        let entries: [GridEntry] = items.map { $0.map(GridEntry.item) }
            ?? (0..<max(bucket.count, 0)).map { GridEntry.placeholder($0) }
        var pieces: [Piece] = []
        for run in TimelineView.areaRuns(for: bucket, entries: entries) {
            if run.start > 0, let name = run.name {
                pieces.append(.area(name))
            }
            let rows = JustifiedLayout.rows(
                aspectRatios: entries[run.start..<(run.start + run.count)].map(\.aspectRatio),
                width: Double(metrics.width),
                targetHeight: Double(metrics.targetHeight),
                spacing: Double(metrics.spacing)
            )
            for row in rows {
                let range = (row.range.lowerBound + run.start)..<(row.range.upperBound + run.start)
                pieces.append(.tiles(range, height: CGFloat(row.height)))
            }
        }
        return DayPieces(
            signature: signature, bucket: bucket, items: items ?? [], entries: entries,
            pieces: pieces, version: version
        )
    }
}

// MARK: - Moving the grid from outside

/// How the rest of the timeline moves the grid: the scrubber, a zoom keeping
/// its place, a jump to a day.
@MainActor @Observable
final class MacGridController {
    enum Target: Equatable {
        case y(Double)
        case day(String)
    }

    struct Request: Equatable {
        let serial: Int
        let target: Target
    }

    private(set) var request: Request?
    @ObservationIgnored private var serial = 0

    func scroll(toY y: Double) { send(.y(y)) }
    func jump(toDay key: String) { send(.day(key)) }

    private func send(_ target: Target) {
        serial += 1
        request = Request(serial: serial, target: target)
    }
}

/// Where each library's grid was left, so leaving for Albums or a photo and
/// coming back lands where you were — the way Photos does — rather than
/// wherever a fresh grid happens to open.
@MainActor
enum MacGridMemory {
    struct Place {
        /// The day at the top of the window, and how far into it.
        let day: String
        let into: CGFloat
        /// Resting on the newest row, which is where the library opens and
        /// where it should stay as new photographs arrive.
        let atEnd: Bool
    }

    static var places: [UUID: Place] = [:]
}

// MARK: - The grid

/// The library grid on a Mac. See `MacGridLayout` for why it is not a lazy
/// stack.
@available(macOS 15.0, *)
struct MacTimelineGrid<Cell: View, DayHeader: View, AreaHeader: View, LibraryHeader: View, Menu: View>: View {
    let space: UUID
    let buckets: [TimelineBucket]
    let items: [String: [TimelineItem]]
    let targetHeight: CGFloat
    let spacing: CGFloat
    let headerHeight: CGFloat
    let areaHeaderHeight: CGFloat
    let total: Int
    let progress: ScrollProgress
    let controller: MacGridController
    let loadDay: (String) async -> Void
    /// A click on a photograph, with the rest of its day.
    let onClick: (TimelineItem, [TimelineItem]) -> Void
    /// A click between photographs.
    let onClickEmpty: () -> Void
    /// The right-click menu for a photograph.
    @ViewBuilder let menu: (TimelineItem) -> Menu
    @ViewBuilder let cell: (GridEntry, CGSize, [TimelineItem]) -> Cell
    @ViewBuilder let dayHeader: (TimelineBucket) -> DayHeader
    @ViewBuilder let areaHeader: (String) -> AreaHeader
    @ViewBuilder let libraryHeader: () -> LibraryHeader

    @State private var cache = MacGridLayoutCache()
    /// The width the rows are laid out for. Follows the window's, but only once
    /// it has stopped changing — see `followWidth`.
    @State private var layoutWidth: CGFloat = 0
    @State private var widthSettle: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            let width = layoutWidth > 0 ? layoutWidth : proxy.size.width
            let layout = cache.layout(
                buckets: buckets, items: items,
                metrics: MacGridMetrics(
                    width: width, targetHeight: targetHeight, spacing: spacing,
                    headerHeight: headerHeight, areaHeaderHeight: areaHeaderHeight,
                    libraryHeaderHeight: total > 0 ? Self.libraryHeaderHeight : 0,
                    bottomClearance: 16
                )
            )
            MacGridScroller(
                space: space, layout: layout, layoutWidth: width,
                viewportWidth: proxy.size.width, headerHeight: headerHeight,
                progress: progress, controller: controller, loadDay: loadDay,
                onClick: onClick, onClickEmpty: onClickEmpty, menu: menu,
                cell: cell, dayHeader: dayHeader, areaHeader: areaHeader,
                libraryHeader: libraryHeader
            )
            .onChange(of: proxy.size.width, initial: true) { _, new in
                followWidth(new)
            }
        }
    }

    /// The count's own line, declared rather than measured for the same reason
    /// as every other height here.
    static var libraryHeaderHeight: CGFloat { 76 }

    /// Takes the window's width once it settles.
    ///
    /// Opening or closing the sidebar animates the detail pane's width through
    /// twenty-odd values in a quarter of a second. Reflowing the library at each
    /// of them is a whole new layout per frame, every visible tile resized and
    /// the scroll position recomputed, which is what made the sidebar stutter.
    /// Held instead, the grid simply slides with the pane, and reflows once,
    /// when the animation — or a window resize — comes to rest.
    private func followWidth(_ width: CGFloat) {
        guard width > 0, abs(width - layoutWidth) > 0.5 else { return }
        if layoutWidth == 0 {
            layoutWidth = width
            return
        }
        widthSettle?.cancel()
        widthSettle = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            layoutWidth = width
        }
    }
}

/// The rows, placed where the layout already says they go.
///
/// A `ZStack` of offset rows asked every row its size on each update — the
/// scroll view measuring its content — which for rows of known size is work
/// with a known answer. This states the size and places each row without
/// asking.
private struct MacGridCanvas: Layout {
    let size: CGSize
    let rows: [CGRect]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, rows) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading, proposal: ProposedViewSize(frame.size)
            )
        }
    }
}

/// One row of the grid, rebuilt only when something it draws has changed.
///
/// The row's content is a closure, which SwiftUI cannot compare, so without
/// this every row on screen was rebuilt each time the scroller re-rendered —
/// the window moving, or any day anywhere arriving from the NAS. Its own
/// day's version says whether anything it shows is different. Selection and
/// the like are still followed: they are read inside `body`, which observes
/// them on its own.
private struct MacGridRowView<Content: View>: View, Equatable {
    let id: String
    let version: Int
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View { content() }

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.version == b.version && a.width == b.width && a.height == b.height
    }
}

/// A view whose content is built when SwiftUI first asks for its body, not
/// when the view is declared. For a context menu, that is when it opens.
struct Deferred<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}

/// The scroll view, and the rows currently near the window.
///
/// Split from `MacTimelineGrid` so the part that changes as you scroll — which
/// rows exist — re-renders without re-checking the library's layout.
@available(macOS 15.0, *)
private struct MacGridScroller<Cell: View, DayHeader: View, AreaHeader: View, LibraryHeader: View, Menu: View>: View {
    let space: UUID
    let layout: MacGridLayout
    let layoutWidth: CGFloat
    let viewportWidth: CGFloat
    let headerHeight: CGFloat
    let progress: ScrollProgress
    let controller: MacGridController
    let loadDay: (String) async -> Void
    let onClick: (TimelineItem, [TimelineItem]) -> Void
    let onClickEmpty: () -> Void
    let menu: (TimelineItem) -> Menu
    let cell: (GridEntry, CGSize, [TimelineItem]) -> Cell
    let dayHeader: (TimelineBucket) -> DayHeader
    let areaHeader: (String) -> AreaHeader
    let libraryHeader: () -> LibraryHeader

    @State private var position: ScrollPosition
    /// The rows that exist as views right now.
    @State private var window: Range<Int> = 0..<0
    @State private var tracker = Tracker()
    /// The photograph under the pointer, as state, so the menu is rebuilt for
    /// the one it will open over. Changes as the pointer crosses from one
    /// photograph to the next, not as it moves within one.
    @State private var pointed: UUID?

    init(
        space: UUID, layout: MacGridLayout, layoutWidth: CGFloat, viewportWidth: CGFloat,
        headerHeight: CGFloat, progress: ScrollProgress, controller: MacGridController,
        loadDay: @escaping (String) async -> Void,
        onClick: @escaping (TimelineItem, [TimelineItem]) -> Void,
        onClickEmpty: @escaping () -> Void,
        menu: @escaping (TimelineItem) -> Menu,
        cell: @escaping (GridEntry, CGSize, [TimelineItem]) -> Cell,
        dayHeader: @escaping (TimelineBucket) -> DayHeader,
        areaHeader: @escaping (String) -> AreaHeader,
        libraryHeader: @escaping () -> LibraryHeader
    ) {
        self.space = space
        self.layout = layout
        self.layoutWidth = layoutWidth
        self.viewportWidth = viewportWidth
        self.headerHeight = headerHeight
        self.progress = progress
        self.controller = controller
        self.loadDay = loadDay
        self.onClick = onClick
        self.onClickEmpty = onClickEmpty
        self.menu = menu
        self.cell = cell
        self.dayHeader = dayHeader
        self.areaHeader = areaHeader
        self.libraryHeader = libraryHeader
        // Back where it was left, or on the newest. Decided before the first
        // frame, from a layout that is already exact, so there is nothing for
        // the window to correct afterwards — which is the gap that used to sit
        // under the newest day after coming back from another page.
        if let place = MacGridMemory.places[space], !place.atEnd,
           let index = layout.dayIndex[place.day] {
            let day = layout.days[index]
            _position = State(initialValue: ScrollPosition(y: day.start + min(place.into, day.height)))
        } else {
            _position = State(initialValue: ScrollPosition(edge: .bottom))
        }
    }

    /// Scroll bookkeeping that nothing draws from.
    @MainActor
    final class Tracker {
        var visible: CGRect = .zero
        /// The first point of content below the toolbar — what you can actually
        /// see at the top, and what `ScrollPosition(y:)` aligns to.
        ///
        /// Not the content offset: the window's toolbar insets the scroll view
        /// by about fifty points, and the offset counts from under it. Using
        /// the offset put every return a heading's height off.
        var top: CGFloat = 0
        var atEnd = true
        var layout = MacGridLayout()
        var loads: [String: Task<Void, Never>] = [:]
        var topKey: String?
        /// The stretch of the library the drawn rows cover. See `updateWindow`.
        var covered: ClosedRange<CGFloat>?
        /// The pointer, in the scroll view's own coordinates.
        var pointer: CGPoint?
    }

    var body: some View {
        ScrollView(.vertical) {
            let drawn = layout.rows[clamped(window)]
            MacGridCanvas(
                size: CGSize(width: layoutWidth, height: layout.total),
                rows: drawn.map { CGRect(x: 0, y: $0.y, width: layoutWidth, height: $0.height) }
            ) {
                ForEach(drawn) { row in
                    MacGridRowView(
                        id: row.id,
                        version: row.day >= 0 ? layout.days[row.day].version : layout.revision,
                        width: layoutWidth, height: row.height
                    ) {
                        rowView(row)
                    }
                    .equatable()
                }
            }
            // One click handler and one menu for the whole library, finding the
            // photograph from the layout — how a collection view does it. A
            // gesture on every tile was a third of the cost of a tile coming
            // into view, measured, and a fast scroll brings dozens a second.
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { point in
                clicked(at: point)
            }
            .contextMenu {
                Deferred {
                    // Looked up afresh, in case the photographs have scrolled
                    // under a pointer that hasn't moved; `pointed` is read so
                    // the menu is rebuilt whenever the pointer reaches another.
                    let _ = pointed
                    if let item = item(at: tracker.pointer) {
                        menu(item)
                    }
                }
            }
            // Held at the laid-out width while the pane animates to a new one —
            // see `followWidth` — and pinned to the leading edge meanwhile, so
            // the grid slides with the sidebar rather than recentering.
            .frame(width: viewportWidth, alignment: .topLeading)
        }
        .scrollPosition($position)
        // A library shorter than the window sits at the bottom, the way the
        // newest end always does.
        .defaultScrollAnchor(.bottom, for: .alignment)
        .scrollIndicators(.hidden)
        // Where the pointer is, for the menu to know what it was raised over.
        // Kept in the window's terms, not the library's: a scroll moves the
        // photographs under a pointer that hasn't moved.
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard case .active(let point) = phase else { return }
            tracker.pointer = point
            let id = item(at: point)?.id
            if id != pointed { pointed = id }
        }
        // Feeds the rail's thumb. See `ScrollProgress`.
        .modifier(ScrollActivityReporter(progress: progress))
        .onScrollGeometryChange(for: ScrollSample.self) { geometry in
            ScrollSample(
                visible: geometry.visibleRect,
                top: geometry.contentOffset.y + geometry.contentInsets.top,
                bottom: geometry.contentOffset.y + geometry.contentInsets.top
                    + geometry.containerSize.height,
                content: geometry.contentSize.height
            )
        } action: { _, sample in
            scrolled(sample)
        }
        .onChange(of: layout.revision, initial: true) { _, _ in relaid() }
        .onChange(of: controller.request) { _, request in
            guard let request else { return }
            move(to: request.target)
        }
        .onDisappear {
            for task in tracker.loads.values { task.cancel() }
            tracker.loads.removeAll()
        }
    }

    private struct ScrollSample: Equatable {
        let visible: CGRect
        let top: CGFloat
        let bottom: CGFloat
        let content: CGFloat
    }

    private func clamped(_ range: Range<Int>) -> Range<Int> {
        let upper = min(range.upperBound, layout.rows.count)
        return min(range.lowerBound, upper)..<upper
    }

    @ViewBuilder
    private func rowView(_ row: MacGridRow) -> some View {
        switch row.kind {
        case .library:
            libraryHeader()
        case .day:
            dayHeader(layout.days[row.day].bucket)
        case .area(let name):
            areaHeader(name)
        case .tiles(let range, let height):
            let day = layout.days[row.day]
            HStack(spacing: PhotoGridMetrics.spacing) {
                ForEach(day.entries[range]) { entry in
                    cell(
                        entry,
                        CGSize(
                            width: JustifiedLayout.width(forRatio: entry.aspectRatio, height: Double(height)),
                            height: height
                        ),
                        day.items
                    )
                }
            }
        }
    }

    // MARK: Clicking

    private func clicked(at point: CGPoint) {
        if let hit = layout.hit(point) {
            let day = layout.days[hit.day]
            if case .item(let item) = day.entries[hit.entry] {
                onClick(item, day.items)
                return
            }
        }
        onClickEmpty()
    }

    /// The photograph under a point in the scroll view.
    private func item(at pointer: CGPoint?) -> TimelineItem? {
        guard let pointer,
              let hit = layout.hit(CGPoint(x: pointer.x, y: tracker.visible.minY + pointer.y)),
              case .item(let item) = layout.days[hit.day].entries[hit.entry]
        else { return nil }
        return item
    }

    // MARK: Scrolling

    private func scrolled(_ sample: ScrollSample) {
        tracker.visible = sample.visible
        tracker.top = sample.top
        // Within a row's gap of the end counts as resting on it.
        tracker.atEnd = sample.bottom >= sample.content - 24
        updateWindow()
        remember()
    }

    /// The rows within a screen of the window: enough that a tile exists, and
    /// has asked for its picture, before it scrolls into view.
    ///
    /// Moved in strides rather than a row at a time. Every change to the
    /// window re-renders the scroller, and at fling speed a row boundary goes
    /// by forty times a second; measured, that was most of the dropped frames.
    /// Now the drawn stretch reaches a screen past each edge and moves once
    /// the window has used up a quarter screen of that — about a tenth as
    /// often at the same speed, and rows already drawn are left alone (see
    /// `MacGridRowView`). Not bigger strides: a whole screen of new rows at
    /// once measured as a 40 ms frame of its own.
    private func updateWindow() {
        let visible = tracker.visible
        guard visible.height > 0 else { return }
        let margin = visible.height
        let next = layout.rows(from: visible.minY - margin, to: visible.maxY + margin)
        if next != window {
            window = next
            requestDays(in: next)
        }
        if let index = layout.day(at: tracker.top + 1) {
            let key = layout.days[index].bucket.key
            if tracker.topKey != key {
                tracker.topKey = key
                progress.topKey = key
            }
        }
    }

    /// Fetches the days near the window that haven't arrived yet.
    ///
    /// After a beat rather than at once, so a fling through a few years asks
    /// the NAS for the days it stops on rather than every one it crosses. A
    /// day that leaves the window before its beat is up is never asked for.
    private func requestDays(in range: Range<Int>) {
        var wanted = Set<String>()
        for row in layout.rows[clamped(range)] where row.day >= 0 {
            let day = layout.days[row.day]
            if day.items.isEmpty, day.bucket.count > 0 { wanted.insert(day.bucket.key) }
        }
        for (key, task) in tracker.loads where !wanted.contains(key) {
            task.cancel()
            tracker.loads[key] = nil
        }
        for key in wanted where tracker.loads[key] == nil {
            tracker.loads[key] = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                await loadDay(key)
                tracker.loads[key] = nil
            }
        }
    }

    private func remember() {
        guard tracker.visible.height > 0, let index = layout.day(at: tracker.top) else { return }
        let day = layout.days[index]
        MacGridMemory.places[space] = MacGridMemory.Place(
            day: day.bucket.key, into: max(tracker.top - day.start, 0),
            atEnd: tracker.atEnd
        )
    }

    /// Keeps the same photographs on screen when the layout changes under them.
    ///
    /// A day arriving turns its square placeholders into photographs of their
    /// real shapes, which changes its height, and a resize reflows everything.
    /// Left alone, each would move whatever you were looking at by the
    /// difference. So the day at the top of the window is found in the old
    /// layout and in the new one, and the scroll moves by however far it moved.
    /// At the newest end, the newest end is kept instead.
    private func relaid() {
        defer {
            tracker.layout = layout
            progress.span = layout.span(header: headerHeight)
            // The rows have moved, so what the window covered is stale.
            tracker.covered = nil
            updateWindow()
        }
        let old = tracker.layout
        let top = tracker.top
        guard old.revision > 0, !old.days.isEmpty, tracker.visible.height > 0 else { return }

        if tracker.atEnd {
            if abs(old.total - layout.total) > 0.5 {
                position.scrollTo(edge: .bottom)
            }
            return
        }
        guard let index = old.day(at: top) else { return }
        let before = old.days[index]
        guard let now = layout.dayIndex[before.bucket.key].map({ layout.days[$0] }) else { return }
        let into = min(top - before.start, now.height)
        let target = now.start + into
        if abs(target - top) > 0.5 {
            position.scrollTo(y: target)
        }
    }

    private func move(to target: MacGridController.Target) {
        switch target {
        case .y(let y):
            position.scrollTo(y: CGFloat(y))
        case .day(let key):
            if let index = layout.dayIndex[key] {
                position.scrollTo(y: layout.days[index].start)
            }
        }
    }
}
#endif
