import FrameStationAPI
import FrameStationKit
import SwiftUI

#if !os(tvOS)

/// The library's shape, down the trailing edge, on screens with room for it.
///
/// `FastScroller` is the phone answer: invisible until you touch it, because a
/// phone has no width to spare. On a Mac or an iPad that reticence is a waste —
/// there is room for a rail that says something while you are not touching it,
/// and a pointer that can ask questions of it without committing to a drag.
///
/// What it says is the part worth having. Synology's equivalent is a ruler:
/// evenly spaced years, dots between. It tells you *when* and nothing about
/// *what is there*, so every year looks alike whether you took four photographs
/// that year or four thousand. Every bucket already carries a count — the
/// manifest has always sent it and the scrubber never used it — so this draws
/// the library's density instead. The August of a big vacation is a thick
/// bright band; the February you photographed a package is a hairline. You can see
/// where the substance of your library is before you drag anywhere.
struct TimelineRail: View {
    let buckets: [TimelineBucket]
    let progress: ScrollProgress
    /// The day under the pointer, and where to send the grid — see
    /// `LibrarySpan.target(atFraction:viewport:)`.
    let onScrub: (TimelineBucket, LibrarySpan.Target?) -> Void
    let onScrubEnd: () -> Void

    @State private var isDragging = false
    @State private var dragFraction: Double = 0
    /// Where the pointer is, 0…1, or nil when it isn't over the rail. Distinct
    /// from the drag: hovering asks "what is here?", dragging says "take me
    /// there", and the rail should answer the first without doing the second.
    @State private var hoverFraction: Double?

    #if os(macOS)
    /// On a Mac the rail is out of sight until the pointer comes to the
    /// window's right edge, then slides out, and goes again once the pointer
    /// has left. It used to stand over the grid's right edge the whole time —
    /// a strip of bars and labels on top of every photograph in that column,
    /// for a control used now and then. A Mac has a pointer to ask with, the
    /// way it has overlay scroll bars that come when wanted.
    @State private var isOut = false
    /// The pointer is over the rail, or over the edge that calls it.
    @State private var pointerNear = false
    @State private var putAway: Task<Void, Never>?

    /// The years and bars.
    private let railWidth: CGFloat = 60
    private let barMaxWidth: CGFloat = 22
    /// Room around them that still counts as the rail — so a pointer a hair
    /// off a bar keeps it out — and their gap from the window's edge.
    private static let margins = EdgeInsets(top: 12, leading: 9, bottom: 12, trailing: 0)
    private static let edgeGap: CGFloat = 8
    /// How near the window's right edge the pointer must come to call the
    /// rail out: the last few points, about where a Mac's own overlay scroll
    /// bar sits. It was 32, and a photo in the grid's last column couldn't be
    /// pointed at near its right side without the rail sliding out over it.
    private static let edgeReach: CGFloat = 10
    /// Everything the rail takes from the window's right edge when it's out.
    private var footprint: CGFloat {
        railWidth + Self.margins.leading + Self.margins.trailing + Self.edgeGap
    }
    #else
    private let railWidth: CGFloat = 62
    private let barMaxWidth: CGFloat = 26
    #endif
    /// How many bars the density strip is drawn with.
    ///
    /// Fixed rather than one per bucket: a day-zoomed library has thousands of
    /// buckets and a rail is six hundred points tall, so per-bucket bars would
    /// be sub-pixel slivers costing thousands of draw calls to look like a solid
    /// block. Aggregating into a fixed number of slots is both cheaper and more
    /// legible.
    private let slots = 90

