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
            // Only a band around the thumb starts a scrub. This gesture used to
            // sit on the whole full-height strip with `minimumDistance: 0`, so
            // any swipe that *began* anywhere in the trailing 44pt was captured
            // as a scrub instead of a scroll — and on a short library a stray
            // scrub flung the grid past its end into empty space, the "grid goes
            // away" bug. Restricting the hit region to the thumb lets an ordinary
            // swipe fall straight through to the scroll view, which stops at the
            // last row on its own. `contentShape` governs only where a touch may
            // *start*: a scrub already under way keeps tracking past the band, so
            // the thumb still follows your finger the length of the track.
            // Verified in an isolated simulator repro — a swipe off the band
            // scrolls (and clamps), a swipe on it scrubs.
            .contentShape(ScrubberGrab(thumbY: y, thumbHeight: thumbHeight, pad: 22))
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

    /// The band, centred on the thumb, where a touch may begin a scrub.
    ///
    /// Everything outside it falls through to the scroll view, which is what
    /// keeps an ordinary swipe near the right edge from being hijacked into a
    /// scrub. `pad` widens the thin thumb into a comfortable target without
    /// making the whole strip greedy.
    private struct ScrubberGrab: Shape {
        let thumbY: CGFloat
        let thumbHeight: CGFloat
        let pad: CGFloat
        func path(in rect: CGRect) -> Path {
            let top = max(thumbY - pad, 0)
            let bottom = min(thumbY + thumbHeight + pad, rect.height)
            return Path(CGRect(x: 0, y: top, width: rect.width, height: max(bottom - top, 0)))
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
    /// How much further the grid could travel toward the newest, in points.
    ///
    /// Taken from where the visible window sits within the content, not from
    /// `offset` and `scrollable`. Those two are the scrubber's arithmetic and
    /// deliberately ignore insets, so their difference is not zero at the end —
    /// measured, it rests at around 54 on this layout and around 137 once the
    /// bottom inset is added back, either of which is wider than the window this
    /// is meant to detect and both of which move with the chrome. The bottom of
    /// the visible rect meeting the bottom of the content is the same fact
    /// stated in a way no inset can shift. Goes negative while bounced past the
    /// end.
    var toEnd: Double
    /// The full height of the scroll content, and the top inset applied to it.
    ///
    /// Neither is used for scrolling — they are here so `LayoutWatch` can see
    /// the grid being resized underneath the user, which is what a glitch
    /// actually is.
    var contentHeight: Double = 0
    var insetTop: Double = 0
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

    /// Was true while the chrome "stood down" on scroll; a constant now. Hiding
    /// a bar resizes the scroll view's safe area, and on a short library that
    /// resize re-realised a grid row, which changed the content height, which
    /// toggled the chrome again — a feedback loop that flung the grid past its
    /// end (confirmed on device). Static bars break it. Left in place, rather
    /// than deleted from every reader, so the nav bar, tab bar and zoom pill
    /// just stay up.
    let chromeHidden = false

    /// Whether the floating top bar has slid away.
    ///
    /// Driven by scroll *direction* and read only by the overlay bar — never by
    /// the scroll view's insets. That is the whole difference from `chromeHidden`
    /// above: moving an overlay cannot resize the scroll view, so flipping this
    /// can't feed the layout storm that toggling the real bar did. Scrolling up
    /// into older photos slides the bar away for room; scrolling back down
    /// toward the newest brings it back. Flips a handful of times per scroll
    /// (never per frame), so the one view that reads it is cheap to invalidate.
    var topBarHidden = false

    private var lastOffset: Double = 0
    private var haveOffset = false
    /// One-way accumulated travel, so a decisive run flips the bar rather than a
    /// stray pixel of jitter.
    private var travel: Double = 0

    func apply(_ report: ScrollReport) {
        let next = report.scrollable > 1
            ? (report.offset / report.scrollable).clamped(to: 0...1)
            : 0
        // Guarded: `@Observable` notifies on every set, equal value or not.
        if fraction != next { fraction = next }
        trackDirection(offset: report.offset)

        // Resting on the newest brings the bar back, whichever way you arrived.
        //
        // This grid runs oldest→newest and opens at the *bottom*, so that end —
        // not the scroll view's top — is the position the library returns to,
        // and chrome you cannot get back by going home is chrome you have lost.
        //
        // It also repairs the case that sent me looking: a fling back to the
        // newest ends in a bounce, and a bounce settles by travelling *backwards*
        // a few points. That trailing reversal was enough to re-hide a bar the
        // fling itself had just brought back, so arriving at the end read as
        // scrolling away from it. Measured in points rather than as a fraction
        // of the range, because on a large library a fraction of the scrollable
        // height is hundreds of points and the bar would return long before you
        // did.
        if report.toEnd < 24, topBarHidden {
            topBarHidden = false
            travel = 0
        }
    }

    /// Brings the bar back for a reason other than scrolling.
    ///
    /// Arriving somewhere is not the same as travelling: coming back from the
    /// viewer, the grid is re-anchored under you by `followViewer`, and that
    /// lands as one enormous offset delta. Counting it as travel would hide the
    /// bar again in the same breath it was shown, so the baseline is dropped
    /// here and the next report re-establishes it without a delta.
    func showTopBar() {
        if topBarHidden { topBarHidden = false }
        travel = 0
        haveOffset = false
    }

    /// Flips `topBarHidden` from the direction of travel, with a small deadband
    /// and a threshold so an ordinary scroll — not jitter — moves the bar.
    private func trackDirection(offset: Double) {
        defer { lastOffset = offset }
        guard haveOffset else { haveOffset = true; return }
        let delta = offset - lastOffset
        guard abs(delta) > 0.5 else { return }
        // A jump this big is not a finger.
        //
        // The lazy grid's content height changes as buckets realise, and the
        // scroll view keeps your position by moving the offset to match — a
        // single report can shift by thousands of points without the grid
        // appearing to move at all. Counting that as travel is how the bar came
        // to hide itself while you were scrolling towards the newest: one
        // correction of -8514pt outweighed the entire gesture. Sixteen
        // milliseconds of even a hard fling is nowhere near this, so anything
        // past it is the content resizing underneath us. Dropped, and the
        // `defer` re-baselines from the new offset.
        guard abs(delta) < 400 else { travel = 0; return }
        if delta < 0 {                                   // toward older (up) → hide
            travel = Swift.min(travel, 0) + delta
            if travel < -24, !topBarHidden { travel = 0; topBarHidden = true }
        } else {                                         // toward newer (down) → show
            travel = Swift.max(travel, 0) + delta
            if travel > 24, topBarHidden { travel = 0; topBarHidden = false }
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
                    scrollable: geometry.contentSize.height - geometry.containerSize.height,
                    toEnd: geometry.contentSize.height - geometry.visibleRect.maxY,
                    contentHeight: geometry.contentSize.height,
                    insetTop: geometry.contentInsets.top
                )
            } action: { _, report in
                progress.apply(report)
                #if os(iOS)
                LayoutWatch.shared.saw(report)
                #endif
            }
        } else {
            content
        }
    }
}

