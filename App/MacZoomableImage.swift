#if os(macOS)
import AppKit
import SwiftUI

/// A photo you can pinch, double-click and scroll around, on a Mac.
///
/// An `NSScrollView` with magnification, for the reason the phone's
/// `ZoomableImage` is a `UIScrollView`: pinching around the pointer,
/// momentum while panning, rubber-banding at the edges and the trackpad's
/// two-finger double-tap are AppKit's own, and each would come out a little
/// wrong rebuilt from SwiftUI gestures.
///
/// At rest it gives every scroll to the viewer, so two fingers sideways still
/// moves to the next photo. Zoomed, the scrolls are its own, and pan.
struct MacZoomableImage: NSViewRepresentable {
    let image: NSImage
    /// False while this page is off-screen, which drops it back to fit, as
    /// Photos does: coming back to a photo left at 4× is disorienting.
    var isCurrent: Bool
    /// How the viewer's zoom keys reach the photo on screen.
    let zoom: MacPhotoZoom
    /// Mirrored out so the viewer can stop paging while the photo is zoomed.
    var onZoomChange: (Bool) -> Void = { _ in }
    /// Asked once the photo is zoomed past the detail `image` holds, so the
    /// original can take its place.
    var onWantsDetail: () -> Void = {}

    func makeNSView(context: Context) -> PhotoMagnifyView {
        let view = PhotoMagnifyView()
        view.show(image)
        view.onZoomChange = onZoomChange
        view.onWantsDetail = onWantsDetail
        return view
    }

    func updateNSView(_ view: PhotoMagnifyView, context: Context) {
        view.onZoomChange = onZoomChange
        view.onWantsDetail = onWantsDetail
        // The preview over the 512, or the original over the preview: same
        // picture, more of it. Shown where it stands, keeping the zoom.
        if view.image !== image { view.show(image) }
        if isCurrent {
            zoom.current = view
        } else {
            if zoom.current === view { zoom.current = nil }
            if view.isZoomed { view.fit(animated: false) }
        }
    }

    static func dismantleNSView(_ view: PhotoMagnifyView, coordinator: ()) {
        view.onZoomChange = { _ in }
        view.onWantsDetail = {}
    }
}

/// The viewer's zoom keys, sent to whichever photo is on screen.
@MainActor
final class MacPhotoZoom {
    weak var current: PhotoMagnifyView?

    func zoomIn() { current?.zoom(by: 1.5) }
    func zoomOut() { current?.zoom(by: 1 / 1.5) }
    func fit() { current?.fit(animated: true) }
}

/// The scroll view behind `MacZoomableImage`.
final class PhotoMagnifyView: NSScrollView {
    private let photo = PhotoLayerView()
    var onZoomChange: (Bool) -> Void = { _ in }
    var onWantsDetail: () -> Void = {}
    private(set) var image: NSImage?
    private(set) var isZoomed = false
    private var laidOutSize: CGSize = .zero
    private var askedForDetail = false

    /// How far a double-click zooms: the phone's double-tap, far enough to be
    /// worth the click and near enough that you can still tell where you are.
    static let doubleClickMagnification: CGFloat = 3

    init() {
        super.init(frame: .zero)
        contentView = CenteringClipView()
        drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        scrollerStyle = .overlay
        allowsMagnification = true
        minMagnification = 1
        maxMagnification = 8
        documentView = photo
        photo.onDoubleClick = { [weak self] point in self?.toggleZoom(at: point) }
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged),
            name: NSView.boundsDidChangeNotification, object: contentView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    func show(_ new: NSImage) {
        let sameShape = image.map { abs(aspect($0) - aspect(new)) < 0.001 } ?? false
        image = new
        photo.layer?.contents = new.cgImage(forProposedRect: nil, context: nil, hints: nil) ?? new
        askedForDetail = false
        if !sameShape || !isZoomed { resetLayout() } else { checkDetail() }
    }

    override func layout() {
        super.layout()
        // Only on a real change of size: the window resized, or the first pass
        // with real bounds. Not on every frame of a pinch.
        if bounds.size != laidOutSize {
            laidOutSize = bounds.size
            resetLayout()
        }
    }

    /// Fits the photo to the view, at rest.
    private func resetLayout() {
        guard let image, image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        magnification = 1
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        photo.frame = CGRect(
            origin: .zero,
            size: CGSize(width: image.size.width * scale, height: image.size.height * scale)
        )
        syncZoomed()
    }

    // MARK: Zooming

