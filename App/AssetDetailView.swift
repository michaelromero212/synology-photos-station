import FrameStationAPI
import FrameStationKit
import Observation
import SwiftUI

/// State for one open photo.
///
/// This is an `@Observable` class rather than a pile of `@State` on the view for
/// a specific reason: the Information panel is presented in a `.sheet`, and
/// state read *inside* a sheet's content closure is not reliably tracked — the
/// closure can keep showing the values it saw at presentation time. That cost
/// real debugging time: the request succeeded, the JSON decoded, and the panel
/// still span forever. An observed object, read by a child view with its own
/// body, propagates correctly.
@Observable
@MainActor
final class AssetDetailModel {
    var image: PlatformImage?
    var placeholder: PlatformImage?
    var detail: AssetDetail?
    var detailError: String?
    var imageError: String?
    var isFavorite: Bool
    /// Names of shared spaces this photo has been added to in this session, so
    /// the action can confirm rather than silently succeeding.
    var addedTo: [String] = []
    var addError: String?

    private let item: TimelineItem
    private let spaceID: UUID

    init(item: TimelineItem, spaceID: UUID) {
        self.item = item
        self.spaceID = spaceID
        self.isFavorite = item.isFavorite
    }

    func load(loader: ThumbnailLoader?, client: FrameStationClient?) async {
        if let bytes = item.thumbHashBytes {
            placeholder = ThumbnailLoader.placeholder(from: bytes)
        }
        guard let loader, let client else {
            detailError = "Not connected."
            return
        }

        // The cached 512 first, so something real is on screen while the server
        // renders the 2048 preview.
        if let cached = await loader.thumbnail(assetID: item.assetID, size: 512), image == nil {
            image = cached
        }
        if let preview = await loader.preview(assetID: item.assetID) {
            withAnimation(.easeOut(duration: 0.2)) { image = preview }
        } else if image == nil {
            imageError = "Couldn't load this photo."
        }

        await loadDetail(client)
    }

    /// Never swallow the error here. An earlier version caught and ignored it,
    /// so a failure was indistinguishable from still loading.
    func loadDetail(_ client: FrameStationClient) async {
        do {
            detail = try await client.detail(spaceID: spaceID, assetID: item.assetID)
            detailError = nil
        } catch {
            detailError = error.localizedDescription
        }
    }

    /// Links the existing blob into another space. Costs no storage — the file
    /// is content-addressed and already on the NAS, so this is one row.
    func addTo(_ space: SpaceDTO, client: FrameStationClient?) async {
        guard let client else { return }
        do {
            _ = try await client.linkAsset(spaceID: space.id, assetID: item.assetID)
            if !addedTo.contains(space.name) { addedTo.append(space.name) }
            addError = nil
        } catch {
            addError = error.localizedDescription
        }
    }

    func toggleFavorite(_ client: FrameStationClient?) async {
        guard let client else { return }
        let target = !isFavorite
        isFavorite = target
        do {
            try await client.setFavorite(spaceID: spaceID, assetID: item.assetID, target)
        } catch {
            isFavorite = !target
        }
    }
}

/// Full-screen viewer, opened from the grid.
///
/// Shows the 2048 px preview rather than the original — the server renders it on
/// first request and caches it, so a 24 MP HEIC never crosses the network just
/// to be looked at.
struct AssetDetailView: View {
    let item: TimelineItem
    let space: SpaceDTO
    @Bindable var session: AppSession

    @State private var model: AssetDetailModel
    @State private var showInfo = false
    #if os(iOS)
    /// The other photos from the same day, for the slideshows and for knowing
    /// what "all videos from that day" means.
    var dayItems: [TimelineItem] = []
    @State private var showChrome = true
    @State private var confirmDelete = false
    @State private var shareFiles: [URL] = []
    @State private var showShare = false
    @State private var slideshow: SlideshowMode?
    @State private var isWorking = false
    @Environment(\.dismiss) private var dismiss
    #endif

