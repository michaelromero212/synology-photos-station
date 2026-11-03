#if os(iOS)
import FrameStationAPI
import Observation
import SwiftUI
import UIKit

/// The library's viewer for every other grid: albums, the Albums page's
/// collections, and Recently Deleted.
///
/// Those grids pushed their viewer, one photo at a time with no swiping, or
/// covered the screen with it, and none of them closed the way the library
/// does. Now a photo grows out of its tile, swipes through the grid it came
/// from, and goes back into the tile of whatever it ended on, dragged down or
/// closed with the back button — the library's `ViewerStage`, frame for frame.
///
/// One stage for the whole app, over the tab view rather than over each grid:
/// these grids sit under the system's navigation bar, and a layer inside the
/// screen is drawn under that bar. `RootTabView` puts it up and hands it down.
@Observable
@MainActor
final class OverlayViewer {
    let stage = ViewerStage()
    /// What the open grid shows its photo in, set as it opens one.
    @ObservationIgnored fileprivate var build: ((OpenedPhoto) -> AnyView)?

    /// Opens a photo from `tiles`' grid, growing it out of its tile.
    func open<Viewer: View>(
        _ photo: OpenedPhoto, from tiles: GridTiles, session: AppSession,
        @ViewBuilder viewer: @escaping (OpenedPhoto) -> Viewer
    ) {
        guard !stage.isPresented else { return }
        build = { AnyView(viewer($0)) }
        stage.tileFrame = { [weak tiles] item in tiles?.frame(of: item.id) }
        stage.willClose = {}
        let item = photo.item
        // The tile's own thumbnail flies, as in the library. See
        // `TimelineView.openInStage`.
        let image = session.loader?.cachedThumbnail(
            assetID: item.assetID, size: PhotoGridMetrics.thumbnailPixels,
            version: item.thumbnailVersion
        ) ?? session.loader?.cachedPlaceholder(assetID: item.assetID)
        stage.present(photo, from: tiles.frame(of: item.id), image: image)
    }

    /// Keeps the grid under the viewer on the photo it shows, so closing lands
    /// in that photo's tile. See `TimelineView.followFocus`.
    func follow(_ item: TimelineItem, in tiles: GridTiles) {
        tiles.reveal(item.id)
        stage.lift(item.id)
    }
}

/// Where each tile of a scrolling grid is, for the viewer to fly to and from.
///
/// Kept in the grid's own coordinates, which don't move as it scrolls, so a
/// tile reports once as it's laid out rather than on every frame of a scroll.
/// Only the grid's origin follows the scroll.
@MainActor
final class GridTiles {
    static let space = "StagedGrid"

    fileprivate var frames: [UUID: CGRect] = [:]
    /// The grid's top left, in the window.
    fileprivate var origin: CGPoint = .zero
    /// What of the scroll view is out from under the bars, in the window.
    fileprivate var viewport: CGRect = .zero
    fileprivate var scroller: ScrollViewProxy?

    /// A tile's place in the window, while any of it shows. Nil for one off
    /// screen, which the photo then fades rather than flying into nothing.
    func frame(of id: UUID) -> CGRect? {
        guard let frame = frames[id] else { return nil }
        let placed = frame.offsetBy(dx: origin.x, dy: origin.y)
        return viewport.intersects(placed) ? placed : nil
    }

    /// Scrolls a tile into the middle unless it's already all on screen.
    func reveal(_ id: UUID) {
        if let shown = frame(of: id), viewport.contains(shown) { return }
        // The identity the grid's `ForEach` gives a photo. See `GridEntry.id`.
        scroller?.scrollTo("i\(id.uuidString)", anchor: .center)
    }
}

extension EnvironmentValues {
    @Entry var overlayViewer: OverlayViewer?
}

/// The stage itself, over everything it covers. See `OverlayViewer`.
struct OverlayViewerLayer: View {
    let viewer: OverlayViewer

    var body: some View {
        ViewerStageView(stage: viewer.stage) { opened in viewer.build?(opened) }
    }
}

extension View {
    /// A grid's scroll view, measured for `GridTiles`. Goes on the
    /// `ScrollView`, with `stagedGridContent` on what it scrolls.
    func stagedGridScroller(_ tiles: GridTiles) -> some View {
        onGeometryChange(for: CGRect.self) { proxy in
            let frame = proxy.frame(in: .global)
            let insets = proxy.safeAreaInsets
            return CGRect(
                x: frame.minX + insets.leading, y: frame.minY + insets.top,
                width: frame.width - insets.leading - insets.trailing,
                height: frame.height - insets.top - insets.bottom
            )
        } action: { tiles.viewport = $0 }
    }

    /// What a grid scrolls: the space its tiles report in, and where that is
    /// in the window.
    func stagedGridContent(_ tiles: GridTiles) -> some View {
        coordinateSpace(name: GridTiles.space)
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: {
                tiles.origin = $0
            }
    }

    /// One tile: where it is, and out of the grid while its photo is open.
    func stagedTile(_ id: UUID, in tiles: GridTiles, stage: ViewerStage?) -> some View {
        modifier(StagedTile(id: id, tiles: tiles, stage: stage))
    }
}

private struct StagedTile: ViewModifier {
    let id: UUID
    let tiles: GridTiles
    let stage: ViewerStage?

    func body(content: Content) -> some View {
        Group {
            if let stage {
                content.modifier(LiftedFromGrid(stage: stage, id: id))
            } else {
                content
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(GridTiles.space)) } action: {
            tiles.frames[id] = $0
        }
    }
}

/// Hands a grid's `ScrollViewReader` to its `GridTiles`.
struct StagedGridReader<Content: View>: View {
    let tiles: GridTiles
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            content().onAppear { tiles.scroller = proxy }
        }
    }
}
#endif
