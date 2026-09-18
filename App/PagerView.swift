import FrameStationAPI
import Observation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Which page the viewer is on.
///
/// An observable rather than a plain `@State` on the viewer because the pages
/// are hosted inside UIKit view controllers built once and kept. They need to
/// notice becoming current — a video three swipes away must not be playing —
/// and reading it from here lets them, without the pager rebuilding every
/// page's root view on each change.
@Observable
@MainActor
final class PagerFocus {
    var currentID: UUID

    init(currentID: UUID) {
        self.currentID = currentID
    }
}

#if os(iOS)
/// Exists only to tell the coordinator when it has joined the navigation
/// hierarchy. There is no representable callback for that, and it is the moment
/// the back-swipe can be claimed.
private final class HostedPageViewController: UIPageViewController {
    var onAppear: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppear?()
    }
}

/// A pager that can actually be told where to go.
///
/// `TabView(.page)` cannot, and that is why video auto-advance dead-ended: it
/// materialises pages lazily, and setting its selection to a page it has not
/// built does nothing at all. The trace was unambiguous — the outgoing page
/// deselected, the incoming one never appeared, never loaded, and the viewer
/// sat on a frame with no player. No amount of deferring the assignment or
/// forcing view identity helps, because the destination does not exist.
///
/// `UIPageViewController` navigates by view controller rather than by tag, so
/// "go to this one" always has something to go to. It also asks its data source
/// for the pages either side as soon as it settles, which is the hook
/// preloading needs: the next video can start buffering while the current one
/// is still playing. `TabView` gives no such signal — in a full session it
/// built exactly one page.
///
/// The paging gesture is the same `UIScrollView` one either way, so the zoom
/// hand-off this viewer depends on is unchanged: a pinched photo keeps the drag
/// until its own content runs out, then the pager takes over.
struct PagerView<Page: View>: UIViewControllerRepresentable {
    let items: [TimelineItem]
    let focus: PagerFocus
    @ViewBuilder let page: (TimelineItem) -> Page

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = HostedPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: 12]
        )
        // At appear rather than in `updateUIViewController`: the controller is
        // not in the navigation hierarchy yet when the representable first
        // updates, so `navigationController` is nil and the swipe stays stolen.
        controller.onAppear = { [weak controller] in
            guard let controller else { return }
            context.coordinator.claimHorizontalDrags(in: controller)
        }
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.view.backgroundColor = .black

        if let start = context.coordinator.controller(for: focus.currentID) {
            controller.setViewControllers([start], direction: .forward, animated: false)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.parent = self

        // Never while a swipe is in flight, and this is the whole reason
        // backwards paging appeared broken.
        //
        // During an interactive transition `viewControllers.first` already
        // reports the *incoming* page, so any SwiftUI update mid-drag — and a
        // playing video causes plenty — saw a controller that didn't match
        // `focus`, decided the pager was in the wrong place, and called
        // `setViewControllers` back to where the swipe started. The drag was
        // being cancelled by its own view update, a frame before it committed.
        guard !context.coordinator.isTransitioning else { return }

        guard let target = context.coordinator.controller(for: focus.currentID) else { return }
        let showing = controller.viewControllers?.first
        guard showing !== target else { return }

        // Direction matters for more than polish: paging backwards with a
        // forward animation looks like the library jumped somewhere else.
        let from = showing.flatMap { context.coordinator.index(of: $0) } ?? 0
        let to = context.coordinator.index(of: target) ?? 0
        controller.setViewControllers(
            [target], direction: to >= from ? .forward : .reverse, animated: true
        )
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource,
                             UIPageViewControllerDelegate {
        var parent: PagerView
        /// Built once per item and kept, so paging back to a photo doesn't
        /// re-download its preview.
        private var hosted: [UUID: UIHostingController<Page>] = [:]

        /// True from the moment a swipe starts moving a page until it lands or
        /// springs back. `updateUIViewController` must keep its hands off the
        /// pager for that whole window.
        private(set) var isTransitioning = false

        init(_ parent: PagerView) {
            self.parent = parent
        }

        /// Gives horizontal drags to the pager, and leaves everything else alone.
        ///
        /// Paging backwards was broken and this is why: the zoom navigation
        /// transition installs an interactive dismiss that takes a rightward
        /// drag before the pager's scroll view ever sees it. The data source was
        /// never even asked for the previous page — swiping right from a video
        /// popped the whole viewer back to the grid.
        ///
        /// Rather than switching either gesture off, the dismiss ones are made
        /// to *wait* for the pager's pan to fail. A horizontal drag is one the
        /// pan recognizes, so it pages; a vertical drag is one it fails, so the
        /// dismiss runs. That is Photos' split exactly — sideways moves between
        /// photos, downwards puts them away — and it keeps the zoom animation,
        /// which is the whole reason the transition is there.
        func claimHorizontalDrags(in controller: UIPageViewController) {
            guard let pan = controller.view.subviews
                .compactMap({ $0 as? UIScrollView })
                .first?.panGestureRecognizer
            else { return }

            // Ancestors only. The pager's own recognizers must not be told to
            // wait for themselves, and nothing below this screen is ours to
            // reorder.
            var ancestor = controller.view.superview
            while let view = ancestor {
                for recognizer in view.gestureRecognizers ?? [] where recognizer !== pan {
                    recognizer.require(toFail: pan)
                }
                ancestor = view.superview
            }
            controller.navigationController?
                .interactivePopGestureRecognizer?.require(toFail: pan)
        }

        func controller(for id: UUID) -> UIHostingController<Page>? {
            guard let item = parent.items.first(where: { $0.id == id }) else { return nil }
            if let existing = hosted[id] { return existing }
            let created = UIHostingController(rootView: parent.page(item))
            created.view.backgroundColor = .black
            // The viewer runs edge to edge under floating chrome.
            created.safeAreaRegions = []
            hosted[id] = created
            return created
        }

        func index(of controller: UIViewController) -> Int? {
            guard let id = hosted.first(where: { $0.value === controller })?.key else { return nil }
            return parent.items.firstIndex { $0.id == id }
        }

        // MARK: - Data source
        //
        // These are what build the neighbours, and they run as soon as a page
        // settles rather than when a swipe starts — which is why a video can be
        // buffering before anyone asks for it.

        func pageViewController(
            _ controller: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let index = index(of: viewController), index > 0 else { return nil }
            return self.controller(for: parent.items[index - 1].id)
        }

        func pageViewController(
            _ controller: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let index = index(of: viewController),
                  index + 1 < parent.items.count else { return nil }
            return self.controller(for: parent.items[index + 1].id)
        }

        // MARK: - Delegate

        func pageViewController(
            _ controller: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            isTransitioning = true
        }

        func pageViewController(
            _ controller: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            isTransitioning = false
            // Only when the swipe actually landed. A drag that springs back
            // must not renumber the viewer.
            guard completed, let showing = controller.viewControllers?.first,
                  let index = index(of: showing) else { return }
            parent.focus.currentID = parent.items[index].id
        }
    }
}
#endif