    init(
        item: TimelineItem,
        space: SpaceDTO,
        session: AppSession,
        dayItems: [TimelineItem] = []
    ) {
        self.item = item
        self.space = space
        self.session = session
        #if os(iOS)
        // Everything from the same section, so a slideshow knows what "that
        // day" contains without going back to the server for it.
        self.dayItems = dayItems
        #endif
        self._model = State(initialValue: AssetDetailModel(item: item, spaceID: space.id))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if item.mediaType == .video {
                // Direct play, Range-served. The poster sits behind it so the
                // frame doesn't flash black while the signed URL is fetched.
                #if os(iOS)
                VideoPlayerView(
                    assetID: item.assetID,
                    client: session.client,
                    poster: model.image ?? model.placeholder,
                    showsControls: showChrome
                )
                // Measured against the full screen, not the safe area. Hiding
                // the navigation bar reveals the status bar underneath it,
                // which resizes the safe area and slid the video ~14pt — a
                // still image doesn't move, and neither should this.
                .ignoresSafeArea()
                #else
                VideoPlayerView(
                    assetID: item.assetID,
                    client: session.client,
                    poster: model.image ?? model.placeholder
                )
                #endif
            } else if let image = model.image {
                imageView(image).transition(.opacity)
            } else if let placeholder = model.placeholder {
                imageView(placeholder).blur(radius: 14, opaque: true)
            } else {
                ProgressView().tint(.white)
            }

            if !model.addedTo.isEmpty || model.addError != nil {
                VStack {
                    Spacer()
                    Text(model.addError ?? "Added to \(model.addedTo.joined(separator: ", "))")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.black.opacity(0.75), in: Capsule())
                        .foregroundStyle(model.addError == nil ? .white : .orange)
                        .padding(.bottom, 80)
                }
                .transition(.opacity)
            }

            if let imageError = model.imageError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(imageError).font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        // Navigation *bars* are iOS-only; macOS has no equivalent modifiers.
        #if os(iOS)
        .toolbar { toolbar }
        .toolbar(.hidden, for: .tabBar)
        // A tap clears the screen down to the media and nothing else — the
        // back chevron and date go with the action bar, and the next tap
        // brings all of it back.
        .toolbar(showChrome ? .visible : .hidden, for: .navigationBar)
        .toolbarBackground(.black.opacity(0.6), for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // iOS reveals its actions on tap (`viewerActions`); showing this one
        // too stacked two bars on top of each other.
        #if !os(iOS)
        .safeAreaInset(edge: .bottom) { actionBar }
        #endif
        #if os(iOS)
        // One tap reveals the actions, matching Photos and Synology both.
        .onTapGesture { withAnimation { showChrome.toggle() } }
        // An overlay, not a safe-area inset: an inset shrinks the layout, so
        // the photo jumped up when the bar appeared and back down when it
        // hid. Floating the bar over the media leaves it centred either way.
        .overlay(alignment: .bottom) {
            if showChrome { viewerActions }
        }
        .fullScreenCover(item: $slideshow) { mode in
            SlideshowView(
                session: session,
                items: dayItems.isEmpty ? [item] : dayItems,
                mode: mode,
                startingAt: item
            ) { slideshow = nil }
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareFiles) }
        .confirmationDialog(
            "Remove this photo from \(space.name)?",
            isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task {
                    try? await session.client?.removeAsset(
                        spaceID: space.id, assetID: item.assetID
                    )
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It stays on this iPhone. On the NAS it moves to #recycle, and backup won't add it again.")
        }
        #endif
        .sheet(isPresented: $showInfo) {
            InformationSheet(model: model, session: session) { showInfo = false }
        }
        .task { await model.load(loader: session.loader, client: session.client) }
    }

    private func imageView(_ platformImage: PlatformImage) -> some View {
        #if canImport(UIKit)
        Image(uiImage: platformImage).resizable().scaledToFit()
        #else
        Image(nsImage: platformImage).resizable().scaledToFit()
        #endif
    }

