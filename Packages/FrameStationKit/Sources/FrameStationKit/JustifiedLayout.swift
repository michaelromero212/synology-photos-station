import Foundation

/// One row of a justified grid: which items are in it, and the height they share.
public struct JustifiedRow: Equatable, Sendable {
    /// Indices into the array that was laid out.
    public let range: Range<Int>
    /// The height every item in this row is drawn at. Each item's width is its
    /// aspect ratio times this.
    public let height: Double

    public init(range: Range<Int>, height: Double) {
        self.range = range
        self.height = height
    }
}

/// Packs photos into rows that fill the width exactly, the way the Synology web
/// client and Google Photos do.
///
/// The point is shape: a landscape frame comes out wider than a portrait one, so
/// you can tell how a photo was taken without opening it. A square grid throws
/// that away and centre-crops everything into the same tile, which is why a
/// panorama and a portrait look identical until you tap them.
///
/// Works off `aspectRatio`, which rides in the timeline manifest — so a whole
/// section can be laid out exactly, at the right height, before a single image
/// has loaded. That matters for the scrollbar: rows that resize once thumbnails
/// arrive would make the grid jump under the finger.
///
/// Deliberately index-based rather than generic over the element: it keeps the
/// arithmetic testable on its own, and the caller maps the ranges back to
/// whatever it's drawing.
public enum JustifiedLayout {
    /// Ratios outside this range are clamped for layout.
    ///
    /// A 10:1 panorama laid out honestly gets a row to itself one tenth of the
    /// width tall — a letterbox slit with nothing readable in it. Clamping caps
    /// how far one frame can distort a row; the cell fills and centre-crops the
    /// remainder, which still reads unmistakably as a panorama.
    public static let ratioBounds: ClosedRange<Double> = 0.4...3.5

    /// - Parameters:
    ///   - aspectRatios: width / height per item, in draw order.
    ///   - width: the space a row has to fill.
    ///   - targetHeight: roughly how tall rows should come out. Rows are
    ///     stretched or squeezed off this to land on `width` exactly.
    ///   - spacing: the gap between items in a row.
    public static func rows(
        aspectRatios: [Double],
        width: Double,
        targetHeight: Double,
        spacing: Double
    ) -> [JustifiedRow] {
        guard width > 0, targetHeight > 0, !aspectRatios.isEmpty else { return [] }

        var rows: [JustifiedRow] = []
        var start = 0
        var ratioSum = 0.0

        for index in aspectRatios.indices {
            ratioSum += normalized(aspectRatios[index])
            let gaps = spacing * Double(index - start)

            // Close the row as soon as it would overflow at the target height,
            // then solve for the height that makes it fit exactly. Rows come
            // out a little shorter or taller than asked for, which is the
            // trade that buys a flush right edge.
            if ratioSum * targetHeight + gaps >= width {
                rows.append(
                    JustifiedRow(
                        range: start..<(index + 1),
                        height: max((width - gaps) / ratioSum, 1)
                    )
                )
                start = index + 1
                ratioSum = 0
            }
        }

        if start < aspectRatios.count {
            let gaps = spacing * Double(aspectRatios.count - start - 1)
            // The last row is whatever's left over, so it is *not* stretched to
            // fill: a day ending on one landscape photo would otherwise close
            // with a single frame running the whole width, taller than
            // everything above it and looking like a header.
            rows.append(
                JustifiedRow(
                    range: start..<aspectRatios.count,
                    height: min(max((width - gaps) / ratioSum, 1), targetHeight)
                )
            )
        }

        return rows
    }

    /// Guards the arithmetic. A missing or nonsense ratio becomes a square,
    /// which is the least wrong guess and matches how the tile renders anyway.
    public static func normalized(_ ratio: Double) -> Double {
        guard ratio.isFinite, ratio > 0 else { return 1 }
        return min(max(ratio, ratioBounds.lowerBound), ratioBounds.upperBound)
    }

    /// The width one item takes in a row of the given height.
    public static func width(forRatio ratio: Double, height: Double) -> Double {
        normalized(ratio) * height
    }
}
