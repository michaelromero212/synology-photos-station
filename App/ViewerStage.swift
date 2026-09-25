#if os(iOS)
import FrameStationAPI
import SwiftUI
import UIKit

/// The photo viewer, shown over the grid rather than pushed in place of it —
/// the way Photos does it.
///
/// The viewer used to be a navigation push with the system's zoom transition,
/// and the system's zoom can't do what Photos does:
///
/// - Dragging a photo down shrank the whole viewer — black background,
///   buttons and all — as a rounded card. Photos moves the photo alone, and
///   the black fades away behind it to show the grid.
/// - A pushed screen takes the one underneath out of the window. While a photo
///   was open the grid wasn't there to be scrolled or asked where a tile was,
///   and after a few swipes the photo zoomed back into the tile you had first
///   tapped, or into the top corner of the screen.
/// - Closing it with a swipe down never reached SwiftUI's navigation state,
///   which went on believing the photo was open — and the next tap did
///   nothing at all.
///
/// Here the grid never leaves the screen. The viewer is a layer over it, and
/// both flights are drawn by hand: a photo grows out of its tile to fill the
/// screen, and on the way back shrinks from wherever the drag has left it into
/// its own tile — the tile of the photo you ended on, brought on screen first
/// if the grid has to move to show it. The black is a separate layer, which is
/// what lets a drag fade it and uncover the grid.
///
/// The library grid on iPhone and iPad. Albums, collections and search still
/// push their viewer.
@Observable
@MainActor
final class ViewerStage {
    /// The photo in flight between its tile and the screen, in window
    /// coordinates.
    struct Flight: Identifiable {
        let id = UUID()
        let image: UIImage
        var frame: CGRect
        let target: CGRect
        let isClosing: Bool
    }

    /// What is open. Nil when nothing is.
    private(set) var opened: OpenedPhoto?
    /// The photo whose tile is out of the grid: hidden there while the photo
    /// is open, so that it has an empty place to go back into. Follows the
    /// viewer from photo to photo.
    private(set) var liftedID: UUID?
    private(set) var flight: Flight?
    /// Whether the viewer itself is drawn. A flight stands in for it on the way
    /// in and on the way out.
    private(set) var showsViewer = false
    /// How much of the black is there: 1 over the whole screen, 0 showing the
    /// grid.
    private(set) var backdrop: Double = 0
    /// Where a drag down has taken the photo, and how far it has shrunk it.
    private(set) var dragOffset: CGSize = .zero
    private(set) var dragScale: CGFloat = 1
    private(set) var isDragging = false
    private(set) var isClosing = false

    /// Where a photo's tile is on screen, in window coordinates, bringing it on
    /// screen first if it isn't. Supplied by the grid when it opens a photo.
    @ObservationIgnored var tileFrame: (TimelineItem) -> CGRect? = { _ in nil }
    /// The screen the viewer fills, in window coordinates. Kept by
    /// `ViewerStageView` from its own geometry.
    @ObservationIgnored var screen: CGRect = .zero

    /// Quick, with no bounce to speak of — a photo settling, not a ball landing.
    private static let openSpring = Animation.spring(response: 0.34, dampingFraction: 0.92)
    private static let closeSpring = Animation.spring(response: 0.32, dampingFraction: 0.9)
    /// How far down a drag has to travel to take all the black away.
    private static let dragRange: CGFloat = 320

    var isPresented: Bool { opened != nil }

    // MARK: - Opening

    /// Opens a photo, growing it out of its tile when there is a picture of it
    /// to grow — the tile's own thumbnail — and fading it in when there isn't.
    func present(_ photo: OpenedPhoto, from tile: CGRect?, image: UIImage?) {
        opened = photo
        liftedID = photo.id
        isClosing = false
        isDragging = false
        dragOffset = .zero
        dragScale = 1
        guard let tile, let image, screen.width > 0 else {
            flight = nil
            showsViewer = true
            backdrop = 0
            withAnimation(.easeOut(duration: 0.2)) { backdrop = 1 }
            return
        }
        showsViewer = false
        backdrop = 0
        flight = Flight(
            image: image, frame: tile,
            target: fitted(aspect: Self.shape(of: image, else: photo.item.aspectRatio)),
            isClosing: false
        )
    }

    /// Starts the flight just put up. Called by the flight's view as it
    /// appears, so its first frame is drawn where it starts before it moves.
    func launch() {
        guard let flight else { return }
        let id = flight.id
        withAnimation(flight.isClosing ? Self.closeSpring : Self.openSpring) {
            self.flight?.frame = flight.target
            backdrop = flight.isClosing ? 0 : 1
        } completion: { [weak self] in
            guard let self, self.flight?.id == id else { return }
            if flight.isClosing {
                self.finish()
            } else {
                self.showsViewer = true
                self.flight = nil
            }
        }
    }

    /// Moves the empty place in the grid to the photo now on screen.
    func lift(_ id: UUID) {
        guard opened != nil, !isClosing else { return }
        liftedID = id
    }

    // MARK: - Dragging

    /// The photo follows the finger and shrinks as it goes down, and the black
    /// thins until the grid shows through — Photos' drag, frame for frame.
    func dragChanged(_ translation: CGSize) {
        guard opened != nil, !isClosing else { return }
        isDragging = true
        let progress = min(max(translation.height, 0) / Self.dragRange, 1)
        dragOffset = translation
        dragScale = 1 - 0.32 * progress
        backdrop = 1 - progress
    }

