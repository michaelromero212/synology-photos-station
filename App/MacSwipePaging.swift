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
/// and a swipe moves them with the fingers. When a page has turned, the three
/// move along by one in the same frame the swipe ends, so nothing on screen
/// jumps.
///
/// One swipe, one page — and every swipe counts. Build 42 handed the decision
/// to AppKit's page-swipe tracker (`NSEvent.trackSwipeEvent`, Safari's back
/// gesture), and it often took two or three tries: the tracker wants more
/// travel or speed than a photo viewer should, and the gesture was judged on
/// its very first movement, so a swipe that began a touch diagonal was taken
/// for a scroll and ignored. Now the fingers are followed here: the direction
/// is judged after a few points, generously sideways; on lift, a modest
/// distance or a modest flick turns the page, a small slow nudge springs back,
/// and a swipe begun while the last is still settling counts too. A mouse's
/// sideways wheel turns one page per flick. See `PageSwipeRules`.
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
        // a swipe was settling: the swipe is over. Not while fingers are on
        // the trackpad: a swipe begun mid-settle has just turned the page
        // itself, and is already moving the new one.
        .onChange(of: currentID) { _, _ in
            if !swipe.isTracking { swipe.reset() }
        }
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
    /// The fingers are on the trackpad, moving the pages.
    @ObservationIgnored var isTracking = false
    /// The pages finishing a swipe on their own, and the turn they end in
    /// (0: springing back). Nil at rest.
    @ObservationIgnored var settling: Int?
    /// Bumped by everything that ends a settle early, so the animation's own
    /// ending, arriving after, knows it is too late to act.
    @ObservationIgnored var generation = 0

    func reset() {
        progress = 0
        isTracking = false
        settling = nil
        generation += 1
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

        /// What the gesture under the fingers has turned out to be.
        private enum Reading { case undecided, pages, ignored }
        private var reading = Reading.ignored
        /// Where the fingers have taken the content since they touched down,
        /// in points: positive is rightward, toward the page before.
        private var travelX: CGFloat = 0
        private var travelY: CGFloat = 0
        /// The last moments of sideways movement, for how fast it was going
        /// when the fingers came off.
        private var samples: [(time: TimeInterval, dx: CGFloat)] = []
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
            // The glide after the fingers lift never moves a page: the swipe
            // has already been decided by then.
            guard event.momentumPhase.isEmpty else { return }
            if event.phase.isEmpty {
                wheel(event, settings: settings)
            } else {
                fingers(event, settings: settings)
            }
        }

        // MARK: Two fingers

        private func fingers(_ event: NSEvent, settings: PageSwipeCatcher) {
            let phase = event.phase
            if phase.contains(.mayBegin) { return }
            if phase.contains(.began) {
                reading = .undecided
                travelX = 0
                travelY = 0
                samples = []
            }
            let ends = phase.contains(.ended) || phase.contains(.cancelled)

            switch reading {
            case .ignored:
                return

            case .undecided:
                travelX += event.scrollingDeltaX
                travelY += event.scrollingDeltaY
                // Judged once the fingers have gone somewhere, not on their
                // first twitch.
                guard hypot(travelX, travelY) >= PageSwipeRules.judgeAfter else {
                    if ends { reading = .ignored }
                    return
                }
                guard !settings.isLocked, isOverPager(event),
                      PageSwipeRules.isSideways(dx: travelX, dy: travelY) else {
                    reading = .ignored
                    return
                }
                reading = .pages
                // A swipe begun while the last one is still settling: that
                // one is finished now, and this one starts from the page it
                // was turning to.
                finishSettling(settings)
                settings.swipe.isTracking = true
                samples.append((event.timestamp, event.scrollingDeltaX))
                follow(settings)
                if ends { release(phase.contains(.cancelled), settings: settings) }

            case .pages:
                travelX += event.scrollingDeltaX
                if event.scrollingDeltaX != 0 {
                    samples.append((event.timestamp, event.scrollingDeltaX))
                    samples.removeAll { event.timestamp - $0.time > PageSwipeRules.speedWindow }
                }
                follow(settings)
                if ends { release(phase.contains(.cancelled), settings: settings) }
            }
        }

        /// The pages under the fingers, giving a little where there is no page.
        private func follow(_ settings: PageSwipeCatcher) {
            settings.swipe.progress = PageSwipeRules.progress(
                travel: travelX, width: settings.pageWidth,
                canGoBack: settings.canGoBack, canGoForward: settings.canGoForward
            )
        }

        private func release(_ cancelled: Bool, settings: PageSwipeCatcher) {
            reading = .ignored
            let speed = PageSwipeRules.speed(samples)
            samples = []
            let step = cancelled ? 0 : PageSwipeRules.decide(
                travel: travelX, width: settings.pageWidth, speed: speed,
                canGoBack: settings.canGoBack, canGoForward: settings.canGoForward
            )
            settle(step, speed: speed, settings: settings)
        }

        // MARK: A mouse's sideways wheel

        private func wheel(_ event: NSEvent, settings: PageSwipeCatcher) {
            guard settings.swipe.settling == nil, !settings.isLocked, isOverPager(event) else { return }
            let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 12
            guard abs(dx) > abs(event.scrollingDeltaY), dx != 0 else { return }
            guard Date().timeIntervalSince(wheelTurnedAt) > 0.45 else { return }
            wheelTravel += dx
            guard abs(wheelTravel) >= 24 else { return }
            let step = wheelTravel > 0 ? -1 : 1
            wheelTravel = 0
            wheelTurnedAt = Date()
            guard step < 0 ? settings.canGoBack : settings.canGoForward else { return }
            settle(step, speed: 0, settings: settings)
        }

        // MARK: Settling

        /// The rest of the way: to the next page, the one before, or back
        /// where the swipe began (`step` 0). Quicker after a quick swipe, so
        /// the page carries on at about the speed the fingers left it.
        private func settle(_ step: Int, speed: CGFloat, settings: PageSwipeCatcher) {
            let swipe = settings.swipe
            swipe.isTracking = false
            swipe.generation += 1
            let generation = swipe.generation
            swipe.settling = step
            let target: CGFloat = step == 0 ? 0 : (step < 0 ? 1 : -1)
            let remaining = abs(target - swipe.progress) * settings.pageWidth
            let duration = PageSwipeRules.settleDuration(remaining: remaining, speed: speed)
            withAnimation(.smooth(duration: duration)) {
                swipe.progress = target
            } completion: { [weak self] in
                guard swipe.generation == generation else { return }
                if step == 0 {
                    swipe.reset()
                } else {
                    (self?.settings ?? settings).onTurn(step)
                }
            }
        }

        /// Ends a settle that is still under way, at once: the page it was
        /// turning to becomes the page on screen.
        private func finishSettling(_ settings: PageSwipeCatcher) {
            let swipe = settings.swipe
            guard let step = swipe.settling else { return }
            swipe.generation += 1
            swipe.settling = nil
            if step == 0 {
                swipe.reset()
            } else {
                settings.onTurn(step)
            }
            // The fingers start this swipe from where the new page rests.
        }
    }
}

