#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// A photo you can pinch, pan and double-tap, sized to the whole screen.
///
/// A `UIScrollView` rather than SwiftUI gestures, and not for want of trying.
/// Three behaviors are effectively free here and are all fiddly to rebuild:
/// pinching below the resting size rubber-bands and springs back
/// (`bouncesZoom`); a pan while zoomed decelerates instead of stopping dead;
/// and — the one that matters most in a pager — UIKit already knows how to
/// arbitrate a zoomed scroll view against the paging scroll view above it, so
/// panning to the edge of a zoomed photo hands the swipe over to the next
/// photo rather than fighting it.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    /// False while this page is off-screen, which is the cue to drop back to
    /// the resting zoom — coming back to a photo you left at 4× is disorienting.
    var isCurrent: Bool
    /// Mirrors the scroll view's zoom out to the viewer, which uses it to know
    /// whether a drag belongs to the photo or to the pager.
    var onZoomChange: (Bool) -> Void = { _ in }
    /// One tap toggles the chrome. The scroll view swallows touches, so the
    /// tap has to be recognized in here rather than by a SwiftUI gesture
    /// wrapped around it.
    var onSingleTap: () -> Void = {}

    func makeUIView(context: Context) -> PhotoScrollView {
        let view = PhotoScrollView()
        view.imageView.image = image
        view.onSingleTap = onSingleTap
        view.onZoomChange = onZoomChange
        return view
    }

    func updateUIView(_ view: PhotoScrollView, context: Context) {
        view.onSingleTap = onSingleTap
        view.onZoomChange = onZoomChange

        // A page recycled onto a different photo: new image, fresh layout. The
        // preview also lands here, replacing the 512 thumbnail mid-view, and
        // that must not throw away a zoom the user is in the middle of.
        if view.imageView.image !== image {
            let sameAspect = view.imageView.image
                .map { abs(aspect($0) - aspect(image)) < 0.001 } ?? false
            view.imageView.image = image
            if !sameAspect || view.zoomScale == view.minimumZoomScale {
                view.resetLayout()
            }
        }

        if !isCurrent, view.zoomScale != view.minimumZoomScale {
            view.setZoomScale(view.minimumZoomScale, animated: false)
            view.syncScrollEnabled()
        }
    }

    private func aspect(_ image: UIImage) -> CGFloat {
        image.size.height > 0 ? image.size.width / image.size.height : 1
    }
}

/// The scroll view behind `ZoomableImage`.
///
/// Its own class rather than a coordinator holding a stock `UIScrollView`
/// because centring a zoomed image is a `layoutSubviews` job — the content has
/// to be re-inset every frame of a pinch, and there is no delegate callback
/// that fires often enough to do it from outside.
final class PhotoScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onSingleTap: () -> Void = {}
    var onZoomChange: (Bool) -> Void = { _ in }

    /// How far a double-tap zooms. Photos uses roughly this; far enough to be
    /// worth the tap, near enough that you can still tell where you are.
    private let doubleTapScale: CGFloat = 3
    private var laidOutSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)

        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        // The spring-back the brief asks for: pinching in past the resting size
        // stretches and snaps home instead of stopping at a hard limit.
        bouncesZoom = true
        decelerationRate = .fast
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        // Off at rest so the pager owns the horizontal swipe. It comes on the
        // moment the photo is zoomed, and UIKit then gives the inner pan
        // priority until it runs out of content to show.
        isScrollEnabled = false

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(
            target: self, action: #selector(handleDoubleTap)
        )
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(
            target: self, action: #selector(handleSingleTap)
        )
        singleTap.numberOfTapsRequired = 1
        // Without this every double-tap also fires a single tap, so zooming in
        // would hide the chrome on the way.
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Only on a real size change — rotation, or the first pass once the
        // scroll view actually has bounds. Re-laying out on every frame of a
        // pinch would fight the gesture.
        if bounds.size != laidOutSize {
            laidOutSize = bounds.size
            resetLayout()
        }
        centerImage()
    }

    /// Fits the image to the view and parks the zoom at rest.
    func resetLayout() {
        guard let image = imageView.image,
              image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0
        else { return }

        zoomScale = 1
        // Aspect-fit against the *full* bounds, which the viewer hands us
        // edge to edge — that's what lets a screen-shaped crop fill the
        // display instead of sitting in a letterbox.
        let fitted = AVMakeRect(aspectRatio: image.size, insideRect: bounds).size
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        centerImage()
        syncScrollEnabled()
    }

    /// Keeps the image in the middle while it's smaller than the viewport.
    ///
    /// Insets rather than a frame offset: an offset gets clobbered by the
    /// scroll view on the next zoom step, and the image drifts off-center as
    /// you pinch.
    private func centerImage() {
        let extraWidth = max(0, (bounds.width - contentSize.width) / 2)
        let extraHeight = max(0, (bounds.height - contentSize.height) / 2)
        let inset = UIEdgeInsets(
            top: extraHeight, left: extraWidth, bottom: extraHeight, right: extraWidth
        )
        if contentInset != inset { contentInset = inset }
    }

    /// The pan gesture belongs to whoever has somewhere to pan.
    func syncScrollEnabled() {
        let zoomed = zoomScale > minimumZoomScale + 0.01
        if isScrollEnabled != zoomed {
            isScrollEnabled = zoomed
            onZoomChange(zoomed)
        }
    }

    @objc private func handleSingleTap() {
        onSingleTap()
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            // Zoom around the point that was tapped, not the middle: tapping a
            // face and landing on someone's elbow is the whole complaint about
            // double-tap zoom done badly.
            let point = recognizer.location(in: imageView)
            let size = CGSize(
                width: bounds.width / doubleTapScale,
                height: bounds.height / doubleTapScale
            )
            zoom(
                to: CGRect(
                    x: point.x - size.width / 2, y: point.y - size.height / 2,
                    width: size.width, height: size.height
                ),
                animated: true
            )
        }
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        syncScrollEnabled()
    }

    func scrollViewDidEndZooming(
        _ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat
    ) {
        syncScrollEnabled()
    }
}
#endif
