import FrameStationAPI
import FrameStationKit
import Observation
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
    /// Where the viewport sits, 0…1. An object rather than a `Double` so that
    /// reading it invalidates *this* view and not the grid — see `ScrollProgress`.
    let progress: ScrollProgress
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
            let fraction = isDragging ? dragFraction : progress.fraction
            // Explicit CGFloat: `track` is CGFloat and `fraction` is Double, and
            // on a 64-bit platform those are the same type by typealias but not
            // to the type checker. Left implicit it cannot decide, and reports
            // the failure against whatever arithmetic it reaches next.
            let y: CGFloat = track * CGFloat(fraction.clamped(to: 0...1))
            let pillOffset: CGFloat = y + (thumbHeight - 32) / 2

            ZStack(alignment: .topTrailing) {
                Color.clear

                if isDragging, let label {
                    ScrubberPill(text: label)
                        .offset(x: -trackWidth, y: pillOffset)
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
                        let raw = Double(value.location.y - thumbHeight / 2)
                            / Double(max(track, 1))
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
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassCapsule(interactive: false, fallback: .regularMaterial)
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
    /// Shared with the zoom, which needs the same answer to know what to anchor
    /// on — two copies of this would eventually disagree, and the symptom would
    /// be a zoom that lands somewhere the scrubber says you weren't.
    private func bucket(at fraction: Double) -> TimelineBucket? {
        buckets.bucket(atFraction: fraction)
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

/// One reading of the grid's scroll position.
struct ScrollReport: Equatable {
    var offset: Double
    var scrollable: Double
}

/// Where the grid is scrolled to, and which way it's going.
///
/// A shared object rather than values passed down from the grid, and this is a
/// performance fix rather than a tidying one. `onScrollGeometryChange` fires
/// every frame of a scroll. Writing that into the grid's own `@State`
/// re-evaluated the entire timeline body at display rate — every section, every
/// cell, the merged backup queue, the lot — which is precisely what stopped a
/// fling from gliding. Holding it out here means each value lands only on the
/// views that read it.
///
/// The split matters: `fraction` changes every frame and belongs to the
/// scrubber alone, while `chromeHidden` flips a handful of times per scroll and
/// is the only property the grid itself reads. `@Observable` tracks per
/// property, so the grid is invalidated by the flip and never by the frame.
@Observable
@MainActor
final class ScrollProgress {
    var fraction: Double = 0

    /// True once the grid has been pushed far enough up that the title and the
    /// toolbar have stood down, leaving the pinned date as the only thing
    /// across the top.
    var chromeHidden = false

    /// The offset the current direction was measured from, re-anchored on every
    /// flip so a reversal is judged from the turning point rather than from
    /// wherever the scroll happened to begin.
    ///
    /// `@ObservationIgnored` is load-bearing: an observed write here would
    /// invalidate the grid on every frame, which is the exact cost the rest of
    /// this class is arranged to avoid.
    @ObservationIgnored private var pivot: Double = 0

    /// Enough travel to read as a decision rather than a wobble.
    private let threshold: Double = 14
    /// Near the top the chrome is always up, whatever the last direction was.
    /// Arriving at the top of your library with no title is disorienting.
    private let topZone: Double = 8

    func apply(_ report: ScrollReport) {
        let next = report.scrollable > 1
            ? (report.offset / report.scrollable).clamped(to: 0...1)
            : 0
        // Guarded rather than assigned blindly: `@Observable` notifies on every
        // set, equal value or not, so an unguarded write is a per-frame
        // invalidation wearing a disguise.
        if fraction != next { fraction = next }

        guard report.offset > topZone else {
            pivot = report.offset
            if chromeHidden { chromeHidden = false }
            return
        }

        let delta = report.offset - pivot
        if delta > threshold {
            pivot = report.offset
            if !chromeHidden { chromeHidden = true }
        } else if delta < -threshold {
            pivot = report.offset
            if chromeHidden { chromeHidden = false }
        }
    }
}

/// Feeds `ScrollProgress` from the grid's scroll view.
///
/// `onScrollGeometryChange` is iOS 18; on 17 the scrubber still scrubs and the
/// chrome simply stays up — a graceful loss rather than a broken screen.
struct ScrollActivityReporter: ViewModifier {
    let progress: ScrollProgress

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, tvOS 18.0, *) {
            content.onScrollGeometryChange(for: ScrollReport.self) { geometry in
                ScrollReport(
                    offset: geometry.contentOffset.y,
                    scrollable: geometry.contentSize.height - geometry.containerSize.height
                )
            } action: { _, report in
                progress.apply(report)
            }
        } else {
            content
        }
    }
}
