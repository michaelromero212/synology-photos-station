#if !os(tvOS)
import FrameStationAPI
import FrameStationKit
import SwiftUI

/// Something in Recently Deleted, full size, with what can be done about it:
/// put it back, or delete it for good.
///
/// Its own viewer rather than the library's. Everything the library's viewer
/// offers — sharing, favorites, editing, albums — waits until the photo is back
/// where it was, and this one's two buttons belong nowhere else. Laid out the
/// way Photos lays out the same screen: swipe through what's here, the days
/// left with Delete and Recover along the bottom.
///
/// Only against a NAS that serves these: see `ServerCapability.deletedPreview`.
struct DeletedItemViewer: View {
    @Bindable var session: AppSession
    /// Whether this person may recover and delete here. Someone who can only
    /// view a library can look, as they can on the page under this.
    let canEdit: Bool
    /// Both throw what went wrong, which this says over the bar.
    let onRecover: (TimelineItem) async throws -> Void
    let onDelete: (TimelineItem) async throws -> Void
    let onDone: () -> Void

    /// What's here, in the page's order. What's recovered or deleted from this
    /// screen leaves it at once, and the next item takes its place.
    @State private var items: [TimelineItem]
    @State private var currentID: UUID?
    /// Outlives the pages, so a clip swiped away from and back to keeps its
    /// place. See `VideoPreloader`.
    @State private var preloader = VideoPreloader()
    @State private var showsChrome = true
    @State private var confirmDelete = false
    @State private var isWorking = false
    @State private var failure: String?

    init(
        session: AppSession, items: [TimelineItem], opening item: TimelineItem,
        canEdit: Bool,
        onRecover: @escaping (TimelineItem) async throws -> Void,
        onDelete: @escaping (TimelineItem) async throws -> Void,
        onDone: @escaping () -> Void
    ) {
        self.session = session
        self.canEdit = canEdit
        self.onRecover = onRecover
        self.onDelete = onDelete
        self.onDone = onDone
        _items = State(initialValue: items)
        _currentID = State(initialValue: item.id)
    }

