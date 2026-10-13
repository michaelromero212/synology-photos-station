#if os(iOS)
import FrameStationAPI
import QuartzCore
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
/// The flights and the black are Core Animation's, not SwiftUI's. A SwiftUI
/// animation is moved along by the main thread a frame at a time, so anything
/// else the main thread does stops it where it is — and the moment a photo
/// opens is the moment its viewer is built. Measured, the first photo opened
/// after launch sat on its tile for a fifth of a second while that happened,
/// then appeared already half grown. A Core Animation flight runs in the
/// render server from its first frame to its last, whatever the app is doing,
/// so the viewer is built underneath it while it flies. See `present`.
///
/// The library grid on iPhone and iPad. Albums, collections and search still
/// push their viewer.
@Observable
@MainActor
final class ViewerStage {
    /// What is open, which the viewer is built from. Nil when nothing is —
    /// and for the first frame of an opening, which is the flight's alone.
    /// See `present`.
    private(set) var opened: OpenedPhoto?
    /// Whether a photo is open or on its way in or out: from the tap until it
    /// is back in its tile.
    private(set) var isPresented = false
    /// The photo whose tile is out of the grid: hidden there while the photo
    /// is open, so that it has an empty place to go back into. Follows the
    /// viewer from photo to photo.
    private(set) var liftedID: UUID?
    /// Whether the viewer itself is drawn. A flight stands in for it on the way
    /// in and on the way out.
    private(set) var showsViewer = false
    /// Where a drag down has taken the photo, and how far it has shrunk it.
    private(set) var dragOffset: CGSize = .zero
    private(set) var dragScale: CGFloat = 1
    private(set) var isDragging = false
    private(set) var isClosing = false

    /// Where a photo's tile is on screen, in window coordinates, bringing it on
    /// screen first if it isn't. Supplied by the grid when it opens a photo.
    @ObservationIgnored var tileFrame: (TimelineItem) -> CGRect? = { _ in nil }
    /// Told as a photo starts back to the grid, so the grid can bring back
    /// what it hid for the viewer before the photo lands rather than after.
    @ObservationIgnored var willClose: () -> Void = {}

    /// The black, under the viewer, and the layer photos fly in, over it:
    /// UIKit views put up by `ViewerStageView` and moved from here. Held
    /// weakly, as SwiftUI owns them.
    @ObservationIgnored fileprivate weak var backdrop: UIView?
    @ObservationIgnored fileprivate weak var flightLayer: UIView?
    /// The photo in flight, while there is one.
    @ObservationIgnored private var flight: UIImageView?

    /// Quick, with no bounce to speak of — a photo settling, not a ball
    /// landing. The same springs SwiftUI's `.spring(response:dampingFraction:)`
    /// ran here before, written the way all three frameworks now share.
    private static let openSpring = Spring(duration: 0.34, bounce: 0.08)
    private static let closeSpring = Spring(duration: 0.32, bounce: 0.1)
    /// A drag let go of too soon, going back where it came from.
    private static let returnSpring = Spring(duration: 0.3, bounce: 0.16)
    /// How far down a drag has to travel to take all the black away.
    private static let dragRange: CGFloat = 320

    // MARK: - Opening

    /// Opens a photo, growing it out of its tile when there is a picture of it
    /// to grow — the tile's own thumbnail — and fading it in when there isn't.
    ///
    /// The viewer is built a frame later, once the flight is on the screen.
    /// Built now, the flight's first frame would wait for it, and that wait is
    /// most of a fifth of a second the first time after launch. Built next
    /// frame, it costs the flight nothing: Core Animation is already moving
    /// it, and the viewer is ready long before it lands.
    func present(_ photo: OpenedPhoto, from tile: CGRect?, image: UIImage?) {
        guard !isPresented else { return }
        isPresented = true
        liftedID = photo.id
        isClosing = false
        isDragging = false
        dragOffset = .zero
        dragScale = 1
        showsViewer = false
        NextFrame.run { [weak self] in
            guard let self, self.isPresented, !self.isClosing else { return }
            self.opened = photo
        }
        guard let tile, let image, !screen.isEmpty else {
            showsViewer = true
            fadeBackdrop(to: 1, duration: 0.2)
            return
        }
        let target = fitted(aspect: Self.shape(of: image, else: photo.item.aspectRatio))
        fly(image, from: tile, to: target, spring: Self.openSpring, backdrop: 1) { [weak self] landed in
            guard let self, self.isPresented, !self.isClosing else { return }
            self.showsViewer = true
            // Taken down a frame later, once the viewer is drawn in its place.
            NextFrame.run { [weak self] in self?.removeFlight(landed) }
        }
    }