    /// Where an animated zoom is headed, while it's on its way. A second press
    /// of ⌘− during the first one's animation steps on from where the first
    /// is going, not from where it has got to, so two quick presses are two
    /// steps.
    private var zoomTarget: CGFloat?

    func fit(animated: Bool) {
        if animated {
            animate(to: minMagnification, around: nil, duration: 0.22)
        } else {
            zoomTarget = nil
            magnification = minMagnification
            syncZoomed()
        }
    }

    /// The zoom keys: around the middle of what's showing.
    func zoom(by factor: CGFloat) {
        let base = zoomTarget ?? magnification
        let target = min(max(base * factor, minMagnification), maxMagnification)
        animate(to: target, around: CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY),
                duration: 0.18)
    }

    /// A double-click: in, keeping the point clicked under the pointer as a
    /// pinch does, or back out to fit.
    private func toggleZoom(at point: CGPoint) {
        if isZoomed || (zoomTarget ?? minMagnification) > minMagnification {
            fit(animated: true)
        } else {
            animate(to: Self.doubleClickMagnification, around: point, duration: 0.22)
        }
    }

    private func animate(to target: CGFloat, around point: CGPoint?, duration: TimeInterval) {
        zoomTarget = target
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            if let point {
                animator().setMagnification(target, centeredAt: point)
            } else {
                animator().magnification = target
            }
        } completionHandler: { [weak self] in
            guard let self else { return }
            if self.zoomTarget == target { self.zoomTarget = nil }
            self.syncZoomed()
        }
        syncZoomed()
    }

    /// The clip view's bounds change on every step of a pinch and every
    /// scroll, so this is where a zoom is noticed, however it was made.
    @objc private func boundsChanged() { syncZoomed() }

    private func syncZoomed() {
        let zoomed = magnification > minMagnification + 0.01
        if zoomed != isZoomed {
            isZoomed = zoomed
            photo.isPannable = zoomed
            // Told on the next turn of the run loop: this can be reached while
            // SwiftUI is updating the view, which mustn't change its state.
            let report = onZoomChange
            DispatchQueue.main.async { report(zoomed) }
        }
        checkDetail()
    }

    /// Whether the photo is now shown bigger than the picture holds, so the
    /// original is worth fetching. Once per picture.
    private func checkDetail() {
        guard isZoomed, !askedForDetail, let image,
              let pixels = image.representations.map(\.pixelsWide).max(), pixels > 0
        else { return }
        let backing = window?.backingScaleFactor ?? 2
        let shown = photo.frame.width * magnification * backing
        if shown > CGFloat(pixels) * 1.05 {
            askedForDetail = true
            onWantsDetail()
        }
    }

    // MARK: Scrolling

    /// At rest, every scroll goes on to the viewer, which pages on it. Kept
    /// here, it would rubber-band a photo that has nowhere to go and the
    /// swipe to the next one would never arrive.
    override func scrollWheel(with event: NSEvent) {
        if isZoomed {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }

    private func aspect(_ image: NSImage) -> CGFloat {
        image.size.height > 0 ? image.size.width / image.size.height : 1
    }
}

/// The photograph itself: a layer the GPU scales, so a pinch never redraws a
/// forty-megapixel bitmap on the processor. Dragged, it pans the zoomed photo.
final class PhotoLayerView: NSView {
    var onDoubleClick: (CGPoint) -> Void = { _ in }
    var isPannable = false {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.minificationFilter = .trilinear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func resetCursorRects() {
        if isPannable { addCursorRect(visibleRect, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick(convert(event.locationInWindow, from: nil))
        } else if isPannable {
            NSCursor.closedHand.push()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPannable, let clip = superview as? NSClipView else {
            super.mouseDragged(with: event)
            return
        }
        // The photo follows the hand: the view the other way, scaled out of
        // the magnification so a centimeter of drag is a centimeter of photo.
        let scale = clip.bounds.width > 0 ? clip.frame.width / clip.bounds.width : 1
        var origin = clip.bounds.origin
        origin.x -= event.deltaX / scale
        origin.y += event.deltaY / scale
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        (clip.superview as? NSScrollView)?.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        if isPannable { NSCursor.pop() }
        super.mouseUp(with: event)
    }
}

/// Keeps a photo smaller than the window in its middle rather than in the
/// bottom-left corner, where AppKit leaves a document that doesn't fill it.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let frame = document.frame
        if rect.width > frame.width { rect.origin.x = (frame.width - rect.width) / 2 + frame.minX }
        if rect.height > frame.height { rect.origin.y = (frame.height - rect.height) / 2 + frame.minY }
        return rect
    }
}
#endif
