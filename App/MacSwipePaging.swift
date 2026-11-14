#if os(macOS)
import AppKit
import FrameStationAPI
import SwiftUI

/// The Mac viewer's pages: two fingers turn one page, as in Photos.
///
/// It was a paging `ScrollView` over a `LazyHStack` of every photo loaded, and
/// that could not be made to behave. A lazy stack only guesses where the pages
/// it hasn't built are, and corrects the guesses as it builds them — mid-swipe,
/// most of all when a swipe reverses — so the scroll position under the
/// fingers moved by tens of thousands of points (sixty pages, measured), and
/// whatever steered the swipe home then carried the pager through the library
/// by itself. Builds 33 to 41 each patched a way it ran off; the guessing
/// remained.
///
/// So nothing here scrolls. There are three pages — the one on screen and one
/// either side — laid side by side at exact multiples of the window's width,
/// and a swipe moves them by the fraction of a page AppKit reports. That is
/// `NSEvent.trackSwipeEvent`, the page swipe Safari and Photos use: it follows
/// the fingers, decides from the fingers' distance and speed whether the page
/// turns, animates the rest of the way with Apple's own curve, rubber-bands
/// where there is no page, and never goes more than one page per swipe. When a
/// page has turned, the three move along by one in the same frame the swipe
/// ends, so nothing on screen jumps.
///
/// Where the system's page swipe is off (System Settings › Trackpad › Swipe
/// between pages) the fingers are followed by hand, with the same one-page
/// rule; a mouse's sideways wheel turns one page per flick.
struct MacPageStrip<Page: View>: View {
    let items: [TimelineItem]
    let currentID: UUID
    /// One page: the whole width the pager covers, sidebar included.
    let pageSize: CGSize
    /// Black between two pages, seen only mid-swipe.
    let gap: CGFloat
    /// Where swipes are taken: the strip, less what the sidebar covers.
    let swipeInsets: EdgeInsets
    /// A zoomed photo keeps two fingers for panning, as in Photos.
    let isLocked: Bool
    let onTurn: (TimelineItem) -> Void
    @ViewBuilder let page: (TimelineItem) -> Page

    @State private var swipe = PageSwipe()

    private var index: Int { items.firstIndex { $0.id == currentID } ?? 0 }
    private var stride: CGFloat { pageSize.width + gap }

    var body: some View {
        let index = index
        let shown = (index - 1 ... index + 1).filter { items.indices.contains($0) }
        ZStack(alignment: .topLeading) {
            // By id, so a page keeps its state — its picture, its player — as
            // it moves from beside the one on screen to on screen.
            ForEach(shown.map { items[$0] }) { item in
                let slot = CGFloat((items.firstIndex { $0.id == item.id } ?? index) - index)
                page(item)
                    .frame(width: pageSize.width, height: pageSize.height)
                    .offset(x: slot * stride)
            }
        }
        .modifier(SwipeShift(swipe: swipe, stride: stride))
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        .clipped()
        .background {
            PageSwipeCatcher(
                swipe: swipe,
                canGoBack: index > 0,
                canGoForward: index < items.count - 1,
                isLocked: isLocked,
                pageWidth: pageSize.width,
                onTurn: turn
            )
            .padding(swipeInsets)
        }
        // Another page chosen — Next Video, auto-play, the grid behind — while
        // a swipe was settling: the swipe is over.
        .onChange(of: currentID) { _, _ in swipe.reset() }
    }

    /// The page on screen is now the one `step` away: −1 back, +1 forward.
    private func turn(_ step: Int) {
        let target = index + step
        guard items.indices.contains(target) else {
            swipe.reset()
            return
        }
        // Both in one frame and without animation: the page that slid into
        // place is drawn where it already is, now as the page on screen.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            swipe.reset()
            onTurn(items[target])
        }
    }
}

/// How far a swipe has carried the pages: 0 at rest, toward +1 as the page
/// before comes in (fingers moving right), toward −1 for the page after.
///
/// Its own observable, read only by `SwipeShift`, so a swipe moves the three
/// pages without redrawing them or the viewer.
@Observable
@MainActor
final class PageSwipe {
    var progress: CGFloat = 0
    @ObservationIgnored var isTracking = false

    func reset() {
        progress = 0
        isTracking = false
    }
}

private struct SwipeShift: ViewModifier {
    let swipe: PageSwipe
    let stride: CGFloat

    func body(content: Content) -> some View {
        content.offset(x: swipe.progress * stride)
    }
}

/// Takes the swipes over the pager, and nothing else.
///
/// A local event monitor rather than an `NSView` in the responder chain: the
/// scroll events land on whatever is under the pointer — the photo's own
/// magnifying scroll view, a video's layer, SwiftUI's hosting view — and only
/// some of those pass them on.
private struct PageSwipeCatcher: NSViewRepresentable {
    let swipe: PageSwipe
    let canGoBack: Bool
    let canGoForward: Bool
    let isLocked: Bool
    let pageWidth: CGFloat
    let onTurn: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.update(self)
        context.coordinator.start()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        private var settings: PageSwipeCatcher?
        private var monitor: Any?

