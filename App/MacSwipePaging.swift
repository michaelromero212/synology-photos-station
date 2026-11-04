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
/// targets: from the page the swipe began on, one page the way it went, once
/// it has carried a tenth of a page or was quick about it.
///
/// One page at a time however hard the swipe, as before. A scroll to a page
/// (opening a photo, ⌘→, the next video) isn't a swipe and is left alone.
struct SwipePaging: ScrollTargetBehavior {
    /// The black between pages: each page is the window wide plus this.
    let gap: CGFloat

    /// How far a swipe and its glide must carry the page for it to turn, as a
    /// share of a page: about a hand's width on a large window.
    static let reach: CGFloat = 0.1
    /// Or how fast, in points a second, however short.
    static let flick: CGFloat = 250

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let stride = context.containerSize.width + gap
        guard stride > 1 else { return }
        let travelable = max(0, context.contentSize.width - context.containerSize.width)
        target.rect.origin.x = Self.offset(
            from: context.originalTarget.rect.minX,
            proposed: target.rect.minX,
            speed: context.velocity.dx,
            stride: stride,
            lastPage: (travelable / stride + 0.01).rounded(.down)
        )
    }

    /// Where a swipe that began at `start` ends, given where the scroll view
    /// proposed it would and how fast it was going.
    static func offset(
        from start: CGFloat, proposed: CGFloat, speed: CGFloat, stride: CGFloat, lastPage: CGFloat
    ) -> CGFloat {
        let proposedPage = proposed / stride
        // Already exactly on a page: a scroll to one, not a swipe.
        if abs(proposedPage - proposedPage.rounded()) < 0.001 { return proposed }
        let startPage = (start / stride).rounded()
        let travel = proposedPage - startPage
        var page = startPage
        if travel > reach || (travel > 0 && speed > flick) {
            page += 1
        } else if travel < -reach || (travel < 0 && speed < -flick) {
            page -= 1
        }
        return min(max(page, 0), lastPage) * stride
    }
}
#endif
