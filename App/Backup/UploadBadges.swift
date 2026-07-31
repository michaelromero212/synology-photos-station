#if os(iOS)
import FrameStationAPI
import Foundation
import Photos
import SwiftUI

/// Where a photo is in its journey to the NAS, as a corner badge.
///
/// Mirrors what Synology Photos does, because it's the right idea: the state
/// belongs on the tile itself, not in a progress bar somewhere else. You look
/// at a photo and know whether it's safe.
enum UploadState {
    /// Queued — on this phone, not yet on the NAS.
    case pending
    /// Going up right now.
    case uploading
    /// Landed. Shown until the next pull-to-refresh, then it stops being news.
    case uploaded
}

struct UploadStateBadge: View {
    let state: UploadState
    var size: CGFloat = 22

    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.35))
            switch state {
            case .pending:
                Image(systemName: "arrow.up")
                    .font(.system(size: size * 0.5, weight: .bold))
                Circle().strokeBorder(.white, lineWidth: 1.5)
            case .uploading:
                Image(systemName: "arrow.up")
                    .font(.system(size: size * 0.5, weight: .bold))
                // A gap in the ring is what makes rotation legible; a full
                // circle spinning looks identical to a still one.
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(
                        .linear(duration: 1).repeatForever(autoreverses: false), value: spin
                    )
                    .onAppear { spin = true }
            case .uploaded:
                Image(systemName: "checkmark.icloud.fill")
                    .font(.system(size: size * 0.55, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.4), radius: 2)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .pending: "Waiting to back up"
        case .uploading: "Backing up"
        case .uploaded: "Backed up"
        }
    }
}

/// A photo that exists on this phone but not yet on the NAS.
///
/// Drawn from the local library so the grid shows it immediately — waiting for
/// the upload to finish before it appears would make a fresh camera roll look
/// empty for as long as the backup takes.
struct PendingTile: View {
    let localIdentifier: String
    let state: UploadState
    let side: CGFloat

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .overlay(alignment: .bottomTrailing) {
            UploadStateBadge(state: state).padding(5)
        }
        .task(id: localIdentifier) { image = await thumbnail() }
    }

    private func thumbnail() async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier], options: nil
        ).firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let scale = UIScreen.main.scale

        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: side * scale, height: side * scale),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                // Opportunistic delivery fires more than once; a continuation
                // may only be resumed once.
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !resumed, image != nil || !degraded else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }
}
#endif