    var body: some View {
        #if os(macOS)
        rail
            // Out past the window's edge while away, so it slides in from it.
            .offset(x: isOut ? 0 : footprint + 4)
            .frame(width: footprint, alignment: .trailing)
            // While away, only a band along the edge takes clicks, so the
            // photos beside it stay clickable; while out, all of it does.
            .contentShape(EdgeBand(width: isOut ? footprint : Self.edgeReach))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    pointerNear = true
                    putAway?.cancel()
                    // Out only from the band at the edge, measured here: the
                    // hover answers over the whole width whatever the shape
                    // above says, and the rail came out for a pointer
                    // anywhere within 77 points of the edge.
                    if !isOut, point.x >= footprint - Self.edgeReach { isOut = true }
                case .ended:
                    pointerNear = false
                    // A drag may wander off the rail; it goes once you let go.
                    if !isDragging { putAwaySoon() }
                }
            }
            // Quick out, quicker back.
            .animation(isOut ? .snappy(duration: 0.2) : .easeIn(duration: 0.16), value: isOut)
            .onDisappear { putAway?.cancel() }
        #else
        rail
        #endif
    }

    #if os(macOS)
    /// Away after a beat, not the instant the pointer slips off: brushing past
    /// the rail's edge shouldn't make it flicker.
    private func putAwaySoon() {
        putAway?.cancel()
        putAway = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, !isDragging, !pointerNear else { return }
            hoverFraction = nil
            isOut = false
        }
    }
    #endif

    private var rail: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let fraction = isDragging ? dragFraction : progress.fraction

            ZStack(alignment: .topTrailing) {
                Color.clear

                // Its own view, compared by the library it draws, so a scroll
                // — which moves only the line below — doesn't recount every
                // bar and relay every year label sixty times a second.
                Backdrop(
                    buckets: buckets, height: height, slots: slots,
                    barMaxWidth: barMaxWidth
                )
                .equatable()
                position(height: height, fraction: fraction)

                // The pill follows the pointer while hovering and the finger
                // while dragging — whichever is asking.
                if let asking = hoverFraction ?? (isDragging ? dragFraction : nil),
                   let bucket = buckets.bucket(atFraction: asking) {
                    RailPill(
                        title: Self.pillTitle(for: bucket),
                        count: bucket.count
                    )
                    .offset(x: pillOffset, y: height * asking - 18)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .frame(width: railWidth, alignment: .trailing)
            .contentShape(Rectangle())
            #if os(macOS) || os(iOS)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hoverFraction = (point.y / max(height, 1)).clamped(to: 0...1)
                case .ended:
                    hoverFraction = nil
                }
            }
            #endif
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        dragFraction = (value.location.y / max(height, 1))
                            .clamped(to: 0...1)
                        if let bucket = buckets.bucket(atFraction: dragFraction) {
                            // The day under the pointer, measured the way the
                            // grid is measured — by height, not by photograph
                            // count. The pill was naming one month while the
                            // scroll went to another; see `LibrarySpan.target`.
                            // Falls back to the item count only before the
                            // library has been measured.
                            let target = progress.span?.target(
                                atFraction: dragFraction, viewport: progress.viewport
                            )
                            let named = target.flatMap { spot in
                                buckets.first { $0.key == spot.day }
                            } ?? bucket
                            onScrub(named, target)
                        }
                    }
                    .onEnded { value in
                        isDragging = false
                        onScrubEnd()
                        #if os(macOS)
                        // Let go off the rail: away it goes. The pointer's
                        // comings and goings aren't reported while the button
                        // is down, so where the drag ended is the only word
                        // on where the pointer is — measured without it, the
                        // rail stayed out, its month pill stuck, until the
                        // pointer next moved.
                        let margins = Self.margins
                        let onRail = value.location.x >= -margins.leading
                            && value.location.x <= railWidth + margins.trailing + Self.edgeGap
                            && value.location.y >= -margins.top
                            && value.location.y <= height + margins.bottom
                        if onRail {
                            // The pill names where you let go, not where the
                            // pointer last hovered before the drag began.
                            pointerNear = true
                            hoverFraction = (value.location.y / max(height, 1)).clamped(to: 0...1)
                        } else {
                            pointerNear = false
                            hoverFraction = nil
                        }
                        if !pointerNear { putAwaySoon() }
                        #endif
                    }
            )
            .animation(.easeOut(duration: 0.12), value: hoverFraction == nil)
            .animation(.easeOut(duration: 0.15), value: isDragging)
        }
        .frame(width: railWidth)
        #if os(macOS)
        // Straight over the photos, with no panel of its own — it had a dark
        // glass one, which was a second thing sliding over the grid for no
        // gain. White, with a shadow under the years and bars (see
        // `Backdrop`), reads over bright photos and dark ones alike.
        .padding(Self.margins)
        .environment(\.colorScheme, .dark)
        .padding(.trailing, Self.edgeGap)
        #endif
    }

    /// Where the hover pill sits: beside the rail, clear of its years.
    private var pillOffset: CGFloat {
        #if os(macOS)
        -(railWidth + Self.margins.leading)
        #else
        -railWidth + 6
        #endif
    }

    // MARK: - Where you are

    /// A line rather than a thumb.
    ///
    /// The rail is the drag target now, so a separate grabbable thumb would be
    /// a second thing to aim at that does the same job. A line says where you
    /// are without implying it is the only place you may press.
    private func position(height: CGFloat, fraction: Double) -> some View {
        Rectangle()
            .fill(.tint)
            .frame(width: barMaxWidth + 10, height: isDragging ? 3 : 2)
            .offset(y: height * fraction.clamped(to: 0...1) - 1)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .allowsHitTesting(false)
    }

    /// `MAR 2021`, and the count beneath it.
    static func pillTitle(for bucket: TimelineBucket) -> String {
        FastScroller.label(for: bucket)
    }

    private struct RailPill: View {
        let title: String
        let count: Int

        var body: some View {
            VStack(alignment: .trailing, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(count == 1 ? "1 photo" : "\(count) photos")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .glassCapsule(interactive: false, fallback: .regularMaterial)
            .shadow(color: .black.opacity(0.22), radius: 8, y: 2)
        }
    }
}

