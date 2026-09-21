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
/// the library's density instead. August of a holiday year is a thick bright
/// band; the February you photographed a parcel is a hairline. You can see
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

    private let railWidth: CGFloat = 62
    private let barMaxWidth: CGFloat = 26
    /// How many bars the density strip is drawn with.
    ///
    /// Fixed rather than one per bucket: a day-zoomed library has thousands of
    /// buckets and a rail is six hundred points tall, so per-bucket bars would
    /// be sub-pixel slivers costing thousands of draw calls to look like a solid
    /// block. Aggregating into a fixed number of slots is both cheaper and more
    /// legible.
    private let slots = 90

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let fraction = isDragging ? dragFraction : progress.fraction

            ZStack(alignment: .topTrailing) {
                Color.clear

                density(height: height)
                years(height: height)
                position(height: height, fraction: fraction)

                // The pill follows the pointer while hovering and the finger
                // while dragging — whichever is asking.
                if let asking = hoverFraction ?? (isDragging ? dragFraction : nil),
                   let bucket = buckets.bucket(atFraction: asking) {
                    RailPill(
                        title: Self.pillTitle(for: bucket),
                        count: bucket.count
                    )
                    .offset(x: -railWidth + 6, y: height * asking - 18)
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
                    .onEnded { _ in
                        isDragging = false
                        onScrubEnd()
                    }
            )
            .animation(.easeOut(duration: 0.12), value: hoverFraction == nil)
            .animation(.easeOut(duration: 0.15), value: isDragging)
        }
        .frame(width: railWidth)
    }

    // MARK: - The strip

    /// The library's density, as bars whose length is how much you shot then.
    ///
    /// Square-rooted rather than linear. One extraordinary fortnight — a
    /// wedding, a first holiday with a new camera — is often an order of
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
                    with: .color(.primary.opacity(0.16 + 0.24 * scaled))
                )
            }
        }
        .allowsHitTesting(false)
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
        let marks = Self.yearMarks(buckets: buckets)
        let minimumGap: CGFloat = 22
        var lastY: CGFloat = -.greatestFiniteMagnitude

        return ZStack(alignment: .topTrailing) {
            ForEach(marks, id: \.year) { mark in
                let y = height * mark.fraction
                let fits = y - lastY >= minimumGap
                if fits { let _ = { lastY = y }() }
                Text(mark.year)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .opacity(fits ? 1 : 0)
                    .offset(x: -barMaxWidth - 6, y: y - 7)
            }
        }
        .allowsHitTesting(false)
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

#endif
