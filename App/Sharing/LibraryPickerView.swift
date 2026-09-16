#if os(iOS)
import FrameStationAPI
import FrameStationKit
import Foundation
import Observation
import Photos
import SwiftUI

/// Backs the share picker: recent library assets, a selection, and the upload.
@Observable
@MainActor
final class LibraryPickerModel {
    private(set) var assets: [PHAsset] = []
    private(set) var access = PhotoLibraryScanner.access
    var selection: [String] = []


    /// Prefetches decoded thumbnails around the visible range. Without this the
    /// grid decodes on the scroll and stutters at exactly the moment the user
    /// notices.
    private let images = PHCachingImageManager()
    private var cachingSize = CGSize.zero

    /// The most recent items, newest first. Bounded because the picker is for
    /// "share what I just shot" — the full library is what backup is for.
    func load(limit: Int = 400, includeVideos: Bool = true) {
        access = PhotoLibraryScanner.access
        guard access == .authorized || access == .limited else { return }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false
        options.fetchLimit = limit
        if !includeVideos {
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        }

        let fetched = PHAsset.fetchAssets(with: options)
        var found: [PHAsset] = []
        found.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in found.append(asset) }
        assets = found
    }

    func startCaching(side: CGFloat) {
        let scale = UIScreen.main.scale
        let size = CGSize(width: side * scale, height: side * scale)
        guard size != cachingSize else { return }
        images.stopCachingImagesForAllAssets()
        cachingSize = size
        images.startCachingImages(
            for: assets, targetSize: size, contentMode: .aspectFill, options: nil
        )
    }

    /// See `PhotoLibraryScanner.thumbnails` — a stream, because opportunistic
    /// delivery sends a placeholder before the real thing. Routed through this
    /// model's own caching manager so the prefetch above is the thing that
    /// answers, rather than a second manager fetching it all again.
    func thumbnails(for asset: PHAsset, side: CGFloat) -> AsyncStream<UIImage> {
        let scale = UIScreen.main.scale
        return PhotoLibraryScanner.thumbnails(
            for: asset,
            targetSize: CGSize(width: side * scale, height: side * scale),
            using: images
        )
    }

    func toggle(_ asset: PHAsset) {
        if let index = selection.firstIndex(of: asset.localIdentifier) {
            selection.remove(at: index)
        } else {
            selection.append(asset.localIdentifier)
        }
    }

    func selectionNumber(for asset: PHAsset) -> Int? {
        selection.firstIndex(of: asset.localIdentifier).map { $0 + 1 }
    }

    /// The selection, oldest-first.
    ///
    /// Oldest-first so a batch lands in the order it was shot, which is the
    /// order it will read in once the timeline groups it.
    func chosenAssets() -> [PHAsset] {
        selection.compactMap { identifier in
            assets.first { $0.localIdentifier == identifier }
        }.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
    }
}

/// Multi-select grid for sharing straight into a space.
struct LibraryPickerView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO
    let onFinished: (Int) -> Void
    let onCancel: () -> Void

    @State private var model = LibraryPickerModel()
    private let columns = 4
    private let spacing: CGFloat = 2

    var body: some View {
        NavigationStack {
            Group {
                switch model.access {
                case .authorized, .limited:
                    grid
                case .notDetermined:
                    ContentUnavailableView {
                        Label("Photo access needed", systemImage: "photo.on.rectangle")
                    } description: {
                        Text("FrameStation needs to see your library to share from it.")
                    } actions: {
                        Button("Allow Access") {
                            Task {
                                _ = await PhotoLibraryScanner.requestAccess()
                                model.load()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                case .denied:
                    ContentUnavailableView(
                        "Photo access denied",
                        systemImage: "xmark.octagon",
                        description: Text("Turn on photo access in Settings to share from your library.")
                    )
                }
            }
            .navigationTitle("Add to \(space.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(addLabel) { send() }
                        .disabled(model.selection.isEmpty)
                        .fontWeight(.semibold)
                }
            }
            .task { model.load() }
        }
    }

    private var addLabel: String {
        model.selection.isEmpty ? "Add" : "Add \(model.selection.count)"
    }

    private var grid: some View {
        GeometryReader { proxy in
            let side = (proxy.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columns),
                    spacing: spacing
                ) {
                    ForEach(model.assets, id: \.localIdentifier) { asset in
                        PickerCell(
                            asset: asset,
                            side: side,
                            number: model.selectionNumber(for: asset),
                            model: model
                        )
                        .onTapGesture { model.toggle(asset) }
                    }
                }
            }
            .onAppear { model.startCaching(side: side) }
        }
    }

    /// Hands the upload to the session and gets out of the way.
    ///
    /// It used to hold this sheet open until the last byte landed, which meant
    /// sharing a four-minute video was four minutes of watching a progress bar
    /// over a grid you couldn't see. The photographs are already on the phone;
    /// there is nothing to wait for before showing them. So the batch goes to
    /// `PendingUploads`, the grid draws it from the local library with an upload
    /// badge, and this closes at once.
    ///
    /// Failures surface in the grid's own banner rather than here, because by
    /// the time one happens this sheet is long gone.
    private func send() {
        guard let client = session.client else { return }
        let chosen = model.chosenAssets()
        guard !chosen.isEmpty else { return }
        let pending = session.pendingUploads
        Task { await pending.upload(chosen, to: space, client: client) }
        onFinished(chosen.count)
    }
}

private struct PickerCell: View {
    let asset: PHAsset
    let side: CGFloat
    let number: Int?
    let model: LibraryPickerModel

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image)
                    .resizable().scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .overlay(alignment: .bottomLeading) {
            if asset.mediaType == .video {
                Label(Self.duration(asset.duration), systemImage: "video.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(4)
            }
        }
        .overlay(alignment: .topTrailing) { badge }
        .overlay {
            if number != nil {
                Rectangle().fill(.black.opacity(0.25))
            }
        }
        .task(id: asset.localIdentifier) {
            // Assigned each time rather than once: the first is the placeholder
            // and the one after it is the real thumbnail.
            for await next in model.thumbnails(for: asset, side: side) {
                image = next
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        ZStack {
            Circle()
                .fill(number == nil ? AnyShapeStyle(.black.opacity(0.25)) : AnyShapeStyle(Color.accentColor))
            Circle().strokeBorder(.white, lineWidth: 1.5)
            if let number {
                Text("\(number)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 22, height: 22)
        .padding(5)
    }

    /// `0:07`, `1:42`.
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
#endif