    /// Moves the empty place in the grid to the photo now on screen.
    func lift(_ id: UUID) {
        guard isPresented, !isClosing else { return }
        liftedID = id
    }

    // MARK: - Dragging

    /// The photo follows the finger and shrinks as it goes down, and the black
    /// thins until the grid shows through — Photos' drag, frame for frame.
    ///
    /// Only the two values the photo is drawn with change here, and they are
    /// read by `StageFollowsDrag` alone, so a drag redraws the photo and
    /// nothing else. The black is set directly.
    func dragChanged(_ translation: CGSize) {
        guard isPresented, showsViewer, !isClosing else { return }
        isDragging = true
        let progress = min(max(translation.height, 0) / Self.dragRange, 1)
        dragOffset = translation
        dragScale = 1 - 0.32 * progress
        backdrop?.layer.removeAnimation(forKey: Self.backdropKey)
        backdrop?.alpha = 1 - progress
    }

    /// Whether the drag has gone far enough — or been flicked hard enough — to
    /// close. When it hasn't, the photo springs back and the black returns.
    ///
    /// A drag pulled well down and then thrown back up is a change of mind,
    /// as it is in Photos: it stays open.
    func dragEnded(_ translation: CGSize, velocity: CGSize) -> Bool {
        guard isPresented, showsViewer, !isClosing else { return false }
        let flicked = velocity.height > 650
        let pulled = translation.height > 90 && velocity.height > -300
        if flicked || pulled { return true }
        isDragging = false
        withAnimation(.spring(Self.returnSpring)) {
            dragOffset = .zero
            dragScale = 1
        }
        animateBackdrop(to: 1, spring: Self.returnSpring)
        return false
    }

    // MARK: - Closing

    /// Puts the photo on screen back into its tile, from wherever it is now —
    /// full screen, or part way down a drag.
    ///
    /// `velocity` is the drag's as it was let go, in points per second. The
    /// photo leaves at that speed, so a flick carries on the way it was
    /// thrown until the spring turns it home. It used to stop dead at the
    /// release and set off again from rest — a hitch in the middle of what
    /// should read as one throw.
    func close(current item: TimelineItem, image: UIImage?, velocity: CGSize = .zero) {
        guard isPresented, !isClosing else { return }
        isClosing = true
        willClose()
        // A viewer turned with the phone shows its photo turned. The flight
        // starts the same way and rights itself on the way to the tile.
        let turn = CGFloat(MediaTilt.shared.angle * .pi / 180)
        let start = displayedFrame(aspect: Self.shape(of: image, else: item.aspectRatio), turn: turn)
        // Asked for before anything moves: this is what scrolls the grid to
        // the tile, if it has to, while the viewer still covers it.
        let target = tileFrame(item)
        liftedID = item.id
        isDragging = false
        guard let image, !screen.isEmpty else {
            // Nothing to fly. The viewer fades with the black.
            withAnimation(.easeOut(duration: 0.22)) { showsViewer = false }
            fadeBackdrop(to: 0, duration: 0.22) { [weak self] in self?.finish() }
            return
        }
        showsViewer = false
        dragOffset = .zero
        dragScale = 1
        if let target {
            let push = Self.rotated(velocity, by: turn)
            fly(
                image, from: start, to: target, velocity: push, turn: (turn, 0),
                spring: Self.closeSpring, backdrop: 0
            ) { [weak self] _ in self?.finish() }
            // The tile comes back under the photo as it comes in to land, a
            // few points out. Left empty until the photo was all the way down,
            // the slow last points of a photo arriving from below — after a
            // flick, every time — showed a strip of the empty place, black
            // along the tile's top edge, for the last several frames.
            //
            // At once rather than faded in: a change animated inside a grid
            // cell never reached the screen, measured frame by frame, and the
            // photo covers all but those few points of the tile anyway.
            let nearly = Self.arrival(
                from: start, to: target, velocity: push, spring: Self.closeSpring, within: 12
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + nearly) { [weak self] in
                guard let self, self.isClosing, self.liftedID == item.id else { return }
                self.liftedID = nil
            }
        } else {
            // No tile to go back to: a day the grid doesn't hold. The photo
            // shrinks a little where it is and fades with the black.
            fly(
                image, from: start, to: start.insetBy(dx: start.width / 10, dy: start.height / 10),
                turn: (turn, turn), fades: true,
                spring: Self.closeSpring, backdrop: 0
            ) { [weak self] _ in self?.finish() }
        }
    }