/// The rail's density strip and year labels: everything on it that depends
/// on the library alone, not on where in it you are.
private struct Backdrop: View, Equatable {
    let buckets: [TimelineBucket]
    let height: CGFloat
    let slots: Int
    let barMaxWidth: CGFloat

    var body: some View {
        ZStack(alignment: .topTrailing) {
            density(height: height)
            years(height: height)
        }
    }

    static func == (a: Self, b: Self) -> Bool {
        guard a.height == b.height, a.slots == b.slots, a.barMaxWidth == b.barMaxWidth else {
            return false
        }
        // The same array, untouched, in the usual case — so a pointer, not a walk.
        let shared = a.buckets.withUnsafeBufferPointer { x in
            b.buckets.withUnsafeBufferPointer { y in
                x.baseAddress == y.baseAddress && x.count == y.count
            }
        }
        return shared || a.buckets == b.buckets
    }

    // MARK: - The strip

    /// The library's density, as bars whose length is how much you shot then.
    ///
    /// Square-rooted rather than linear. One extraordinary two weeks — a
    /// wedding, a first vacation with a new camera — is often an order of
    /// magnitude above an ordinary month, and on a linear scale it takes the
    /// whole width while every normal month collapses to an invisible stub. The
    /// root keeps the busy periods obviously busy while leaving the quiet ones
    /// legible, which is the comparison somebody is actually making.
    private func density(height: CGFloat) -> some View {
        Canvas { context, size in
            let weights = Self.weights(buckets: buckets, slots: slots)
            guard let peak = weights.max(), peak > 0 else { return }
            let slotHeight = size.height / CGFloat(slots)

            for (index, weight) in weights.enumerated() {
                guard weight > 0 else { continue }
                let scaled = (weight / peak).squareRoot()
                let width = barMaxWidth * CGFloat(scaled)
                let rect = CGRect(
                    x: size.width - width,
                    y: CGFloat(index) * slotHeight,
                    // A hair over, so neighbouring bars meet rather than
                    // leaving a moiré of gaps at fractional heights.
                    width: width, height: slotHeight + 0.5
                )
                context.fill(
                    Path(rect),
                    with: .color(.primary.opacity(Self.barOpacity(scaled)))
                )
            }
        }
        #if os(macOS)
        .shadow(color: .black.opacity(0.45), radius: 1.5)
        #endif
        .allowsHitTesting(false)
    }

    /// How strongly a bar is drawn, by how full it is. Stronger on a Mac,
    /// where the bars sit straight on the photos rather than beside them.
    private static func barOpacity(_ scaled: Double) -> Double {
        #if os(macOS)
        0.3 + 0.4 * scaled
        #else
        0.16 + 0.24 * scaled
        #endif
    }

