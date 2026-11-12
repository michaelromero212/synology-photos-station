#if os(macOS)
import SwiftUI

/// Two fingers turn the page as they do in Photos: a short swipe, or a quick
/// one, is enough.
///
/// `.viewAligned` went to whichever page was nearest where the swipe and its
/// glide would have come to rest, so a swipe had to carry a photo more than
/// halfway across the window or it sprang back, and turning the page took two
/// or three tries. Photos, like Safari's back and forward, uses AppKit's page
/// swipe instead, which decides by direction: the photo follows the fingers,
/// and on release a flick, or a drag a little way, turns the page; only a
/// small or slow one springs back. This does the same with a scroll view's
/// targets: from where the swipe began, one page the way it went, once it has
/// carried a tenth of a page or was quick about it.
///
/// One page at a time however hard the swipe, as before.
///
/// Only swipes are steered, and only relative to where they began. Where the
/// scroll view places a page itself — opening a photo, ⌘→ to the next video,
/// the window changing size — it is left alone: it placed the page by the
/// page's own frame, by its id. Working a position out as page number times
/// page width was wrong whenever those weren't the pages' real places: the
/// stack is lazy, so the widths of pages it hasn't built are estimates, and a
/// tiled window has laid every page out a point wider than the window. A
/// photo hundreds of pages in sat hundreds of points off, half out of view.
struct SwipePaging: ScrollTargetBehavior {
    /// The black between pages: each page is the window wide plus this.
    let gap: CGFloat
    /// The pages' real width, gap included, as they last laid out. See
    /// `PagerMetrics`.
    let metrics: PagerMetrics

    /// How far a swipe and its glide must carry the page for it to turn, as a
    /// share of a page: about a hand's width on a large window.
    static let reach: CGFloat = 0.1
    /// Or how fast, in points a second, however short.
    static let flick: CGFloat = 250

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let measured = metrics.stride
        let stride = measured > 1 ? measured : context.containerSize.width + gap
        guard stride > 1 else { return }
        let travelable = max(0, context.contentSize.width - context.containerSize.width)
        if let aim = Self.aim(
            from: context.originalTarget.rect.minX, proposed: target.rect.minX,
            speed: context.velocity.dx, stride: stride, travelable: travelable
        ) {
            target.rect.origin.x = aim
        }
    }

    /// Where a swipe that began at `start` should end, given where the scroll
    /// view proposed it would and how fast it was going: the next page that
    /// way, the previous one, or back where it began. Nil when it isn't a
    /// swipe — nothing moved and nothing was thrown — and the scroll view's
    /// own place stands.
    static func aim(
        from start: CGFloat, proposed: CGFloat, speed: CGFloat,
        stride: CGFloat, travelable: CGFloat
    ) -> CGFloat? {
        guard speed != 0 || abs(proposed - start) >= 0.5 else { return nil }
        let travel = (proposed - start) / stride
        var step: CGFloat = 0
        if travel > reach || (travel > 0 && speed > flick) {
            step = 1
        } else if travel < -reach || (travel < 0 && speed < -flick) {
            step = -1
        }
        let aim = start + step * stride
        // No page that way: past the first or the last, it stays.
        return aim < -0.5 || aim > travelable + 0.5 ? start : aim
    }
}

/// What the pager knows about its pages that the scroll view doesn't say: how
/// wide they really are, and whether the window is in the middle of changing
/// size.
///
/// A reference, read by `SwipePaging` and written by the pages as they lay
/// out, so a new width never re-renders anything. Main thread only, which is
/// where SwiftUI asks for scroll targets.
final class PagerMetrics: @unchecked Sendable {
    /// A page's width plus the gap after it, measured.
    var stride: CGFloat = 0
    /// Set while the window is changing size, and a moment after. The page
    /// the scroll view reports then is whatever the old offset falls on in
    /// the new layout — not a page anyone turned to.
    var isResizing = false
    var settle: Task<Void, Never>?
}
#endif