    private func finish() {
        let landed = flight
        opened = nil
        isPresented = false
        liftedID = nil
        showsViewer = false
        isClosing = false
        isDragging = false
        dragOffset = .zero
        dragScale = 1
        backdrop?.layer.removeAnimation(forKey: Self.backdropKey)
        backdrop?.alpha = 0
        // Taken down a frame later, once the tile is back underneath it.
        NextFrame.run { [weak self] in self?.removeFlight(landed) }
    }

    // MARK: - Flights

    private static let backdropKey = "stage.backdrop"

    /// Flies `image` from one frame to another, in window coordinates, and
    /// takes the black to `backdrop` alongside it. Calls `completion` with the
    /// flight once it has landed, still on screen — or straight away, with no
    /// flight, when there is no layer to fly it in, so that nothing is left
    /// waiting on a landing that will never come.
    ///
    /// `velocity` is where the finger was taking the photo, in points per
    /// second. `turn` is the angle it starts and ends at, for a photo shown
    /// turned with the phone — see `MediaTilt`.
    private func fly(
        _ image: UIImage, from start: CGRect, to end: CGRect,
        velocity: CGPoint = .zero, turn: (from: CGFloat, to: CGFloat) = (0, 0),
        fades: Bool = false, spring: Spring, backdrop target: CGFloat,
        completion: @escaping (UIImageView?) -> Void
    ) {
        guard let layer = flightLayer else {
            completion(nil)
            return
        }
        if let flight { removeFlight(flight) }
        let from = layer.convert(start, from: nil)
        let to = layer.convert(end, from: nil)

        let view = UIImageView(image: image)
        // Cropped to whatever shape it has reached, so it turns from the
        // whole picture into the square of its tile as it lands.
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        // Where it ends. The animations carry it there from where it starts,
        // and are on it before it is first drawn.
        view.bounds = CGRect(origin: .zero, size: to.size)
        view.center = CGPoint(x: to.midX, y: to.midY)
        view.transform = CGAffineTransform(rotationAngle: turn.to)
        if fades { view.alpha = 0 }
        layer.addSubview(view)
        flight = view

        CATransaction.begin()
        CATransaction.setCompletionBlock { completion(view) }
        let moves: [(String, CGFloat, CGFloat, CGFloat)] = [
            ("position.x", from.midX, to.midX, velocity.x),
            ("position.y", from.midY, to.midY, velocity.y),
            ("bounds.size.width", from.width, to.width, 0),
            ("bounds.size.height", from.height, to.height, 0),
        ]
        for (keyPath, start, end, speed) in moves {
            view.layer.add(
                Self.spring(keyPath, from: start, to: end, velocity: speed, spring),
                forKey: keyPath
            )
        }
        if turn.from != turn.to {
            view.layer.add(
                Self.spring("transform.rotation.z", from: turn.from, to: turn.to, spring, within: 0.002),
                forKey: "turn"
            )
        }
        if fades {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = spring.duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.layer.add(fade, forKey: "fade")
        }
        animateBackdrop(to: target, spring: spring)
        CATransaction.commit()
    }

    private func removeFlight(_ view: UIImageView?) {
        guard let view else { return }
        view.removeFromSuperview()
        if flight === view { flight = nil }
    }

    /// Takes the black to `target` with a spring the length of `spring`, from
    /// wherever it is now — including part way through another change.
    private func animateBackdrop(to target: CGFloat, spring: Spring) {
        guard let backdrop else { return }
        let from = CGFloat(backdrop.layer.presentation()?.opacity ?? Float(backdrop.alpha))
        backdrop.layer.removeAnimation(forKey: Self.backdropKey)
        backdrop.alpha = target
        guard abs(target - from) > 0.002 else { return }
        // No bounce: black can't go past none, and a spring that tried would
        // flicker on its way back from there.
        let calm = Spring(duration: spring.duration, bounce: 0)
        backdrop.layer.add(
            Self.spring("opacity", from: from, to: target, calm, within: 0.004),
            forKey: Self.backdropKey
        )
    }

    private func fadeBackdrop(to target: CGFloat, duration: Double, completion: (() -> Void)? = nil) {
        guard let backdrop else {
            completion?()
            return
        }
        let from = CGFloat(backdrop.layer.presentation()?.opacity ?? Float(backdrop.alpha))
        backdrop.layer.removeAnimation(forKey: Self.backdropKey)
        backdrop.alpha = target
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = target
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        backdrop.layer.add(fade, forKey: Self.backdropKey)
        CATransaction.commit()
    }

