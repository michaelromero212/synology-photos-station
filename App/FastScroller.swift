import FrameStationAPI
import FrameStationKit
import SwiftUI

#if !os(tvOS)

/// Apple Photos-style scrubber down the trailing edge.
///
/// Two jobs, and they're easy to conflate: at rest it *reports* where you are in
/// the library, and under a drag it *drives* where you go. A library spanning
/// fifteen years is thousands of scroll-pages, so dragging a finger down the
/// edge is the only way to get from 2026 to 2011 without flinging repeatedly.
struct FastScroller: View {
    let buckets: [TimelineBucket]
    /// 0…1, where the viewport currently sits. Drives the resting indicator.
    let scrollFraction: Double
    /// Called continuously while dragging, with the bucket under the finger.
    let onScrub: (TimelineBucket) -> Void
    let onScrubEnd: () -> Void

    @State private var isDragging = false
    @State private var dragFraction: Double = 0
    @State private var label: String?

    private let trackWidth: CGFloat = 44
    private let thumbHeight: CGFloat = 36

    var body: some View {
        GeometryReader { proxy in
            let track = proxy.size.height - thumbHeight
            // While dragging the thumb follows the finger; otherwise it follows
            // the scroll view. Using the finger position during a drag matters —
            // deriving it from scroll offset makes the thumb lag its own gesture.
            let fraction = isDragging ? dragFraction : scrollFraction
            let y = track * fraction.clamped(to: 0...1)

            ZStack(alignment: .topTrailing) {
                Color.clear

                if isDragging, let label {
                    ScrubberPill(text: label)
                        .offset(x: -trackWidth, y: y + (thumbHeight - 32) / 2)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .allowsHitTesting(false)
                }

                thumb
                    .offset(y: y)
            }
            .frame(width: trackWidth, alignment: .trailing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            #if os(iOS)
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                            #endif
                        }
                        // Centre the thumb on the finger rather than pinning its
                        // top there, or the grid sits half a thumb off from
                        // where you're pointing.
                        let raw = (value.location.y - thumbHeight / 2) / max(track, 1)
                        dragFraction = raw.clamped(to: 0...1)
                        if let bucket = bucket(at: dragFraction) {
                            if label != Self.label(for: bucket) {
                                #if os(iOS)
                                UISelectionFeedbackGenerator().selectionChanged()
                                #endif
                            }
                            label = Self.label(for: bucket)
                            onScrub(bucket)
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        label = nil
                        onScrubEnd()
                    }
            )
            .animation(.easeOut(duration: 0.15), value: isDragging)
        }
        .frame(width: trackWidth)
    }

    /// Extracted rather than inlined.
    ///
    /// Not style: the enclosing `body` builds a ZStack whose contents depend on
    /// drag state, with offsets computed from a GeometryReader, and older
    /// Swift versions give up type-checking it and report the failure against
    /// whichever modifier they reached last — a misleading "ambiguous use of
    /// 'font'" on a line that is nothing of the sort. Small views keep each
    /// expression inside what the type checker will actually solve.
    private struct ScrubberPill: View {
        let text: String

        var body: some View {
            Text(text)
                .font(.subheadline)
                .fontWeight(.semibold)
                .fixedSize()
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.black.opacity(0.75), in: Capsule())
        }
    }

    private var thumb: some View {
        Capsule()
            .fill(isDragging ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .frame(width: isDragging ? 8 : 4, height: thumbHeight)
            .padding(.trailing, isDragging ? 6 : 8)
            .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: 3)
    }

    /// Which bucket a position along the track lands on.
    ///
    /// Weighted by item count, not by bucket index: a day with 200 photos is a
    /// long scroll and a day with 2 is not, so an even split would make busy
    /// stretches of the library nearly impossible to land in.
    private func bucket(at fraction: Double) -> TimelineBucket? {
        guard !buckets.isEmpty else { return nil }
        let total = buckets.reduce(0) { $0 + max($1.count, 1) }
        let target = Double(total) * fraction
        var running = 0.0
        for bucket in buckets {
            running += Double(max(bucket.count, 1))
            if running >= target { return bucket }
        }
        return buckets.last
    }

    /// `2026-07-18` → `JUL 2026`. Day precision is noise on a scrubber — you're
    /// navigating by season, not by date — and the short form keeps the pill
    /// narrow enough to sit beside the thumb without covering the grid.
    static func label(for bucket: TimelineBucket) -> String {
        let key = bucket.key
        if key.count == 4 { return key }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = key.count == 7 ? "yyyy-MM" : "yyyy-MM-dd"
        guard let date = parser.date(from: key) else { return key }
        let display = DateFormatter()
        display.timeZone = TimeZone(identifier: "UTC")
        display.locale = Locale(identifier: "en_US_POSIX")
        display.dateFormat = "MMM yyyy"
        return display.string(from: date).uppercased()
    }
}

#endif

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Reports how far the grid has scrolled, 0…1, so the resting indicator tracks it.
///
/// `onScrollGeometryChange` is iOS 18; on 17 the scroller still scrubs, it just
/// doesn't follow along at rest — a graceful loss rather than a broken control.
struct ScrollFractionReporter: ViewModifier {
    let onChange: (Double) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, tvOS 18.0, *) {
            content.onScrollGeometryChange(for: Double.self) { geometry in
                let scrollable = geometry.contentSize.height
                    - geometry.containerSize.height
                guard scrollable > 1 else { return 0 }
                return (geometry.contentOffset.y / scrollable).clamped(to: 0...1)
            } action: { _, fraction in
                onChange(fraction)
            }
        } else {
            content
        }
    }
}
