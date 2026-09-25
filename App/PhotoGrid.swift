import FrameStationAPI
import FrameStationKit
import SwiftUI

/// Anything that can occupy a slot in the grid, in draw order.
///
/// Equatable so the collection-view grid can tell which of its visible days
/// actually changed — a day finishing loading, a pending tile starting to send —
/// and redraw only those. See `TimelineCollection`.
enum GridEntry: Identifiable, Equatable {
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
    /// The Mac and the television get justified rows; iPhone and iPad keep the
    /// square grid, which is also what Photos draws on both.
    ///
    /// The iPad had justified rows too, until the iPhone's grid became a
    /// collection view that knows where every day is before any of them loads —
    /// see `TimelineGridLayout`. That is only possible for squares: a justified
    /// row is sized from the shapes of its photographs, which aren't known until
    /// their day arrives. Left on the old grid, the iPad kept everything the
    /// iPhone had been rid of — the photographs moving under your finger as days
    /// were measured, the scrubber snapping — and none of what came after, like
    /// the viewer that opens over the grid. Sharing the square grid, the iPad
    /// gets all of it, and whatever the grid gets next.
    static var usesJustifiedRows: Bool {
        #if os(iOS)
        return false
        #else
        return true
        #endif
    }

    /// How many square tiles go across `width`, at a stop that puts
    /// `phoneColumns` across a phone.
    ///
    /// A phone gets exactly `phoneColumns` — every iPhone is narrower than the
    /// point where this would add one. Anything wider gets as many tiles as fit
    /// at about the size a phone's would be on a bigger screen: at the
    /// three-across stop, tiles of about 170 points, which on an iPad is five
    /// across in portrait and seven in landscape, close to what Photos shows
    /// there. Never fewer than a phone's, so a narrow Split View column is a
    /// phone's grid.
    ///
    /// From the width rather than the device, so turning an iPad or resizing it
    /// beside another app reflows the grid, and one rule serves every square
    /// grid in the app.
    static func squareColumns(_ phoneColumns: Int, across width: CGFloat) -> Int {
        let phone = max(phoneColumns, 1)
        guard width > 0 else { return phone }
        // A tile of `tileBasis / phone` points: 170 at the three-across stop,
        // 102 at five, 46 at eleven — the phone's stops in proportion.
        let fitted = Int((width * CGFloat(phone) / tileBasis).rounded())
        return max(phone, fitted)
    }

    /// The width that holds a stop's phone count at iPad size. See
    /// `squareColumns`.
    private static let tileBasis: CGFloat = 510

    /// Tighter on a phone, where two points of gap is already visible, and
    /// slightly looser where varied shapes need the separation to read.
    static var spacing: CGFloat {
        usesJustifiedRows ? 4 : 2
    }

    /// Which cached derivative a tile asks for.
    ///
    /// 256 and 512 are both derived eagerly at ingest, so either is a cache hit;
    /// 2048 is rendered on demand and far too heavy to ask for per tile. Every
    /// screen takes the 512: the phone's square tiles are ~270–390 px on a
    /// Retina display, and a 256 stretched into that is visibly soft — worse on
    /// an odd-aspect photo, whose short edge the square crop upscales hardest.
    /// The 512 (now sized by the short edge server-side) fills the tile without
    /// upscaling. It also sidesteps the old blur on a device that already cached
    /// the 256: `?size=512` is a different URL, so it fetches the sharp one fresh
    /// rather than serving the stale 256 from the immutable cache.
    static var thumbnailPixels: Int {
        512
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

/// One section's tiles: justified rows, or the square grid on iPhone and iPad.
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
    /// Columns for the square layout across a phone; a wider screen fits more —
    /// see `PhotoGridMetrics.squareColumns`. Ignored when rows are justified.
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
        let columns = PhotoGridMetrics.squareColumns(self.columns, across: width)
        let side = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let rows = Int((Double(entries.count) / Double(columns)).rounded(.up))
        // Declared, not discovered, and this is the fix for a scrubber that
        // lurched while the grid scrolled smoothly.
        //
        // A `LazyVGrid` does not know its own height until it has realized its
        // rows, and this one sits inside the timeline's `LazyVStack`, which
        // therefore cannot know a day's height until it draws that day. So the
        // scroll view guesses, and its guess was not close: measured on a
        // library of 582 photographs across 168 days, it first reported the
        // content as 26,956 points — about right — and then, in the frame the
        // top content margin landed, as 474,634. It settled at 191,364, seven
        // times the truth, and was still changing thirteen seconds later.
        //
        // The scrubber's position is the offset over that number, so every time
        // an unrealized day was realized and its guess collapsed to reality, the
        // thumb moved without the grid moving. At section boundaries. Which is
        // exactly where it was seen to jump.
        //
        // A square grid's height needs nothing realized to be known: the rows
        // are the entry count over the columns, and every tile is `side` tall.
        // Saying so leaves the stack nothing to estimate. The grid stays lazy
        // inside — a day of six hundred photographs still builds its rows as
        // they arrive — it simply no longer lies about how tall it will be.
        let height = CGFloat(rows) * side + CGFloat(max(rows - 1, 0)) * spacing
        return LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columns),
            spacing: spacing
        ) {
            ForEach(entries) { entry in
                cell(entry, CGSize(width: side, height: side))
            }
        }
        .frame(height: height)
    }
}