    /// One of Core Animation's springs, set to `spring` — the curve SwiftUI
    /// would draw for it — starting at `velocity` in the value's own units
    /// per second.
    ///
    /// It ends as it comes within `within` of where it's going for good — a
    /// third of a point by default, a pixel on a phone — rather than when
    /// it has stopped altogether. What's left is too small to see, and in a
    /// spring this damped it is two fifths of the running time: waiting for
    /// it kept the viewer from taking over, or a swipe from being answered,
    /// for a quarter of a second after the photo had visibly arrived.
    private static func spring(
        _ keyPath: String, from start: CGFloat, to end: CGFloat, velocity: CGFloat = 0,
        _ spring: Spring, within tolerance: CGFloat = 1.0 / 3
    ) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.fromValue = start
        animation.toValue = end
        animation.mass = spring.mass
        animation.stiffness = spring.stiffness
        animation.damping = spring.damping
        let distance = end - start
        guard abs(distance) > tolerance else {
            animation.duration = 0.01
            return animation
        }
        // Measured in whole journeys per second, toward where it's going.
        let relative = Double(velocity / distance)
        animation.initialVelocity = relative
        animation.duration = arrival(
            of: spring, velocity: relative, within: Double(tolerance / abs(distance))
        )
        return animation
    }

    /// When a flight from `start` to `end`, leaving at `velocity`, is within
    /// `tolerance` points of `end` in every part of its frame and stays there.
    private static func arrival(
        from start: CGRect, to end: CGRect, velocity: CGPoint, spring: Spring,
        within tolerance: CGFloat
    ) -> TimeInterval {
        let parts: [(from: CGFloat, to: CGFloat, speed: CGFloat)] = [
            (start.midX, end.midX, velocity.x),
            (start.midY, end.midY, velocity.y),
            (start.width, end.width, 0),
            (start.height, end.height, 0),
        ]
        return parts.map { part in
            let distance = part.to - part.from
            guard abs(distance) > tolerance else { return 0 }
            return arrival(
                of: spring, velocity: Double(part.speed / distance),
                within: Double(tolerance / abs(distance))
            )
        }.max() ?? 0
    }

    /// When a spring from 0 to 1 is inside `epsilon` of 1 and stays there.
    ///
    /// Found by walking back from SwiftUI's own settling estimate, which is
    /// a bound on the spring's envelope and so a long way after the spring
    /// itself has arrived: for the open, 0.58 seconds against 0.35.
    private static func arrival(
        of spring: Spring, velocity: Double, within epsilon: Double
    ) -> TimeInterval {
        let bound = spring.settlingDuration(
            target: 1.0, initialVelocity: velocity, epsilon: epsilon
        )
        let step = 1.0 / 240
        var time = bound
        while time > 0 {
            let value = spring.value(target: 1.0, initialVelocity: velocity, time: time)
            if abs(1 - value) > epsilon { return min(time + step, bound) }
            time -= step
        }
        return bound
    }

    // MARK: - Geometry

    /// The screen the viewer fills, in window coordinates: the flight layer's
    /// own frame, which runs to every edge.
    private var screen: CGRect {
        guard let flightLayer, flightLayer.window != nil else { return .zero }
        return flightLayer.convert(flightLayer.bounds, to: nil)
    }

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

    /// The size a photo of this shape is drawn at to fit `box`.
    private static func fittedSize(aspect: Double, in box: CGSize) -> CGSize {
        guard box.width > 0, box.height > 0 else { return box }
        let ratio = aspect > 0 ? CGFloat(aspect) : 1
        let size = CGSize(width: box.width, height: box.width / ratio)
        return size.height > box.height
            ? CGSize(width: box.height * ratio, height: box.height)
            : size
    }

    /// Where a photo of this shape sits when it fills the screen: fitted, and
    /// centered, the way the viewer draws it.
    private func fitted(aspect: Double) -> CGRect {
        let screen = screen
        let size = Self.fittedSize(aspect: aspect, in: screen.size)
        return CGRect(
            x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
            width: size.width, height: size.height
        )
    }

    /// Where the photo is now, before it is turned: fitted to the screen — to
    /// the screen on its side, when the viewer is turned with the phone — and
    /// moved and shrunk by a drag. Matches `scaleEffect` about the center,
    /// then `offset`, inside `videoTilt`'s turn, which is applied to the
    /// flight separately.
    private func displayedFrame(aspect: Double, turn: CGFloat) -> CGRect {
        let screen = screen
        let sideways = abs(sin(turn)) > 0.5
        let box = sideways ? CGSize(width: screen.height, height: screen.width) : screen.size
        let fitted = Self.fittedSize(aspect: aspect, in: box)
        let size = CGSize(width: fitted.width * dragScale, height: fitted.height * dragScale)
        let offset = Self.rotated(dragOffset, by: turn)
        return CGRect(
            x: screen.midX + offset.x - size.width / 2,
            y: screen.midY + offset.y - size.height / 2,
            width: size.width, height: size.height
        )
    }

    /// A drag's movement as the screen sees it. A turned viewer is dragged in
    /// its own turned coordinates.
    private static func rotated(_ vector: CGSize, by angle: CGFloat) -> CGPoint {
        CGPoint(
            x: vector.width * cos(angle) - vector.height * sin(angle),
            y: vector.width * sin(angle) + vector.height * cos(angle)
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
            // Both are UIKit views that `ViewerStage` moves itself, so nothing
            // here is read while a photo flies or follows a drag, and nothing
            // here is redrawn for it. See `ViewerStage`.
            StageCanvas(stage: stage, role: .backdrop)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if let opened = stage.opened {
                viewer(opened)
                    .modifier(StagedViewerVisibility(stage: stage))
            }

            StageCanvas(stage: stage, role: .flights)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            FlightShield(stage: stage)
        }
        .allowsHitTesting(stage.isPresented)
    }
}