#if os(iOS)
/// Watches the grid for movement the user did not ask for.
///
/// A glitch, described precisely, is one of two things: the scroll *content*
/// changing size under a view that is already settled, or the *offset* jumping
/// without a finger on the glass. Both are visible in the scroll geometry and
/// neither is visible in a screenshot, which is why chasing this by eye kept
/// producing plausible wrong answers.
///
/// Writes into the same ring buffer as everything else, so Settings → Export
/// Playback Logs carries it off a phone that is nowhere near a Mac.
///
/// Deliberately not a debug-only build flag. The bug is intermittent and
/// happens on his device and not this one; something that has to be specially
/// compiled in is something that is never on when the interesting launch
/// happens.
@MainActor
final class LayoutWatch {
    static let shared = LayoutWatch()

    /// Content-height changes below this are the lazy stack breathing as rows
    /// realise, and would drown the signal.
    private static let heightNoise: Double = 1
    /// An offset move larger than this between two reports is not a finger.
    /// A hard fling is ~80pt per frame; 400 leaves five times the headroom, and
    /// is the same number `trackDirection` uses to spot the same thing.
    private static let jumpFloor: Double = 400
    /// Enough to cover a launch and then some, then silence. The failure is in
    /// the first seconds and an unbounded log of every resize would bury it.
    private static let budget = 120

    private var lastHeight: Double?
    private var lastOffset: Double?
    private var lastInset: Double?
    private var spent = 0
    private let startedAt = Date()

    func saw(_ report: ScrollReport) {
        guard spent < Self.budget else { return }

        let since = String(format: "%.2fs", Date().timeIntervalSince(startedAt))

        // The inset is ours — it comes from `windowTopInset` plus the bar — so a
        // change here is the app moving its own goalposts, not data arriving.
        if let was = lastInset, abs(report.insetTop - was) > 0.5 {
            spend("[\(since)] top inset \(Self.pt(was)) → \(Self.pt(report.insetTop))")
        }
        lastInset = report.insetTop

        if let was = lastHeight, abs(report.contentHeight - was) > Self.heightNoise {
            let delta = report.contentHeight - was
            spend(
                "[\(since)] content \(Self.pt(was)) → \(Self.pt(report.contentHeight))"
                    + " (\(delta > 0 ? "+" : "")\(Self.pt(delta)))"
                    + ", offset \(Self.pt(report.offset))"
            )
        }
        lastHeight = report.contentHeight

        if let was = lastOffset, abs(report.offset - was) > Self.jumpFloor {
            spend(
                "[\(since)] offset jumped \(Self.pt(was)) → \(Self.pt(report.offset))"
                    + " — no gesture moves this far in one frame"
            )
        }
        lastOffset = report.offset
    }

    /// Notes something the grid did to itself, for correlating against the
    /// geometry above — "content grew" is only half an answer without "because
    /// twelve more days arrived".
    func note(_ what: String) {
        guard spent < Self.budget else { return }
        spend("[\(String(format: "%.2fs", Date().timeIntervalSince(startedAt)))] \(what)")
    }

    private func spend(_ message: String) {
        spent += 1
        Diagnostics.shared.log(.layout, message)
        if spent == Self.budget {
            Diagnostics.shared.log(.layout, "budget spent — no further layout notes")
        }
    }

    private static func pt(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
}
#endif