    /// Whether the drag has gone far enough — or been flicked hard enough — to
    /// close. When it hasn't, the photo springs back and the black returns.
    func dragEnded(_ translation: CGSize, velocity: CGSize) -> Bool {
        isDragging = false
        if translation.height > 90 || velocity.height > 650 { return true }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
            dragOffset = .zero
            dragScale = 1
            backdrop = 1
        }
        return false
    }

    // MARK: - Closing

    /// Puts the photo on screen back into its tile, from wherever it is now —
    /// full screen, or part way down a drag.
    func close(current item: TimelineItem, image: UIImage?) {
        guard opened != nil, !isClosing else { return }
        isClosing = true
        let start = displayedFrame(aspect: Self.shape(of: image, else: item.aspectRatio))
        // Asked for before anything moves: this is what scrolls the grid to
        // the tile, if it has to, while the viewer still covers it.
        let target = tileFrame(item)
        liftedID = item.id
        showsViewer = false
        isDragging = false
        dragOffset = .zero
        dragScale = 1
        guard let image, let target else {
            // No tile to go back to — or nothing to show flying there. Fade.
            flight = nil
            withAnimation(.easeOut(duration: 0.22)) {
                backdrop = 0
            } completion: { [weak self] in
                self?.finish()
            }
            return
        }
        flight = Flight(image: image, frame: start, target: target, isClosing: true)
    }

    private func finish() {
        opened = nil
        flight = nil
        liftedID = nil
        showsViewer = false
        isClosing = false
        backdrop = 0
    }

    // MARK: - Geometry

    /// A photo's shape, width over height, as the viewer will draw it: read
    /// off the picture itself, which the NAS renders upright, rather than the
    /// library's record of the photo's dimensions.
    ///
    /// The record can be a quarter turn out. A portrait iPhone photo is stored
    /// sideways with an instruction to turn it, and when the phone's own
    /// upright dimensions were recorded alongside that instruction, the
    /// record said landscape for a photo that shows portrait. Flying to that
    /// shape cropped the photo into a wide band on the way open, before the
    /// viewer showed it the right way up — every portrait photo, every time.
    /// The record is the fallback for when there is no picture to go by.
    private static func shape(of image: UIImage?, else recorded: Double) -> Double {
        guard let size = image?.size, size.width > 0, size.height > 0 else { return recorded }
        return Double(size.width / size.height)
    }

    /// Where a photo of this shape sits when it fills the screen: fitted, and
    /// centered, the way the viewer draws it.
    private func fitted(aspect: Double) -> CGRect {
        guard screen.width > 0, screen.height > 0 else { return screen }
        let ratio = aspect > 0 ? CGFloat(aspect) : 1
        var size = CGSize(width: screen.width, height: screen.width / ratio)
        if size.height > screen.height {
            size = CGSize(width: screen.height * ratio, height: screen.height)
        }
        return CGRect(
            x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
            width: size.width, height: size.height
        )
    }

    /// Where the photo is now: its fitted frame, as a drag has moved and
    /// shrunk it. Matches `scaleEffect` about the center, then `offset`.
    private func displayedFrame(aspect: Double) -> CGRect {
        let base = fitted(aspect: aspect)
        let scale = dragScale
        let width = base.width * scale
        let height = base.height * scale
        return CGRect(
            x: screen.midX + (base.minX - screen.midX) * scale + dragOffset.width,
            y: screen.midY + (base.minY - screen.midY) * scale + dragOffset.height,
            width: width, height: height
        )
    }
}

/// The layer the viewer lives in, over the grid: the black, the viewer, and a
/// photo in flight between the two.
struct ViewerStageView<Viewer: View>: View {
    let stage: ViewerStage
    @ViewBuilder let viewer: (OpenedPhoto) -> Viewer

    var body: some View {
        ZStack {
            // The black and the photo in flight run to every edge of the
            // screen; the viewer between them keeps the safe area, so its
            // buttons clear the clock and the home indicator the way a pushed
            // screen's did. It runs its own photo edge to edge.
            //
            // The screen is measured here, and nothing is drawn in here. What
            // a GeometryReader holds is rebuilt during layout, outside the
            // transaction that changed it — so a flight drawn inside one
            // jumped straight to where it was going, SwiftUI counted the
            // flight finished, and the viewer cut in over a photo that had
            // barely left its tile.
            GeometryReader { geometry in
                Color.clear
                    .onChange(of: geometry.frame(in: .global), initial: true) { _, new in
                        stage.screen = new
                    }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if stage.opened != nil {
                Color.black
                    .opacity(stage.backdrop)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            if let opened = stage.opened {
                viewer(opened)
                    .opacity(stage.showsViewer ? 1 : 0)
                    .allowsHitTesting(stage.showsViewer)
            }

            if let flight = stage.flight {
                FlightView(flight: flight, origin: stage.screen.origin) {
                    stage.launch()
                }
                .id(flight.id)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(stage.isPresented)
    }
}

/// The photo in flight: cropped to whatever shape its frame has reached, so it
/// turns from the full picture into the square of its tile as it lands.
private struct FlightView: View {
    let flight: ViewerStage.Flight
    /// The top left of the screen the flight is drawn across, in window
    /// coordinates — where the flight's own frames are measured from.
    let origin: CGPoint
    let onAppear: () -> Void

    var body: some View {
        Image(uiImage: flight.image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: flight.frame.width, height: flight.frame.height)
            .clipped()
            .position(x: flight.frame.midX - origin.x, y: flight.frame.midY - origin.y)
            .allowsHitTesting(false)
            .onAppear(perform: onAppear)
    }
}
#endif