/// The black, or the layer photos fly in — a plain UIKit view that registers
/// itself with the stage, which moves it.
private struct StageCanvas: UIViewRepresentable {
    enum Role { case backdrop, flights }

    let stage: ViewerStage
    let role: Role

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        switch role {
        case .backdrop:
            view.backgroundColor = .black
            view.alpha = 0
            stage.backdrop = view
        case .flights:
            view.backgroundColor = .clear
            stage.flightLayer = view
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}

/// The viewer, kept out of sight and out of reach while a flight stands in
/// for it. A modifier of its own so that the stage's body doesn't read this,
/// and showing the viewer doesn't rebuild it.
private struct StagedViewerVisibility: ViewModifier {
    let stage: ViewerStage

    func body(content: Content) -> some View {
        content
            .opacity(stage.showsViewer ? 1 : 0)
            .allowsHitTesting(stage.showsViewer)
    }
}

/// Takes the touches that land while a photo is on its way in or out, so a
/// tap on the grid underneath can't open a second one, nor a flick scroll a
/// tile out from under the photo flying back into it.
private struct FlightShield: View {
    let stage: ViewerStage

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .ignoresSafeArea()
            .allowsHitTesting(stage.isPresented && !stage.showsViewer)
    }
}

/// A tile out of the grid while its photo is open. See `ViewerStage.liftedID`.
///
/// A modifier of its own so that moving the empty place redraws this alone.
/// Read where the tile is built, every move rebuilt every tile on screen.
struct LiftedFromGrid: ViewModifier {
    let stage: ViewerStage
    let id: UUID

    func body(content: Content) -> some View {
        content.opacity(stage.liftedID == id ? 0 : 1)
    }
}

/// Where a drag down has taken the photo.
///
/// A modifier of its own so that each step of a drag redraws this and nothing
/// else. Read in the viewer's body, every step rebuilt the whole viewer —
/// pager, controls, sheets and all — eighteen times for an eleven-step drag.
struct StageFollowsDrag: ViewModifier {
    let stage: ViewerStage?

    func body(content: Content) -> some View {
        content
            .scaleEffect(stage?.dragScale ?? 1)
            .offset(stage?.dragOffset ?? .zero)
    }
}

/// The viewer's controls, out of the way while a photo is dragged or flown
/// home: only the photo moves, as in Photos.
///
/// Faded rather than taken out. Taken out for the drag, they were built again,
/// glass and all, the moment it ended — in the very frame the photo set off
/// home, for a viewer that was on its way out.
struct StageHidesChrome: ViewModifier {
    let stage: ViewerStage?

    func body(content: Content) -> some View {
        let hidden = stage.map { $0.isDragging || $0.isClosing } ?? false
        content
            .opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .animation(.easeOut(duration: 0.15), value: hidden)
    }
}

/// Runs something once, at the start of the next frame: after everything
/// changed in this turn of the run loop has been sent to the screen.
@MainActor
private final class NextFrame: NSObject {
    private var link: CADisplayLink?
    private var action: (() -> Void)?

    static func run(_ action: @escaping () -> Void) {
        let next = NextFrame()
        next.action = action
        // The link holds its target until it is invalidated, which is what
        // keeps this alive until then.
        let link = CADisplayLink(target: next, selector: #selector(fire))
        next.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func fire() {
        link?.invalidate()
        link = nil
        let action = self.action
        self.action = nil
        action?()
    }
}
#endif