        /// This gesture has been looked at: it is a page swipe, or it went up
        /// or down and isn't one. Cleared when the fingers come off.
        private var decided = false
        /// Following the fingers by hand (system page swipe off).
        private var manualTravel: CGFloat?
        /// A mouse's sideways wheel: what it has turned since the last page,
        /// and when that page turned.
        private var wheelTravel: CGFloat = 0
        private var wheelTurnedAt = Date.distantPast

        func update(_ settings: PageSwipeCatcher) { self.settings = settings }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func isOverPager(_ event: NSEvent) -> Bool {
            guard let view, let window = view.window, event.window === window,
                  !view.isHiddenOrHasHiddenAncestor else { return false }
            return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }

        private func handle(_ event: NSEvent) {
            guard let settings else { return }
            let swipe = settings.swipe

            if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                decided = false
            }

            // Fingers on the trackpad.
            if !event.phase.isEmpty {
                if let travel = manualTravel {
                    followByHand(event, travel: travel)
                    return
                }
                guard !decided, !swipe.isTracking, !settings.isLocked, isOverPager(event) else { return }
                let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
                guard dx != 0 || dy != 0 else { return }
                decided = true
                // Mostly sideways, or it is a scroll of something else.
                guard abs(dx) > abs(dy) else { return }
                if NSEvent.isSwipeTrackingFromScrollEventsEnabled {
                    track(event, settings: settings)
                } else {
                    manualTravel = 0
                    swipe.isTracking = true
                    followByHand(event, travel: 0)
                }
                return
            }

            // A mouse's sideways wheel: no phases, no glide.
            guard event.momentumPhase.isEmpty, !swipe.isTracking, !settings.isLocked,
                  isOverPager(event) else { return }
            let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 12
            guard abs(dx) > abs(event.scrollingDeltaY), dx != 0 else { return }
            guard Date().timeIntervalSince(wheelTurnedAt) > 0.45 else { return }
            wheelTravel += dx
            guard abs(wheelTravel) >= 24 else { return }
            let step = wheelTravel > 0 ? -1 : 1
            wheelTravel = 0
            wheelTurnedAt = Date()
            slide(step, settings: settings)
        }

        /// The system's page swipe: AppKit follows the fingers, decides, and
        /// animates; this only moves the pages to where it says.
        private func track(_ event: NSEvent, settings: PageSwipeCatcher) {
            let swipe = settings.swipe
            swipe.isTracking = true
            var direction = 0
            event.trackSwipeEvent(
                options: [.lockDirection, .clampGestureAmount],
                // Where there is no page that way, the pages only give a
                // little and spring back.
                dampenAmountThresholdMin: settings.canGoForward ? -1 : 0,
                max: settings.canGoBack ? 1 : 0
            ) { [weak self] amount, phase, isComplete, _ in
                MainActor.assumeIsolated {
                    guard let self, let settings = self.settings, settings.swipe === swipe else { return }
                    swipe.progress = amount
                    switch phase {
                    // Let go far enough or fast enough: the page will turn.
                    case .ended: direction = amount > 0 ? -1 : (amount < 0 ? 1 : 0)
                    case .cancelled: direction = 0
                    default: break
                    }
                    guard isComplete else { return }
                    if direction != 0 {
                        settings.onTurn(direction)
                    } else {
                        swipe.reset()
                    }
                }
            }
        }

        /// The fingers followed by hand, where the system page swipe is off.
        private func followByHand(_ event: NSEvent, travel: CGFloat) {
            guard let settings else { return }
            let swipe = settings.swipe
            let width = max(settings.pageWidth, 1)
            let total = travel + event.scrollingDeltaX
            manualTravel = total
            var fraction = total / width
            // No page that way: it gives a little, as AppKit's does.
            if fraction > 0 && !settings.canGoBack { fraction *= 0.2 }
            if fraction < 0 && !settings.canGoForward { fraction *= 0.2 }
            swipe.progress = min(max(fraction, -1), 1)

            guard event.phase.contains(.ended) || event.phase.contains(.cancelled) else { return }
            manualTravel = nil
            let speed = event.scrollingDeltaX
            var step = 0
            if fraction > 0.15 || speed > 8 { step = settings.canGoBack ? -1 : 0 }
            if fraction < -0.15 || speed < -8 { step = settings.canGoForward ? 1 : 0 }
            if event.phase.contains(.cancelled) { step = 0 }
            if step == 0 {
                withAnimation(.smooth(duration: 0.25)) { swipe.progress = 0 } completion: {
                    swipe.reset()
                }
            } else {
                slide(step, settings: settings)
            }
        }

        /// Finishes a page turn the fingers didn't: the rest of the way, then
        /// the turn itself.
        private func slide(_ step: Int, settings: PageSwipeCatcher) {
            let swipe = settings.swipe
            guard step < 0 ? settings.canGoBack : settings.canGoForward else {
                withAnimation(.smooth(duration: 0.25)) { swipe.progress = 0 } completion: {
                    swipe.reset()
                }
                return
            }
            swipe.isTracking = true
            withAnimation(.smooth(duration: 0.28)) {
                swipe.progress = step < 0 ? 1 : -1
            } completion: {
                settings.onTurn(step)
            }
        }
    }
}
#endif