/// When a swipe turns the page. Kept apart from the event handling so the
/// numbers can be checked on their own.
enum PageSwipeRules {
    /// How far the fingers move, in points, before the gesture is judged.
    static let judgeAfter: CGFloat = 6
    /// Sideways enough to be a page swipe: up to about 60° off horizontal.
    /// Nothing in the viewer scrolls up and down — a zoomed photo, which
    /// pans, takes no page swipes at all — so there is little to mistake.
    static func isSideways(dx: CGFloat, dy: CGFloat) -> Bool {
        abs(dx) >= abs(dy) * 0.6
    }

    /// A share of a page, carried by the fingers, that turns it however
    /// slowly they let go: about a thumb's width on a laptop screen.
    static let reach: CGFloat = 0.06
    /// Or a flick, in points a second, however short.
    static let flick: CGFloat = 160
    /// How far back the speed at release is measured.
    static let speedWindow: TimeInterval = 0.08

    /// −1 back, +1 forward, 0 stay. A flick back the other way cancels.
    static func decide(
        travel: CGFloat, width: CGFloat, speed: CGFloat,
        canGoBack: Bool, canGoForward: Bool
    ) -> Int {
        let share = travel / max(width, 1)
        let back = (share > reach && speed > -flick) || (share > 0 && speed > flick)
        let forward = (share < -reach && speed < flick) || (share < 0 && speed < -flick)
        if back && canGoBack { return -1 }
        if forward && canGoForward { return 1 }
        return 0
    }

    /// Points a second at release: the fingers' last moments of travel.
    /// Fingers that paused before lifting carry no speed.
    static func speed(_ samples: [(time: TimeInterval, dx: CGFloat)]) -> CGFloat {
        guard let last = samples.last else { return 0 }
        let recent = samples.filter { last.time - $0.time <= speedWindow }
        guard let first = recent.first else { return 0 }
        let span = max(last.time - first.time, 1.0 / 120)
        return recent.reduce(0) { $0 + $1.dx } / span
    }

    /// Where the pages sit under the fingers, as a share of a page.
    static func progress(travel: CGFloat, width: CGFloat, canGoBack: Bool, canGoForward: Bool) -> CGFloat {
        var share = travel / max(width, 1)
        // No page that way: it gives a little and no more.
        if share > 0 && !canGoBack { share = min(share * 0.25, 0.12) }
        if share < 0 && !canGoForward { share = max(share * 0.25, -0.12) }
        return min(max(share, -1), 1)
    }

    static func settleDuration(remaining: CGFloat, speed: CGFloat) -> Double {
        guard abs(speed) > 1 else { return 0.28 }
        return min(max(Double(remaining / abs(speed)) * 1.5, 0.16), 0.3)
    }
}
#endif
