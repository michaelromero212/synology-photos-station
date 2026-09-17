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
    /// Whether `image` is this phone's own copy, standing in until the NAS has
    /// one. A real picture, so it is not blurred like the ThumbHash — but still
    /// a stand-in, so it does not count as "already loaded" and must be
    /// replaced by the server's version when that arrives.
    @State private var isLocalOriginal = false

    /// Seeded from the decoded-image cache, so a tile whose picture is already
    /// in memory draws it in the very first frame rather than after two actor
    /// hops. That is what a tab switch costs otherwise: the grid is rebuilt, so
    /// every visible cell starts from nothing at the same moment and the whole
    /// screen greys before it fills.
    init(item: TimelineItem, loader: ThumbnailLoader?, size: CGSize) {
        self.item = item
        self.loader = loader
        self.size = size
        let cached = loader?.cachedThumbnail(
            assetID: item.assetID, size: PhotoGridMetrics.thumbnailPixels,
            version: item.thumbnailVersion
        )
        _image = State(initialValue: cached)
        // Decode the ThumbHash here too, so a tile with no cached picture opens
        // on its blurred preview instead of a grey square. This is the whole of
        // "thumbnails appear instantly": the sharp image still arrives over the
        // network in `load`, but there is a recognisable picture from the first
        // frame rather than grey → blur → sharp. The decode is 32px on bytes
        // already in the item — no network, no actor hop — cheap enough to run
        // as each lazy cell is created. Skipped when the sharp image is already
        // in hand, since then there is nothing to stand in for.
        _placeholder = State(
            initialValue: cached == nil
                ? item.thumbHashBytes.flatMap(ThumbnailLoader.placeholder(from:))
                : nil
        )
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
            // No transition. Crossing from the blurred placeholder to the sharp
            // image composites the two at partial opacity for the length of the
            // fade, which on one tile is a soft arrival and on a screenful of
            // them at cold start is the whole grid appearing to blink —
            // twenty-odd tiles each dipping in brightness, slightly out of step
            // with each other. Swapping outright is a single frame nobody
            // registers, which is what Photos and Synology's own app both look
            // like: the pictures are simply there.
            imageView(image)
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
        // Already painted from the memory cache by `init`; nothing to fetch.
        // A borrowed local copy does not count: it is standing in for a
        // thumbnail the NAS has not made yet, and when the NAS makes one this
        // task re-runs and should go and get it.
        if image != nil, !isLocalOriginal { return }

        // The ThumbHash placeholder was seeded in `init`, so it is already on
        // screen — no decode here, and no grey frame before it.
        //
        // 202 while the derivation queue is behind: keep the placeholder rather
        // than requesting an image that isn't there yet. The grid is told when
        // that changes — see DerivationWorker — and this task is keyed on it.
        guard item.isDerived, let loader else {
            // Except when the picture is already on this phone.
            //
            // "Keep the placeholder" assumed there was one. For anything just
            // uploaded there isn't: the ThumbHash is made *by* derivation, so
            // until that runs the item has no thumbnail and no stand-in for one,
            // and the tile is plain grey. Uploading a few hundred photos filled
            // the grid with grey squares — at exactly the moment somebody is
            // watching to see that their photographs arrived safely.
            //
            // So if this device is the one that uploaded it, draw it from the
            // camera roll. Same photograph, no network, no waiting on the NAS.
            #if os(iOS)
            await paintLocalOriginal()
            #endif

            // And then ask the server anyway, once.
            //
            // `isDerived` is what the *client* last heard, not what is true.
            // A delta that never arrived, or one applied to a copy that was
            // later replaced by a stale snapshot, leaves this false on an asset
            // the NAS finished long ago — and nothing re-asks, because the
            // task is keyed on this very flag. That is the difference between a
            // tile that is briefly grey and one that is grey for good.
            //
            // One request, and a 202 if it really isn't ready, which costs the
            // NAS almost nothing and cannot cache a miss. Worth it: the rule is
            // that a photograph on the server always ends up drawn.
            if image == nil, let loader,
               let loaded = await loader.thumbnail(
                   assetID: item.assetID, size: PhotoGridMetrics.thumbnailPixels,
                   version: item.thumbnailVersion
               ) {
                image = loaded
                isLocalOriginal = false
            }
            return
        }

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
                assetID: item.assetID, size: PhotoGridMetrics.thumbnailPixels,
                version: item.thumbnailVersion
            ) {
                image = loaded
                isLocalOriginal = false
                return
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 300_000_000 << UInt64(attempt))
            guard !Task.isCancelled else { return }
        }

        // Three tries is about a second, and the server can easily need longer.
        //
        // `isDerived` says the row has been marked derived; it does not promise
        // the bytes are servable this instant, and during a large backup they
        // often are not — the queue is minutes deep and the answer is a 202.
        // So a tile can burn all three attempts in the first second of being
        // looked at and then wait, grey, until the item changes and re-runs
        // this task.
        //
        // Caught on a device: an asset the server was serving perfectly well by
        // then still had a grey tile, because the cell had given up a minute
        // earlier and nothing had asked again since.
        //
        // If the photograph is on this phone, that wait is unnecessary.
        #if os(iOS)
        await paintLocalOriginal()
        #endif
    }

    #if os(iOS)
    /// Draws the copy still sitting in this phone's photo library.
    ///
    /// Into `image`, not `placeholder`, and the difference is visible: the
    /// placeholder slot is blurred six points because what normally goes there
    /// is a 32-pixel ThumbHash. Putting a real photograph through that blur was
    /// the first attempt, and it looked like a mistake rather than like a
    /// picture — soft in a grid where every neighbour is sharp.
    ///
    /// `isLocalOriginal` is what keeps it honest: `load` treats an image flagged
    /// that way as not-yet-loaded, so when the NAS finishes deriving and this
    /// task re-runs — it is keyed on `isDerived` — the server's thumbnail is
    /// fetched and takes over. Every device ends up showing the same picture;
    /// this one just doesn't have to wait to show *a* picture.
    ///
    /// The stream is two-phase — PhotoKit sends a fast degraded frame and then
    /// the full one — so the tile fills almost immediately and then sharpens.
    private func paintLocalOriginal() async {
        guard image == nil || isLocalOriginal,
              let localIdentifier = LocalOriginals.shared.localIdentifier(for: item.assetID),
              let asset = PhotoLibraryScanner.asset(for: localIdentifier)
        else { return }

        let pixels = CGFloat(PhotoGridMetrics.thumbnailPixels)
        for await thumbnail in PhotoLibraryScanner.thumbnails(
            for: asset, targetSize: CGSize(width: pixels, height: pixels)
        ) {
            guard !Task.isCancelled else { return }
            image = thumbnail
            isLocalOriginal = true
        }
    }
    #endif

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