    private var current: TimelineItem? {
        items.first { $0.id == currentID } ?? items.first
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            pages
        }
        .overlay {
            if showsChrome { chrome.transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.2), value: showsChrome)
        .viewerChromeScheme()
        #if os(iOS)
        .statusBarHidden(!showsChrome)
        // Full screen over the app, so it would take the popups' solid style;
        // its glass matches the viewer's instead. See `PopupContrast`.
        .standardContrast()
        #endif
        // The clip on screen claims the connection and the rest pause, as in
        // the library's viewer.
        .onChange(of: currentID, initial: true) { _, _ in
            failure = nil
            preloader.playOnly(current?.mediaType == .video ? current?.assetID : nil)
        }
        .confirmationDialog(
            current?.mediaType == .video
                ? "Delete this video permanently?" : "Delete this photo permanently?",
            isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) { act(onDelete) }
        } message: {
            Text("This can't be undone. It's removed from your NAS right away, without "
                + "waiting out the \(Retention.days)-day window.")
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private var pages: some View {
        #if os(iOS)
        TabView(selection: $currentID) {
            ForEach(items) { item in
                DeletedItemPage(
                    item: item, session: session, isCurrent: item.id == current?.id,
                    preloader: preloader, onTap: { showsChrome.toggle() }
                )
                .tag(Optional(item.id))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
        #else
        // No paging scroll view on a Mac: one at a time, with the arrow keys
        // and the buttons in the bar.
        if let current {
            DeletedItemPage(
                item: current, session: session, isCurrent: true,
                preloader: preloader, onTap: { showsChrome.toggle() }
            )
            .id(current.id)
        }
        #endif
    }

    // MARK: - Chrome

    private var chrome: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
            #if os(iOS)
            if let current, current.mediaType == .video,
               let player = preloader.existing(current.assetID) {
                VideoControls(model: player)
            }
            #endif
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: onDone) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .contentShape(Circle())
                    .glassCircle(tint: .viewerGlassTint)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Back")

            Spacer()

            if let current {
                Text(current.capturedAt, format: .dateTime.month(.abbreviated).day().year())
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .glassCapsule(tint: .viewerGlassTint, interactive: false)
            }

            Spacer()

            #if os(macOS)
            HStack(spacing: 0) {
                step(by: -1, symbol: "chevron.backward", label: "Previous", key: .leftArrow)
                step(by: 1, symbol: "chevron.forward", label: "Next", key: .rightArrow)
            }
            .glassCapsule(tint: .viewerGlassTint)
            #else
            // The back button's width, so the date sits in the middle.
            Color.clear.frame(width: 46, height: 46)
            #endif
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    /// Delete on the left, Recover on the right, the days left between them —
    /// the arrangement of the page under this, and of Photos.
    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassCapsule(tint: .viewerGlassTint, interactive: false)
            }
            HStack(spacing: 0) {
                if canEdit {
                    Button("Delete") { confirmDelete = true }
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                }
                Group {
                    if isWorking {
                        ProgressView().tint(.white)
                    } else if let days = current?.daysUntilPurge {
                        Text(days == 1 ? "1 day" : "\(days) days")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(days <= 7 ? AnyShapeStyle(.orange) : AnyShapeStyle(.white))
                            .accessibilityLabel(
                                days == 1 ? "Deleted forever in 1 day"
                                    : "Deleted forever in \(days) days"
                            )
                    }
                }
                .frame(maxWidth: .infinity)
                if canEdit {
                    Button("Recover") { act(onRecover) }
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 14)
            .glassCapsule(tint: .viewerGlassTint, interactive: false)
            .disabled(isWorking || current == nil)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    #if os(macOS)
    private func step(
        by offset: Int, symbol: String, label: String, key: KeyEquivalent
    ) -> some View {
        let index = items.firstIndex { $0.id == current?.id } ?? 0
        let target = index + offset
        return Button {
            currentID = items[target].id
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 42, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: [])
        .disabled(!items.indices.contains(target))
        .accessibilityLabel(label)
    }
    #endif

    /// Recovers or deletes what's on screen, then shows the next item, or
    /// closes when there's nothing left.
    private func act(_ action: @escaping (TimelineItem) async throws -> Void) {
        guard let item = current, !isWorking else { return }
        isWorking = true
        failure = nil
        Task {
            defer { isWorking = false }
            do {
                try await action(item)
            } catch {
                failure = error.localizedDescription
                return
            }
            let index = items.firstIndex { $0.id == item.id } ?? 0
            items.removeAll { $0.id == item.id }
            guard !items.isEmpty else {
                onDone()
                return
            }
            currentID = items[min(index, items.count - 1)].id
        }
    }
}

/// One item: the photo, as large as the server makes it, or the video.
private struct DeletedItemPage: View {
    let item: TimelineItem
    let session: AppSession
    let isCurrent: Bool
    let preloader: VideoPreloader
    let onTap: () -> Void

    /// The 512 at once, then for a photo the full-size preview over it. A
    /// clip's poster is the 512.
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            Color.black
            if item.mediaType == .video {
                video
            } else if let image {
                photo(image)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: item.id) { await load() }
        // Claimed in a task, never in the body: claiming changes what the
        // body reads, and the library's viewer once froze doing it there.
        // See `AssetPage.claimClip`.
        .task(id: isCurrent) {
            if isCurrent, item.mediaType == .video { _ = preloader.model(for: item.assetID) }
        }
    }

    @ViewBuilder
    private var video: some View {
        if isCurrent, let model = preloader.existing(item.assetID) {
            #if os(iOS)
            VideoPlayerView(
                assetID: item.assetID, client: session.client, poster: image,
                onSingleTap: onTap, isActive: true, model: model
            )
            .ignoresSafeArea()
            #else
            VideoPlayerView(
                assetID: item.assetID, client: session.client, poster: image, model: model
            )
            #endif
        } else if let image {
            Image(platformImage: image).resizable().scaledToFit()
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
        } else {
            ProgressView().tint(.white)
        }
    }

    @ViewBuilder
    private func photo(_ image: PlatformImage) -> some View {
        #if os(iOS)
        ZoomableImage(image: image, isCurrent: isCurrent, onSingleTap: onTap)
            .ignoresSafeArea()
        #else
        Image(platformImage: image).resizable().scaledToFit()
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
        #endif
    }

    private func load() async {
        guard let loader = session.loader else { return }
        if image == nil, let small = await loader.thumbnail(assetID: item.assetID, size: 512) {
            image = small
        }
        guard item.mediaType != .video,
              let full = await loader.preview(assetID: item.assetID) else { return }
        image = full
    }
}
#endif