    #if os(iOS)
    #if os(iOS)
    /// The overlay bar: share, favourite, information, delete, and the two
    /// slideshows behind More.
    private var viewerActions: some View {
        HStack(spacing: 0) {
            action("Share", "square.and.arrow.up") {
                Task {
                    isWorking = true
                    defer { isWorking = false }
                    guard let data = try? await session.client?.originalData(
                        assetID: item.assetID
                    ) else { return }
                    let name = item.mediaType == .video
                        ? "\(item.assetID.uuidString.prefix(8)).mov"
                        : "\(item.assetID.uuidString.prefix(8)).jpg"
                    let file = FileManager.default.temporaryDirectory
                        .appendingPathComponent(name)
                    try? data.write(to: file)
                    shareFiles = [file]
                    showShare = true
                }
            }
            action(
                "Favorite", model.isFavorite ? "heart.fill" : "heart"
            ) {
                Task { await model.toggleFavorite(session.client) }
            }
            action("Info", "info.circle") { showInfo = true }
            action("Delete", "trash") { confirmDelete = true }

            Menu {
                Button {
                    slideshow = .everything
                } label: {
                    Label(SlideshowMode.everything.title, systemImage: SlideshowMode.everything.symbol)
                }
                Button {
                    slideshow = .videosOnly
                } label: {
                    Label(SlideshowMode.videosOnly.title, systemImage: SlideshowMode.videosOnly.symbol)
                }
                .disabled(!dayItems.contains { $0.mediaType == .video })

                if !session.sharedSpaces.filter({ $0.id != space.id }).isEmpty {
                    Divider()
                    Menu("Add to Shared Space") {
                        ForEach(session.sharedSpaces.filter { $0.id != space.id }) { target in
                            Button(target.name) {
                                Task { await model.addTo(target, client: session.client) }
                            }
                        }
                    }
                }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "ellipsis").font(.system(size: 20))
                    Text("More").font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .disabled(isWorking)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func action(
        _ title: String, _ symbol: String, _ perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 20))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
    #endif

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text(item.capturedAt, format: .dateTime.month(.abbreviated).day().year())
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
        }
    }
    #endif

    private var actionBar: some View {
        HStack(spacing: 34) {
            Button {} label: { Image(systemName: "square.and.arrow.up") }
                .disabled(true)

            Button {
                Task { await model.toggleFavorite(session.client) }
            } label: {
                Image(systemName: model.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(model.isFavorite ? .red : .white)
            }

            Button { showInfo = true } label: {
                Image(systemName: "info.circle")
            }

            // The action neither reference app has: put this photo in a shared
            // space. A row, not a copy — the bytes are already on the NAS.
            if !session.sharedSpaces.isEmpty {
                Menu {
                    ForEach(session.sharedSpaces.filter { $0.id != space.id }) { target in
                        Button {
                            Task { await model.addTo(target, client: session.client) }
                        } label: {
                            Label(target.name, systemImage: "person.2")
                        }
                    }
                } label: {
                    Image(systemName: model.addedTo.isEmpty
                          ? "rectangle.stack.badge.plus"
                          : "rectangle.stack.badge.person.crop.fill")
                }
            }
        }
        .font(.title3)
        .foregroundStyle(.white)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.55))
    }
}

/// Its own `View` on purpose — a body that observes the model, rather than a
/// closure inside `.sheet` that may not.
private struct InformationSheet: View {
    let model: AssetDetailModel
    let session: AppSession
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Information")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                #if !os(tvOS)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
                #endif
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if let detail = model.detail {
            InformationPanel(detail: detail)
        } else if let error = model.detailError {
            ContentUnavailableView {
                Label("Couldn't load details", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") {
                    Task {
                        if let client = session.client { await model.loadDetail(client) }
                    }
                }
            }
        } else {
            ProgressView("Loading details…")
        }
    }
}
