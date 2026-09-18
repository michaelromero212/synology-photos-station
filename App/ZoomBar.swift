import FrameStationAPI
import SwiftUI

/// Bigger photos, or more of them — floating above the tab bar.
///
/// This used to name its three stops Year / Month / Day. The stops themselves
/// haven't moved: the control still changes how the server groups the timeline
/// *and* how many photos fit across, and those still belong together, because a
/// year at four across is a wall of scrolling and a day at eleven across is
/// thumbnails nobody can recognize.
///
/// What changed is that the names are gone, because they were answering a
/// question nobody asks. Standing in front of a wall of photographs you want
/// them bigger, or you want to see more at once; the grouping that comes with
/// it is a consequence you'll accept without being consulted — which is exactly
/// why Apple's Photos offers this pair and *only* this pair, and why the month
/// captions simply appear once you're zoomed far enough out for them to be the
/// only way to tell where you are.
///
/// Apple keeps it two taps deep in View Options. On a library this size it gets
/// used constantly, so here it stays in reach.
struct ZoomBar: View {
    let zoom: TimelineZoom
    let onChange: (TimelineZoom) -> Void

    var body: some View {
        GlassGroup(spacing: 4) {
            HStack(spacing: 2) {
                // Minus left, plus right: the direction every stepper, map and
                // zoom control already agrees on, so the pair reads correctly
                // before either word is actually read.
                step(to: zoom.zoomedOut, symbol: "minus.magnifyingglass", label: "Zoom Out")
                step(to: zoom.zoomedIn, symbol: "plus.magnifyingglass", label: "Zoom In")
            }
            .padding(4)
            .glassCapsule(interactive: false, fallback: .regularMaterial)
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
        // Drives the capsule's width as a step appears or leaves. Without it the
        // pill jumps between one button and two, which is a worse artefact than
        // the grayed-out button this replaced.
        .animation(.snappy(duration: 0.26), value: zoom)
    }

    /// One step along the ladder, drawn only when there is a step to take.
    ///
    /// A direction that has run out leaves entirely rather than sitting there
    /// grayed out. Dimming was the obvious move and it looked wrong: over glass
    /// this transparent, a disabled label reads as half-rendered rather than as
    /// deliberately off, and at four across — where the library opens, and where
    /// it therefore spends most of its life — one of the two was always in that
    /// state. So the pill carries one button at each end of the ladder and two
    /// in the middle, and no dead control ever appears.
    ///
    /// The cost is a capsule that changes width, which is why `body` animates on
    /// the zoom.
    ///
    /// Glyph *and* word: the magnifiers alone would fit in half the space and
    /// are hardly cryptic, but this pill replaced three named options, and a
    /// control that drops its labels in the same change that alters what it does
    /// is one people have to poke at to re-learn.
    @ViewBuilder
    private func step(
        to destination: TimelineZoom?, symbol: String, label: String
    ) -> some View {
        if let destination {
            Button {
                onChange(destination)
            } label: {
                Label(label, systemImage: symbol)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .contentShape(Capsule())
            }
            // tvOS keeps its own button style: `.plain` strips the focus ring,
            // and on a television the focus ring is the only thing telling you
            // which control the remote is pointing at.
            #if !os(tvOS)
            .buttonStyle(.plain)
            #endif
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
        }
    }
}

extension TimelineZoom {
    /// How many photos fit across at this stop.
    ///
    /// Zooming out means smaller tiles and more of them: eleven across is for
    /// recognising a season at a glance, three is for looking at the photos.
    /// Three is where the library opens and stays the tightest stop — this
    /// control exists to leave that grid, not to replace it.
    ///
    /// Three rather than four because that is the width Photos opens at, and
    /// this app is meant to read as a continuation of it rather than as a
    /// denser cousin. The difference is bigger than one column sounds: at four
    /// across a phone-width tile is about 97pt, which is small enough that
    /// faces stop being recognisable and the grid becomes a texture you scan
    /// rather than a set of photographs you look at.
    var columns: Int {
        switch self {
        case .year: 11
        case .month: 5
        case .day: 3
        }
    }

    /// The stops in order, tightest first.
    ///
    /// Spelled out rather than taken from `allCases`. That order belongs to the
    /// wire type's declaration, and a control whose buttons depend on the
    /// order somebody happened to write an enum in is a trap waiting for
    /// whoever adds a fourth grouping.
    static let ladder: [TimelineZoom] = [.day, .month, .year]

    /// Bigger photos, fewer of them. `nil` at the tight end.
    var zoomedIn: TimelineZoom? { Self.ladder.step(from: self, by: -1) }

    /// Smaller photos, more of them. `nil` at the wide end.
    var zoomedOut: TimelineZoom? { Self.ladder.step(from: self, by: 1) }
}

private extension Array where Element == TimelineZoom {
    func step(from current: TimelineZoom, by offset: Int) -> TimelineZoom? {
        guard let index = firstIndex(of: current) else { return nil }
        let next = index + offset
        return indices.contains(next) ? self[next] : nil
    }
}
