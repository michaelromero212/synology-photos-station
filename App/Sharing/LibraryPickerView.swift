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

    private(set) var isUploading = false
    private(set) var sent = 0
    private(set) var failed = 0
    private(set) var total = 0
    private(set) var lastError: String?

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

    func thumbnail(for asset: PHAsset, side: CGFloat) async -> UIImage? {
        let scale = UIScreen.main.scale
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        // Thumbnails may only exist in iCloud when Optimize Storage is on.
        options.isNetworkAccessAllowed = true

        return await withCheckedContinuation { continuation in
            var resumed = false
            images.requestImage(
                for: asset,
                targetSize: CGSize(width: side * scale, height: side * scale),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                // Opportunistic delivery calls back more than once (degraded,
                // then full). A continuation may only be resumed once, so take
                // the first non-nil and ignore the rest.
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !resumed, image != nil || !degraded else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
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

    /// Uploads the selection into `space`. Returns true if everything landed.
    @discardableResult
    func upload(to space: SpaceDTO, client: FrameStationClient) async -> Bool {
        guard !selection.isEmpty else { return true }
        isUploading = true
        sent = 0
        failed = 0
        lastError = nil
        total = selection.count
        defer { isUploading = false }

        // Oldest-first so a batch lands in the order it was shot, which is the
        // order it will read in once the timeline groups it.
        let chosen = selection.compactMap { identifier in
            assets.first { $0.localIdentifier == identifier }
        }.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }

        for asset in chosen {
            guard let candidate = PhotoLibraryScanner.describe(asset) else {
                failed += 1
                lastError = UploadError.noExportableResource.localizedDescription
                continue
            }
            do {
                _ = try await AssetUploader.send(
                    asset,
                    descriptor: UploadDescriptor(asset: asset, candidate: candidate),
                    to: space.id,
                    client: client
                )
                sent += 1
            } catch {
                failed += 1
                lastError = error.localizedDescription
            }
        }
        return failed == 0
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
                    Button("Cancel", action: onCancel).disabled(model.isUploading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isUploading {
                        ProgressView()
                    } else {
                        Button(addLabel) { Task { await send() } }
                            .disabled(model.selection.isEmpty)
                            .fontWeight(.semibold)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { statusBar }
            .task { model.load() }
        }
        .interactiveDismissDisabled(model.isUploading)
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

    @ViewBuilder
    private var statusBar: some View {
        if model.isUploading || model.failed > 0 {
            VStack(spacing: 4) {
                if model.isUploading {
                    ProgressView(value: Double(model.sent + model.failed), total: Double(model.total))
                    Text("Sharing \(model.sent + model.failed) of \(model.total)…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.lastError, model.failed > 0 {
                    Text("\(model.failed) failed — \(error)")
                        .font(.caption).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private func send() async {
        guard let client = session.client else { return }
        let allLanded = await model.upload(to: space, client: client)
        // Anything that failed stays on screen with its reason rather than
        // closing and quietly losing the report.
        if allLanded { onFinished(model.sent) }
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
            image = await model.thumbnail(for: asset, side: side)
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
