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
    /// A short confirmation for the edits that change nothing on screen —
    /// rating and tagging both happen entirely inside the Information panel,
    /// so without this they look like they did nothing.
    var notice: String?
    /// Loaded once per photo. In a pager the same model is handed back every
    /// time a page scrolls into view, and without this every swipe past a photo
    /// refetches its preview and its detail.
    private var hasLoaded = false

    let item: TimelineItem
    private let spaceID: UUID

    init(item: TimelineItem, spaceID: UUID) {
        self.item = item
        self.spaceID = spaceID
        self.isFavorite = item.isFavorite
    }

    func load(loader: ThumbnailLoader?, client: FrameStationClient?) async {
        guard !hasLoaded else { return }
        hasLoaded = true

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

    /// Stars, 0–5. Returns 1 when it took, so the sheet can report the same way
    /// it does for a selection of twelve.
    func setRating(_ stars: Int, client: FrameStationClient?) async -> Int {
        guard let client else { return 0 }
        do {
            try await client.setRating(spaceID: spaceID, assetID: item.assetID, stars)
            // Refetched rather than patched locally: the Information panel
            // reads `detail`, and a value edited in two places drifts.
            await loadDetail(client)
            return 1
        } catch {
            return 0
        }
    }

    func editTags(add: [String], remove: [String], client: FrameStationClient?) async -> Int {
        guard let client else { return 0 }
        do {
            _ = try await client.editTags(
                spaceID: spaceID, assetID: item.assetID, add: add, remove: remove
            )
            await loadDetail(client)
            return 1
        } catch {
            return 0
        }
    }

    /// Shows a confirmation and retires it, so the viewer doesn't keep a
    /// message about something that happened a minute ago.
    func flash(_ message: String) async {
        notice = message
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        if notice == message { notice = nil }
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

/// One model per photo, for as long as the viewer is open.
///
/// Deliberately *not* `@Observable`: the viewer reads this on every body pass to
/// find the current page's model, and an observable cache would make each new
/// page invalidate the whole viewer — chrome, pager and all — mid-swipe. The
/// models it hands out are observable, which is where the tracking belongs.
@MainActor
final class ViewerModelCache {
    private var byID: [UUID: AssetDetailModel] = [:]

    func model(for item: TimelineItem, spaceID: UUID) -> AssetDetailModel {
        if let existing = byID[item.id] { return existing }
        let created = AssetDetailModel(item: item, spaceID: spaceID)
        byID[item.id] = created
        return created
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

    /// The other photos from the same day, for the slideshows and for knowing
    /// what "all videos from that day" means.
    var dayItems: [TimelineItem] = []
    /// Everything the grid has loaded, in timeline order — what you swipe
    /// through. It runs past the end of a day on purpose: a photo shouldn't
    /// feel like the last one in the library just because midnight happened.
    var pageItems: [TimelineItem] = []

    @State private var cache = ViewerModelCache()
    @State private var showInfo = false
    #if os(iOS)
    /// Which page is on screen, keyed by placement id.
    @State private var currentID: UUID
    @State private var showChrome = true
    /// True while the open photo is zoomed past its resting size. The chrome
    /// gets out of the way when it is.
    @State private var isZoomed = false
    @State private var confirmDelete = false
    @State private var shareFiles: [URL] = []
    @State private var showShare = false
    @State private var slideshow: SlideshowMode?
    @State private var showTagEditor = false
    @State private var showRatingEditor = false
    @State private var showDateEditor = false
    @State private var isWorking = false
    @Environment(\.dismiss) private var dismiss
    #endif

    init(
        item: TimelineItem,
        space: SpaceDTO,
        session: AppSession,
        dayItems: [TimelineItem] = [],
        pageItems: [TimelineItem] = []
    ) {
        self.item = item
        self.space = space
        self.session = session
        self.dayItems = dayItems
        self.pageItems = pageItems
        #if os(iOS)
        self._currentID = State(initialValue: item.id)
        #endif
    }

    // MARK: - Body

    #if os(iOS)
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            pager
        }
        .navigationBarBackButtonHidden(true)
        // The whole bar goes, not just its background. The back chevron and the
        // date come back as floating controls over the photo, which is what
        // lets the media run edge to edge underneath them.
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .overlay(alignment: .top) {
            if showChrome && !isZoomed { topChrome }
        }
        .overlay(alignment: .bottom) {
            if showChrome && !isZoomed { bottomChrome }
        }
        .overlay { toastLayer }
        .animation(.easeInOut(duration: 0.22), value: showChrome)
        .animation(.easeInOut(duration: 0.22), value: isZoomed)
        .statusBarHidden(!showChrome)
        .fullScreenCover(item: $slideshow) { mode in
            SlideshowView(
                session: session,
                items: dayItems.isEmpty ? [currentItem] : dayItems,
                mode: mode,
                startingAt: currentItem
            ) { slideshow = nil }
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareFiles) }
        .sheet(isPresented: $showInfo) {
            InformationSheet(model: currentModel, session: session) { showInfo = false }
        }
        .sheet(isPresented: $showRatingEditor) {
            RatingSheet(title: subject, current: currentModel.detail?.rating) { stars in
                await currentModel.setRating(stars, client: session.client)
            } onFinished: { done in
                showRatingEditor = false
                if let done { Task { [model = currentModel] in await model.flash(done) } }
            }
        }
        .sheet(isPresented: $showDateEditor) {
            DateTimeEditorSheet(items: [currentItem]) { plan in
                try? await session.client?.setCaptureTimes(spaceID: space.id, items: plan)
            } onFinished: { done in
                showDateEditor = false
                // Popped rather than left open: the photo has moved to another
                // day, so the pager it was opened from no longer contains it
                // where it sits. Better to land back on a correct grid than to
                // keep swiping through a list that has quietly gone stale.
                if done != nil { dismiss() }
            }
        }
        .sheet(isPresented: $showTagEditor) {
            TagEditorSheet(
                session: session, space: space, title: subject,
                current: currentModel.detail?.tags ?? []
            ) { add, remove in
                await currentModel.editTags(add: add, remove: remove, client: session.client)
            } onFinished: { done in
                showTagEditor = false
                if let done { Task { [model = currentModel] in await model.flash(done) } }
            }
        }
        .confirmationDialog(
            "Remove this photo from \(space.name)?",
            isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task { [asset = currentItem] in
                    try? await session.client?.removeAsset(
                        spaceID: space.id, assetID: asset.assetID
                    )
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It stays on this iPhone. On the NAS it moves to #recycle, and backup won't add it again.")
        }
    }
    #else
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AssetPage(
                model: cache.model(for: item, spaceID: space.id),
                session: session,
                isCurrent: true,
                showsChrome: true,
                onSingleTap: {},
                isZoomed: .constant(false)
            )
        }
        .safeAreaInset(edge: .bottom) { actionBar }
        .sheet(isPresented: $showInfo) {
            InformationSheet(
                model: cache.model(for: item, spaceID: space.id),
                session: session
            ) { showInfo = false }
        }
    }
    #endif

    // MARK: - Paging

    #if os(iOS)
    /// What you can swipe between. Falls back through the day to this one photo
    /// so the viewer still opens when it's handed nothing.
    private var pages: [TimelineItem] {
        for candidate in [pageItems, dayItems]
        where candidate.contains(where: { $0.id == item.id }) {
            return candidate
        }
        return [item]
    }

    private var currentItem: TimelineItem {
        pages.first { $0.id == currentID } ?? item
    }

    private var currentModel: AssetDetailModel {
        cache.model(for: currentItem, spaceID: space.id)
    }

    /// `TabView`'s page style rather than a paging `ScrollView`.
    ///
    /// Two reasons, both about the zoom. It lands on the opened photo on the
    /// first layout pass instead of scrolling to it afterwards, and its pan
    /// gesture is a `UIScrollView`'s — so when a photo is zoomed in, UIKit
    /// hands the drag to the photo and only takes it back at the edge of the
    /// content, which is exactly the hand-off Photos has.
    private var pager: some View {
        TabView(selection: $currentID) {
            ForEach(pages) { entry in
                AssetPage(
                    model: cache.model(for: entry, spaceID: space.id),
                    session: session,
                    isCurrent: entry.id == currentID,
                    showsChrome: showChrome,
                    onSingleTap: { showChrome.toggle() },
                    isZoomed: $isZoomed
                )
                .tag(entry.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
        // A photo left zoomed shouldn't hold the pager hostage once you've
        // swiped away from it.
        .onChange(of: currentID) { _, _ in isZoomed = false }
    }
    #endif

    private var subject: String {
        #if os(iOS)
        return currentItem.mediaType == .video ? "This Video" : "This Photo"
        #else
        return item.mediaType == .video ? "This Video" : "This Photo"
        #endif
    }

    // MARK: - Chrome

    #if os(iOS)
    /// One line, whatever last happened: a failure first, then the edits that
    /// leave no trace on screen, then the shared-space confirmation.
    private var toast: String? {
        let model = currentModel
        if let error = model.addError { return error }
        if let notice = model.notice { return notice }
        if !model.addedTo.isEmpty { return "Added to \(model.addedTo.joined(separator: ", "))" }
        return nil
    }

    @ViewBuilder
    private var toastLayer: some View {
        if let toast {
            VStack {
                Spacer()
                Text(toast)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(currentModel.addError == nil ? .white : .orange)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassCapsule(interactive: false)
                    .padding(.bottom, 150)
            }
            .viewerChromeScheme()
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    /// Back on its own, and the actions grouped — the split in screenshot one.
    ///
    /// Separate pieces rather than one bar across the top: a full-width bar
    /// covers the top of the photo, and the whole point of hiding the
    /// navigation bar was to stop doing that.
    private var topChrome: some View {
        HStack(alignment: .top) {
            ViewerButton(symbol: "chevron.left", label: "Back") { dismiss() }

            Spacer()

            // One capsule, two glyphs — the grouping on the right of
            // screenshot one. The glyphs carry no glass of their own.
            HStack(spacing: 0) {
                Button {
                    slideshow = .everything
                } label: {
                    ViewerGlyph(symbol: "play.rectangle", glass: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play slideshow")

                Menu {
                    moreMenuItems
                } label: {
                    ViewerGlyph(symbol: "ellipsis", glass: false)
                }
                .accessibilityLabel("More")
            }
            .glassCapsule()
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .viewerChromeScheme()
        .transition(.opacity)
    }

    /// The date, then four round buttons across the width — screenshot one.
    private var bottomChrome: some View {
        VStack(alignment: .leading, spacing: 16) {
            // A video puts its scrubber on this line instead — elapsed time,
            // the bar, remaining, and mute all need the width, and the date
            // stacked on top of them was exactly the collision it looked like.
            //
            // The row is reserved either way. Dropping it for videos let the
            // four buttons slide down thirty-odd points, so swiping from a
            // photo to a clip jolted the whole bar.
            Group {
                if currentItem.mediaType != .video {
                    Text(
                        currentItem.capturedAt,
                        format: .dateTime.month(.abbreviated).day().year()
                    )
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                    .padding(.leading, 6)
                }
            }
            .frame(height: 20, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)

            GlassGroup(spacing: 20) {
                HStack(spacing: 0) {
                    ViewerButton(symbol: "square.and.arrow.up", label: "Share", action: share)
                        .frame(maxWidth: .infinity)
                    ViewerButton(
                        symbol: currentModel.isFavorite ? "heart.fill" : "heart",
                        label: "Favorite",
                        // The brand red, not the system one. `.red` is
                        // #FF453A — oranger and more saturated than the
                        // #F7605C the icon and every other accent use, and
                        // the two sitting a tab bar apart read as a mistake.
                        tint: currentModel.isFavorite ? .accentColor : .white
                    ) {
                        Task { [model = currentModel] in
                            await model.toggleFavorite(session.client)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    ViewerButton(symbol: "info.circle", label: "Information") {
                        showInfo = true
                    }
                    .frame(maxWidth: .infinity)
                    ViewerButton(symbol: "trash", label: "Remove") {
                        confirmDelete = true
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
        .viewerChromeScheme()
        .disabled(isWorking)
        .transition(.opacity)
    }

    @ViewBuilder
    private var moreMenuItems: some View {
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

        Divider()
        Button {
            showTagEditor = true
        } label: {
            Label("Edit Tags", systemImage: "tag")
        }
        Button {
            showRatingEditor = true
        } label: {
            Label("Edit Rating", systemImage: "star")
        }

        Divider()
        Button {
            showDateEditor = true
        } label: {
            Label("Edit Date & Time", systemImage: "calendar")
        }
        // Photos only. Rotating a video would mean re-encoding it, which is a
        // different and far more expensive thing than correcting a tag.
        if currentItem.mediaType != .video {
            Button {
                rotate(.left)
            } label: {
                Label("Rotate Left", systemImage: "rotate.left")
            }
            Button {
                rotate(.right)
            } label: {
                Label("Rotate Right", systemImage: "rotate.right")
            }
        }

        if !session.sharedSpaces.filter({ $0.id != space.id }).isEmpty {
            Divider()
            Menu("Add to Shared Space") {
                ForEach(session.sharedSpaces.filter { $0.id != space.id }) { target in
                    Button(target.name) {
                        Task { [model = currentModel] in
                            await model.addTo(target, client: session.client)
                        }
                    }
                }
            }
        }
    }

    /// Turns this photo. The thumbnails are regenerated on the NAS, so the grid
    /// catches up over delta sync; the open preview is dropped server-side and
    /// re-renders the right way up on the next view.
    private func rotate(_ rotation: MediaRotation) {
        Task { [asset = currentItem, model = currentModel] in
            guard let result = try? await session.client?.rotate(
                spaceID: space.id, assetIDs: [asset.assetID], rotation
            ), result.updated > 0 else {
                await model.flash("Couldn't rotate this photo.")
                return
            }
            await model.flash("Rotated — the thumbnail will catch up shortly.")
        }
    }

    private func share() {
        Task { [asset = currentItem] in
            isWorking = true
            defer { isWorking = false }
            guard let data = try? await session.client?.originalData(
                assetID: asset.assetID
            ) else { return }
            let name = asset.mediaType == .video
                ? "\(asset.assetID.uuidString.prefix(8)).mov"
                : "\(asset.assetID.uuidString.prefix(8)).jpg"
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent(name)
            try? data.write(to: file)
            shareFiles = [file]
            showShare = true
        }
    }
    #endif

    #if !os(iOS)
    private var actionBar: some View {
        let model = cache.model(for: item, spaceID: space.id)
        return HStack(spacing: 34) {
            Button {} label: { Image(systemName: "square.and.arrow.up") }
                .disabled(true)

            Button {
                Task { await model.toggleFavorite(session.client) }
            } label: {
                Image(systemName: model.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(model.isFavorite ? Color.accentColor : .white)
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
    #endif
}

// MARK: - One page

/// The media for one photo, and nothing else.
///
/// Split out of the viewer so the chrome doesn't redraw when a page's preview
/// lands, and so a page that isn't on screen can tell — a video three swipes
/// away must not be playing.
private struct AssetPage: View {
    let model: AssetDetailModel
    let session: AppSession
    let isCurrent: Bool
    let showsChrome: Bool
    let onSingleTap: () -> Void
    @Binding var isZoomed: Bool

    var body: some View {
        ZStack {
            Color.black

            if model.item.mediaType == .video {
                video
            } else if let shown = model.image ?? model.placeholder {
                // One branch, deliberately. The blurred ThumbHash and the sharp
                // preview used to be two, which meant SwiftUI tore the zoomable
                // scroll view down and built a new one the moment the preview
                // landed — a visible pop rather than a resolve, and it threw
                // away a zoom if you were already pinching.
                //
                // Now the same view is handed a better image (the representable
                // swaps it in place, keeping the zoom) and the blur animates
                // away, so the photo sharpens where it stands.
                // The blur rides in an overlay rather than on the zoomable view
                // itself. A `.blur` left attached keeps an offscreen render pass
                // alive for the whole session — including every frame of a pinch
                // — for the sake of the first quarter second.
                zoomable(shown)
                    .overlay {
                        if model.image == nil, let placeholder = model.placeholder {
                            Image(platformImage: placeholder)
                                .resizable()
                                .scaledToFit()
                                .blur(radius: 14, opaque: true)
                                .ignoresSafeArea()
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.28), value: model.image == nil)
            } else {
                ProgressView().tint(.white)
            }

            if let imageError = model.imageError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(imageError).font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .task { await model.load(loader: session.loader, client: session.client) }
    }

    @ViewBuilder
    private var video: some View {
        #if os(iOS)
        // Only the page you're looking at gets a player. Without this a swipe
        // past three clips leaves three of them playing.
        if isCurrent {
            // The tap goes *in* rather than being wrapped around the outside:
            // the player owns the double-tap skip zones, and a chrome toggle
            // attached out here would win the race and fire on the first tap of
            // every skip.
            VideoPlayerView(
                assetID: model.item.assetID,
                client: session.client,
                poster: model.image ?? model.placeholder,
                showsControls: showsChrome,
                onSingleTap: onSingleTap
            )
            .ignoresSafeArea()
        } else if let poster = model.image ?? model.placeholder {
            Image(platformImage: poster).resizable().scaledToFit()
        }
        #else
        VideoPlayerView(
            assetID: model.item.assetID,
            client: session.client,
            poster: model.image ?? model.placeholder
        )
        #endif
    }

    @ViewBuilder
    private func zoomable(_ platformImage: PlatformImage) -> some View {
        #if os(iOS)
        ZoomableImage(
            image: platformImage,
            isCurrent: isCurrent,
            onZoomChange: { zoomed in
                guard isCurrent else { return }
                withAnimation(.easeInOut(duration: 0.2)) { isZoomed = zoomed }
            },
            onSingleTap: onSingleTap
        )
        .ignoresSafeArea()
        #elseif canImport(UIKit)
        Image(uiImage: platformImage).resizable().scaledToFit()
        #else
        Image(nsImage: platformImage).resizable().scaledToFit()
        #endif
    }
}

// MARK: - Chrome pieces

extension View {
    /// Pins viewer chrome to the dark appearance.
    ///
    /// Glass and materials both sample what's behind them, and over a black
    /// canvas the light variants wash out to near-white. Scoped to the chrome
    /// rather than the whole viewer on purpose: a sheet inherits the presenting
    /// view's environment, so setting this at the root dragged the Information
    /// panel, the tag editor and the rating sheet into dark mode along with it —
    /// on a phone set to light, in a viewer they'd only just opened.
    func viewerChromeScheme() -> some View {
        environment(\.colorScheme, .dark)
    }
}

/// One round glass button, the shape the viewer's controls take.
private struct ViewerButton: View {
    let symbol: String
    let label: String
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ViewerGlyph(symbol: symbol, tint: tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The glyph inside a viewer control, sized so the tap target clears 44pt.
///
/// Separate from the button because a `Menu` needs the glyph without a `Button`
/// wrapped round it, and because of `glass`. The top-right pair sit inside one
/// shared capsule, and glass over glass is not a subtler version of glass — it
/// double-refracts, and the circles show as raised lozenges inside the capsule
/// instead of reading as two icons in one control.
private struct ViewerGlyph: View {
    let symbol: String
    var tint: Color = .white
    /// False when an ancestor already provides the glass.
    var glass: Bool = true

    var body: some View {
        let glyph = Image(systemName: symbol)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 46, height: 46)
            .contentShape(Circle())

        if glass {
            glyph.glassCircle()
        } else {
            glyph
        }
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
