import FrameStationAPI
import FrameStationKit
import SwiftUI

/// One grid cell.
///
/// Paints the ThumbHash immediately — it ships inside the timeline payload, so
/// there is a recognisable image on screen before any network request — then
/// crossfades to the real thumbnail when it arrives. A cell that starts grey
/// and pops is the single most obvious way a photo grid feels cheap.
struct PhotoCell: View {
    let item: TimelineItem
    let loader: ThumbnailLoader?
    /// The frame this tile fills. Square on iPhone; on every other platform the
    /// justified grid hands it a width that follows the photo's own shape.
    var size: CGSize

    @State private var image: PlatformImage?
    @State private var placeholder: PlatformImage?

    /// Seeded from the decoded-image cache, so a tile whose picture is already
    /// in memory draws it in the very first frame rather than after two actor
    /// hops. That is what a tab switch costs otherwise: the grid is rebuilt, so
    /// every visible cell starts from nothing at the same moment and the whole
    /// screen greys before it fills.
    init(item: TimelineItem, loader: ThumbnailLoader?, size: CGSize) {
        self.item = item
        self.loader = loader
        self.size = size
        _image = State(initialValue: loader?.cachedThumbnail(
            assetID: item.assetID, size: PhotoGridMetrics.thumbnailPixels
        ))
    }

    /// The picture is clipped to the tile *before* the overlay goes on.
    ///
    /// It used to be a `ZStack` of image and overlay with the frame applied to
    /// the pair. `scaledToFill` makes the image larger than the tile, so the
    /// stack sized itself to the *image*, and the overlay's bottom edge sat
    /// below the tile — outside the clip, thrown away. That is why no video in
    /// this grid has ever shown its duration: the label was being drawn
    /// offscreen, not styled badly.
    var body: some View {
        picture
            .frame(width: size.width, height: size.height)
            .clipped()
            .overlay(alignment: .top) { durationBadge }
            .overlay(alignment: .bottom) { favouriteBadge }
            .contentShape(Rectangle())
            // Keyed on the derivation state as well as the identity. Keyed on
            // the id alone, a tile drawn before its thumbnail existed never
            // asked again: the id doesn't change when the derivation lands, so
            // the task never re-ran and the cell sat grey until the app was
            // relaunched. The id still has to be in the key — cells are recycled
            // between photos and must reload when the photo changes.
            .task(id: LoadKey(assetID: item.assetID, isDerived: item.isDerived)) {
                await load()
            }
    }

    /// What makes a reload necessary: a different photo, or the same photo
    /// finally having a picture to fetch.
    private struct LoadKey: Equatable {
        let assetID: UUID
        let isDerived: Bool
    }

    @ViewBuilder
    private var picture: some View {
        if let image {
            imageView(image)
                .transition(.opacity)
        } else if let placeholder {
            imageView(placeholder)
                .blur(radius: 6, opaque: true)
        } else {
            Rectangle().fill(.quaternary)
        }
    }

    private func imageView(_ platformImage: PlatformImage) -> some View {
        #if canImport(UIKit)
        Image(uiImage: platformImage).resizable().scaledToFill()
        #else
        Image(nsImage: platformImage).resizable().scaledToFill()
        #endif
    }

    /// Top-right, which is where Synology puts it and — more to the point —
    /// one of the two corners this tile has left. Top-left is the selection
    /// mark and bottom-right is the upload badge; a duration in either would
    /// sit under something.
    ///
    /// The scrim is what makes it readable. White text with a drop shadow
    /// disappears over a bright thumbnail, which is most of them: a snowy
    /// slope, a sunlit wall, a video whose first frame is a white title card.
    /// A darkened band reads over anything without being a box drawn on the
    /// picture.
    @ViewBuilder
    private var durationBadge: some View {
        if item.mediaType == .video, let duration = item.durationMs {
            ZStack(alignment: .topTrailing) {
                LinearGradient(
                    colors: [.black.opacity(0.5), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .allowsHitTesting(false)

                // No play triangle. The duration already says it's a video,
                // and the glyph is one more thing over the picture.
                Text(Self.formatDuration(duration))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
            }
            .frame(height: 30)
        }
    }

    /// Bottom-left, where Photos keeps it, and the last free corner.
    @ViewBuilder
    private var favouriteBadge: some View {
        if item.isFavorite {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [.black.opacity(0.45), .clear],
                    startPoint: .bottom, endPoint: .top
                )
                .allowsHitTesting(false)

                Image(systemName: "heart.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 5)
            }
            .frame(height: 28)
        }
    }

    private func load() async {
        // Already painted from the memory cache by `init`; nothing to fetch and
        // nothing to animate.
        if image != nil { return }

        if let bytes = item.thumbHashBytes {
            placeholder = ThumbnailLoader.placeholder(from: bytes)
        }
        // 202 while the derivation queue is behind; keep the placeholder rather
        // than requesting an image that isn't there yet. The grid is told when
        // that changes — see DerivationWorker — and this task is keyed on it.
        guard item.isDerived, let loader else { return }

        // A nil answer is a setback, not a verdict.
        //
        // It used to be final: one dropped connection, one request cancelled by
        // navigating away mid-flight, or one coalesced caller inheriting a
        // failure, and that tile stayed grey for the life of the cell. Nothing
        // ever asked again, which is why thumbnails "sometimes" didn't come back
        // after leaving a tab and returning.
        //
        // Three tries with a widening gap, and only for photos the server has
        // already said it derived — so this retries a genuine failure and never
        // polls for work that hasn't been done yet.
        for attempt in 0..<3 {
            if let loaded = await loader.thumbnail(
                assetID: item.assetID, size: PhotoGridMetrics.thumbnailPixels
            ) {
                withAnimation(.easeOut(duration: 0.18)) { image = loaded }
                return
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 300_000_000 << UInt64(attempt))
            guard !Task.isCancelled else { return }
        }
    }

    /// `0:59`, `12:08`, `1:02:33` — the way Photos writes them.
    ///
    /// Hours matter for a family library: an hour of a school concert used to
    /// read as `71:14`, which is not a duration anybody writes.
    static func formatDuration(_ milliseconds: Int) -> String {
        let total = max(milliseconds / 1000, 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
