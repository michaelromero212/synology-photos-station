import FrameStationAPI
import FrameStationKit
import SwiftUI

#if os(iOS)

/// Dragging across tiles to select them, the way Photos does.
///
/// Tapping one photo at a time is fine for three and miserable for thirty, which
/// is exactly the size of job this grid exists for — "put the holiday in the
/// shared space" is forty photos, not four.
///
/// A sweep only ever *adds* to the selection. Making the direction depend on the
/// first tile touched reads well on paper and is a trap in the hand: the natural
/// move is to long-press a photo and then drag on from it, and that tile is
/// selected by definition — so the gesture people reach for first would have
/// silently emptied their selection instead of extending it. Removing one photo
/// is a tap, which is cheap; losing forty to a misread gesture is not.
///
/// Each tile is acted on once per drag, so wobbling over a boundary doesn't flip
/// it back and forth under your finger.
///
/// Only ever armed while a selection is already active. A drag on the grid means
/// scroll the rest of the time, and there is no way to have both.

/// Where each on-screen tile sits, so a point can be turned into a photo.
///
/// Collected through a preference rather than computed, because the two layouts
/// this grid uses — square on iPhone, justified rows everywhere else — have
/// nothing in common to compute *from*. Only realised cells report, and only
/// while selecting, so browsing pays nothing for this.
struct TileFrameKey: PreferenceKey {
    static var defaultValue: [TimelineItem: CGRect] = [:]

    static func reduce(
        value: inout [TimelineItem: CGRect],
        nextValue: () -> [TimelineItem: CGRect]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Reports this tile's position while a selection is in progress.
    @ViewBuilder
    func sweepTarget(_ item: TimelineItem, in space: String, active: Bool) -> some View {
        if active {
            background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TileFrameKey.self,
                        value: [item: proxy.frame(in: .named(space))]
                    )
                }
            }
        } else {
            self
        }
    }
}

/// Turns a drag across the grid into a run of selections.
struct SelectionSweep: ViewModifier {
    let selection: GridSelection
    let space: String

    @State private var frames: [TimelineItem: CGRect] = [:]
    /// Tiles this drag has already passed over, so crossing a boundary twice
    /// doesn't act twice.
    @State private var visited: Set<TimelineItem> = []

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: space)
            .onPreferenceChange(TileFrameKey.self) { frames = $0 }
            // Simultaneous so the grid still scrolls under a selection — Photos
            // lets you do both, and a selection you cannot scroll is one you
            // cannot finish on a library of any size.
            //
            // The minimum distance is what keeps a tap a tap: without it, the
            // press that toggles one photo also registers as a zero-length
            // sweep and toggles it straight back.
            .simultaneousGesture(
                DragGesture(minimumDistance: 14, coordinateSpace: .named(space))
                    .onChanged { value in
                        guard selection.isActive else { return }
                        extend(to: value.location)
                    }
                    .onEnded { _ in visited.removeAll() }
            )
    }

    private func extend(to point: CGPoint) {
        guard let item = frames.first(where: { $0.value.contains(point) })?.key else { return }
        guard !visited.contains(item) else { return }
        visited.insert(item)

        // Already picked is a no-op rather than a toggle: dragging back across
        // your own trail should not start unpicking it.
        guard !selection.contains(item) else { return }
        selection.toggle(item)
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

extension View {
    /// Arms drag-to-select over a grid whose tiles call `sweepTarget`.
    func selectionSweep(
        _ selection: GridSelection, space: String = "photo-grid"
    ) -> some View {
        modifier(SelectionSweep(selection: selection, space: space))
    }
}

#endif