    /// How much of the library sits in each slot of the rail.
    ///
    /// By *bucket position* rather than by date, because that is what dragging
    /// does: the scrubber maps a fraction to a bucket index, so a rail laid out
    /// by date would disagree with the thing it is a picture of — you would
    /// point at a band and land somewhere else.
    static func weights(buckets: [TimelineBucket], slots: Int) -> [Double] {
        guard !buckets.isEmpty, slots > 0 else { return [] }
        var result = [Double](repeating: 0, count: slots)
        for (index, bucket) in buckets.enumerated() {
            let slot = min(slots - 1, index * slots / buckets.count)
            result[slot] += Double(bucket.count)
        }
        return result
    }

    // MARK: - Years

    /// A year label where that year begins, and only for years you have.
    ///
    /// A rail carrying 2016 for a library with nothing from 2016 is a ruler
    /// pretending to be a library. Labels are dropped when they would collide
    /// rather than shrunk — an unreadable stack of years is worse than fewer.
    private func years(height: CGFloat) -> some View {
        #if os(macOS)
        // Larger and white, with a shadow to stand on over a bright photo:
        // the thing you read the rail for, and it was the faintest thing on it.
        let font = Font.system(size: 12, weight: .semibold)
        let style = HierarchicalShapeStyle.primary
        let minimumGap: CGFloat = 20
        let lift: CGFloat = 8
        #else
        let font = Font.caption2.weight(.semibold)
        let style = HierarchicalShapeStyle.secondary
        let minimumGap: CGFloat = 22
        let lift: CGFloat = 7
        #endif
        let marks = Self.visibleYearMarks(
            buckets: buckets, height: height, minimumGap: minimumGap
        )

        return ZStack(alignment: .topTrailing) {
            ForEach(marks, id: \.year) { mark in
                Text(mark.year)
                    .font(font)
                    .monospacedDigit()
                    .foregroundStyle(style)
                    #if os(macOS)
                    .shadow(color: .black.opacity(0.7), radius: 2, y: 0.5)
                    #endif
                    .offset(x: -barMaxWidth - 6, y: mark.y - lift)
            }
        }
        .allowsHitTesting(false)
    }

    /// The year labels that fit, each where its year begins, and how far down.
    ///
    /// One that would crowd the label above it is left out rather than drawn
    /// over it — except the newest year, where the library opens, which is
    /// always labeled, at the expense of whichever came just before it. This
    /// used to be decided while the labels were being drawn, by a running
    /// total the drawing kept; SwiftUI may draw a list's rows in any order and
    /// more than once, so it wasn't a total anything could rely on.
    static func visibleYearMarks(
        buckets: [TimelineBucket], height: CGFloat, minimumGap: CGFloat
    ) -> [(year: String, y: CGFloat)] {
        let marks = yearMarks(buckets: buckets).map { (year: $0.year, y: height * CGFloat($0.fraction)) }
        var kept: [(year: String, y: CGFloat)] = []
        for mark in marks {
            if let last = kept.last, mark.y - last.y < minimumGap { continue }
            kept.append(mark)
        }
        if let newest = marks.last, kept.last?.year != newest.year {
            while let last = kept.last, newest.y - last.y < minimumGap { kept.removeLast() }
            kept.append(newest)
        }
        return kept
    }

    static func yearMarks(buckets: [TimelineBucket]) -> [(year: String, fraction: Double)] {
        guard !buckets.isEmpty else { return [] }
        var seen = Set<String>()
        var marks: [(String, Double)] = []
        for (index, bucket) in buckets.enumerated() {
            let year = String(bucket.key.prefix(4))
            guard year.count == 4, !seen.contains(year) else { continue }
            seen.insert(year)
            marks.append((year, Double(index) / Double(buckets.count)))
        }
        return marks
    }

}

#if os(macOS)
/// A strip of `width` along the trailing edge: where the hidden rail listens
/// for the pointer.
private struct EdgeBand: Shape {
    var width: CGFloat

    func path(in rect: CGRect) -> Path {
        let width = min(width, rect.width)
        return Path(CGRect(x: rect.maxX - width, y: rect.minY, width: width, height: rect.height))
    }
}
#endif

#endif
