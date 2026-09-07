#if DEBUG
import SwiftUI

/// Temporary on-device instrumentation for the grid-scroll investigation.
///
/// Prints to the Xcode console with a `🧭` prefix so it is easy to spot and
/// grep. Remove once the "grid disappears / scrolls into a void at the bottom"
/// behaviour is understood. Everything here is wrapped in `#if DEBUG`, so it
/// never ships in a release build.
///
/// Legend for `🧭[SCROLL]`:
///   off       — contentOffset.y (how far scrolled; 0 = top)
///   max       — the furthest a normal scroll should rest (content − container)
///   over      — off − max. **Positive-and-staying = scrolled past the end (the void).**
///   content   — total content height. If this balloons far past the media, it
///               is an over-reservation problem, not a gesture problem.
///   container — the viewport height
///   insetB    — bottom safe-area inset the scroll view is honouring
struct ScrollDebugLogger: ViewModifier {
    let tag: String

    @State private var lastOffset: CGFloat = -99_999
    @State private var lastContent: CGFloat = -1
    @State private var wasOver = false

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, tvOS 18.0, *) {
            content.onScrollGeometryChange(for: Geo.self) { g in
                Geo(
                    offset: g.contentOffset.y,
                    content: g.contentSize.height,
                    container: g.containerSize.height,
                    insetB: g.contentInsets.bottom
                )
            } action: { _, geo in
                let maxOff = max(geo.content - geo.container, 0)
                let over = geo.offset - maxOff
                let isOver = over > 1
                let contentChanged = abs(geo.content - lastContent) > 1

                // Log on meaningful movement, when the content size changes, and
                // — always — the moment we cross into or out of overscroll, so
                // the void shows up as a clean edge in the trace.
                if abs(geo.offset - lastOffset) >= 40 || contentChanged || isOver != wasOver || isOver {
                    print(String(
                        format: "🧭[SCROLL:%@] off=%.0f max=%.0f over=%.0f content=%.0f container=%.0f insetB=%.0f%@",
                        tag, geo.offset, maxOff, over, geo.content, geo.container, geo.insetB,
                        isOver ? "  ⚠️ PAST END" : ""
                    ))
                    lastOffset = geo.offset
                    lastContent = geo.content
                    wasOver = isOver
                }
            }
        } else {
            content
        }
    }

    private struct Geo: Equatable {
        var offset: CGFloat
        var content: CGFloat
        var container: CGFloat
        var insetB: CGFloat
    }
}

extension View {
    func scrollDebug(_ tag: String) -> some View { modifier(ScrollDebugLogger(tag: tag)) }
}
#endif
