import Foundation
import Testing
@testable import FrameStationKit

/// Guards the client-side decode sizing.
///
/// The square grid tile fills by the SHORT edge under `scaledToFill`, but
/// ImageIO's `ThumbnailMaxPixelSize` caps the LONGEST edge. The whole persistent
/// blur was that gap: passing the short-edge target straight to ImageIO shrank
/// the short edge by the aspect ratio (a 512×1111 derivative decoded to 236×512),
/// so the tile then upscaled 236px into mush and silently threw away the server's
/// short-edge sizing. `maxPixelForShortEdge` scales the cap up by long/short so
/// the short edge lands on target. These pin that math down.
@Suite("Thumbnail decode sizes by the short edge")
struct ThumbnailSizingTests {
    @Test("A square thumbnail asks for exactly the target")
    func square() {
        #expect(
            ThumbnailLoader.maxPixelForShortEdge(
                targetShortEdge: 512, sourceWidth: 500, sourceHeight: 500
            ) == 512
        )
    }

    @Test("A 2:1 thumbnail asks for double, so the short edge still lands on target")
    func twoToOne() {
        // Landscape and portrait are the same request — the fill edge is the
        // short one either way, so the cap depends on the ratio, not the tilt.
        #expect(
            ThumbnailLoader.maxPixelForShortEdge(
                targetShortEdge: 512, sourceWidth: 1000, sourceHeight: 500
            ) == 1024
        )
        #expect(
            ThumbnailLoader.maxPixelForShortEdge(
                targetShortEdge: 512, sourceWidth: 500, sourceHeight: 1000
            ) == 1024
        )
    }

    @Test("The exact blur case: 512×1111 recovers a 512 short edge, not 236")
    func regressionCase() {
        // Before the fix this decoded to a 236px short edge and the 325px iPhone
        // tile upscaled it. The cap must be the long edge (1111) so ImageIO keeps
        // the short edge at the full 512 the server already wrote.
        #expect(
            ThumbnailLoader.maxPixelForShortEdge(
                targetShortEdge: 512, sourceWidth: 512, sourceHeight: 1111
            ) == 1111
        )
    }

    @Test("The cap is never below the target, so the fill edge is never upscaled")
    func neverBelowTarget() {
        for (w, h) in [(500, 500), (1000, 500), (512, 1111), (3, 4000), (4000, 3)] {
            #expect(
                ThumbnailLoader.maxPixelForShortEdge(
                    targetShortEdge: 512, sourceWidth: w, sourceHeight: h
                ) >= 512
            )
        }
    }

    @Test("A degenerate zero dimension falls back to the target, never divides by zero")
    func degenerate() {
        #expect(
            ThumbnailLoader.maxPixelForShortEdge(
                targetShortEdge: 512, sourceWidth: 0, sourceHeight: 0
            ) == 512
        )
    }
}
