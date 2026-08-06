import FrameStationAPI
import FrameStationKit
import SwiftUI

/// Anything that can occupy a slot in the grid, in draw order.
enum GridEntry: Identifiable {
    case item(TimelineItem)
    /// Keeps an unloaded bucket the right height so the scrollbar doesn't jump
    /// when its contents land.
    case placeholder(Int)
    #if os(iOS)
    /// A photo that so far exists only on this phone.
    case pending(localIdentifier: String, state: UploadState)
    #endif

    var id: String {
        switch self {
        case .item(let item): "i\(item.id.uuidString)"
        case .placeholder(let index): "x\(index)"
        #if os(iOS)
        case .pending(let identifier, _): "p\(identifier)"
        #endif
        }
    }

    /// Placeholders and not-yet-uploaded photos are laid out square: nothing is
    /// known about their shape until the server has seen them, and a square is
    /// the least wrong guess.
    var aspectRatio: Double {
        if case .item(let item) = self { return item.aspectRatio }
        return 1
    }
}

/// How the grid is proportioned on this platform.
enum PhotoGridMetrics {
    /// iPhone keeps the square grid; everywhere else gets justified rows.
    ///
    /// Not a size class. An iPhone in landscape reports a regular width on the
    /// larger models, and this is a decision about the device rather than about
    /// how wide the window happens to be right now — the ask was that iPhone
    /// stays exactly as it is.
    static var usesJustifiedRows: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return true
        #endif
    }

    /// Tighter on a phone, where two points of gap is already visible, and
    /// slightly looser where varied shapes need the separation to read.
    static var spacing: CGFloat {
        usesJustifiedRows ? 4 : 2
    }

    /// Which cached derivative a tile asks for.
    ///
    /// 256 and 512 are both derived eagerly at ingest, so either is a cache
    /// hit. 2048 is rendered on demand, and asking for it per tile would put a
    /// full-size decode per photo on a J4125 — not an option. But 256 stretched
    /// into a 260-point row on a television is visibly soft, so the bigger
    /// screens take the 512 and the phone keeps the smaller one.
    static var thumbnailPixels: Int {
        usesJustifiedRows ? 512 : 256
    }

    /// Roughly how tall a row comes out, before it's stretched to fit.
    ///
    /// Fixed per platform rather than derived from the window width, and that's
    /// the point: a wider window gets *more photos per row*, not bigger ones.
    /// It's what makes a photo the same size in a Mac window, on an iPad and on
    /// a TV, and it's why the grid survives an iPad split view without becoming
    /// a two-column wall of enormous tiles.
    static func targetRowHeight(for zoom: TimelineZoom) -> CGFloat {
        #if os(tvOS)
        // A ten-foot layout: everything roughly doubles.
        switch zoom {
        case .year: return 110
        case .month: return 175
        case .day: return 260
        }
        #elseif os(macOS)
        switch zoom {
        case .year: return 84
        case .month: return 132
        case .day: return 196
        }
        #else
        switch zoom {
        case .year: return 76
        case .month: return 120
        case .day: return 178
        }
        #endif
    }
}

// MARK: - Opening a photo

/// The zoom transition, where the platform has one.
///
/// Opening a photo was a plain navigation push — a new screen sliding in from
/// the right. Photos lifts the tile you tapped and grows it into the full-screen
/// image, then drops it back into the grid on the way out, and that one
/// difference is most of why this app didn't feel like that one: it happens
/// every single time anybody looks at a photo.
///
/// iOS 18 added exactly this transition. Below 18 the push is what's left, which
/// is the behaviour the app already had.
extension View {
    /// The tile the transition grows *from*.
    @ViewBuilder
    func photoTransitionSource(id: UUID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, macOS 15.0, tvOS 18.0, *) {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// The viewer the transition grows *into*. The id has to be the same
    /// placement the tile registered, or the system quietly falls back to a
    /// push and the whole thing looks like it isn't working.
    ///
    /// iOS and tvOS only — macOS has `matchedTransitionSource` but no zoom
    /// transition to pair it with, and a Mac window doesn't push-and-pop the way
    /// this is compensating for anyway.
    @ViewBuilder
    func photoZoomTransition(id: UUID, in namespace: Namespace.ID) -> some View {
        #if os(macOS)
        self
        #else
        if #available(iOS 18.0, tvOS 18.0, *) {
            self.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
        #endif
    }
}

/// One section's tiles: justified rows, or the square grid on iPhone.
///
/// The two layouts live behind one view so callers build their cells once. What
/// differs is only the frame each cell is handed — which is also why `cell`
/// takes a size rather than reading one off the environment.
struct PhotoGridSection<Cell: View>: View {
    let entries: [GridEntry]
    /// The space a row has to fill.
    let width: CGFloat
    let targetHeight: CGFloat
    let spacing: CGFloat
    /// Columns for the square layout. Ignored when rows are justified.
    let columns: Int
    @ViewBuilder let cell: (GridEntry, CGSize) -> Cell

    var body: some View {
        if PhotoGridMetrics.usesJustifiedRows {
            justified
        } else {
            square
        }
    }

    // MARK: - Justified

    private var rows: [JustifiedRow] {
        JustifiedLayout.rows(
            aspectRatios: entries.map(\.aspectRatio),
            width: Double(width),
            targetHeight: Double(targetHeight),
            spacing: Double(spacing)
        )
    }

    /// `LazyVStack`, not `VStack`. A day with six hundred photos is eighty rows,
    /// and an eager stack would build — and start a thumbnail request for —
    /// every one of them the moment the section scrolled into view.
    private var justified: some View {
        LazyVStack(alignment: .leading, spacing: spacing) {
            ForEach(rows, id: \.range.lowerBound) { row in
                HStack(spacing: spacing) {
                    ForEach(entries[row.range]) { entry in
                        cell(
                            entry,
                            CGSize(
                                width: JustifiedLayout.width(
                                    forRatio: entry.aspectRatio, height: row.height
                                ),
                                height: row.height
                            )
                        )
                    }
                }
            }
        }
    }

    // MARK: - Square

    private var square: some View {
        let side = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        return LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columns),
            spacing: spacing
        ) {
            ForEach(entries) { entry in
                cell(entry, CGSize(width: side, height: side))
            }
        }
    }
}
