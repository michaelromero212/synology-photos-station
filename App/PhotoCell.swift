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
    var side: CGFloat

    @State private var image: PlatformImage?
    @State private var placeholder: PlatformImage?

    var body: some View {
        ZStack {
            if let image {
                imageView(image)
                    .transition(.opacity)
            } else if let placeholder {
                imageView(placeholder)
                    .blur(radius: 6, opaque: true)
            } else {
                Rectangle().fill(.quaternary)
            }

            overlays
        }
        .frame(width: side, height: side)
        .clipped()
        .contentShape(Rectangle())
        .task(id: item.assetID) { await load() }
    }

    private func imageView(_ platformImage: PlatformImage) -> some View {
        #if canImport(UIKit)
        Image(uiImage: platformImage).resizable().scaledToFill()
        #else
        Image(nsImage: platformImage).resizable().scaledToFill()
        #endif
    }

    @ViewBuilder
    private var overlays: some View {
        VStack {
            Spacer()
            HStack(spacing: 4) {
                if item.mediaType == .video {
                    Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                    if let duration = item.durationMs {
                        Text(Self.formatDuration(duration)).font(.system(size: 11, weight: .semibold))
                    }
                }
                Spacer()
                if item.isFavorite {
                    Image(systemName: "heart.fill").font(.system(size: 10))
                }
            }
            .foregroundStyle(.white)
            .shadow(radius: 2)
            .padding(.horizontal, 5)
            .padding(.bottom, 4)
        }
    }

    private func load() async {
        if let bytes = item.thumbHashBytes {
            placeholder = ThumbnailLoader.placeholder(from: bytes)
        }
        // 202 while the derivation queue is behind; keep the placeholder rather
        // than requesting an image that isn't there yet.
        guard item.isDerived, let loader else { return }
        let loaded = await loader.thumbnail(assetID: item.assetID, size: 256)
        withAnimation(.easeOut(duration: 0.18)) { image = loaded }
    }

    static func formatDuration(_ milliseconds: Int) -> String {
        let total = milliseconds / 1000
        let minutes = total / 60, seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
