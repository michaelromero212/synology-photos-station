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
    /// Set by "Get Info" in the grid, which means "open this showing its
    /// details" rather than "open this".
    var showsInfoInitially = false

    @State private var cache = ViewerModelCache()
    /// Outlives any one page, which is the point: a video prepared as a
    /// neighbour must still be prepared when you arrive at it.
    @State private var preloader = VideoPreloader()
    @State private var showInfo = false
    #if os(iOS)
    /// Which page is on screen, keyed by placement id.
    ///
    /// Owned by an observable so the hosted pages can watch it themselves. They
    /// are built once and kept, so they cannot learn they've become current
    /// from a rebuilt root view.
    @State private var focus: PagerFocus
    private var currentID: UUID { focus.currentID }
    @State private var showChrome = true
    /// True while the open photo is zoomed past its resting size. The chrome
    /// gets out of the way when it is.
    @State private var isZoomed = false
    @State private var confirmDelete = false
    @State private var shareFiles: [URL] = []
    @State private var showShare = false
    @State private var showSlideshow = false
    @State private var showTagEditor = false
    @State private var showDateEditor = false
    @State private var isWorking = false
    @Environment(\.dismiss) private var dismiss
    #else
    /// What the viewer is showing. A `let` on the outside, but the
    /// next/previous video controls have to be able to move it — there is no
    /// pager on these platforms to do that for them.
    @State private var displayedItem: TimelineItem
    #if os(macOS)
    /// Which page the scroll view has settled on. Separate from
    /// `displayedItem` because the two drive each other in opposite
    /// directions — a swipe moves this, a button moves that.
    @State private var scrolledID: UUID?
    #endif
    #endif

    init(
        item: TimelineItem,
        space: SpaceDTO,
        session: AppSession,
        dayItems: [TimelineItem] = [],
        pageItems: [TimelineItem] = [],
        showsInfoInitially: Bool = false
    ) {
        self.item = item
        self.space = space
        self.session = session
        self.dayItems = dayItems
        self.pageItems = pageItems
        self.showsInfoInitially = showsInfoInitially
        #if os(iOS)
        self._focus = State(initialValue: PagerFocus(currentID: item.id))
        #else
        self._displayedItem = State(initialValue: item)
        #if os(macOS)
        // Set here rather than in `onAppear`: a scroll position assigned after
        // the first layout scrolls there visibly, so opening a photograph from
        // the middle of a day would flick past the ones before it.
        self._scrolledID = State(initialValue: item.id)
        #endif
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
        .fullScreenCover(isPresented: $showSlideshow) {
            SlideshowView(
                session: session,
                items: dayItems.isEmpty ? [currentItem] : dayItems,
                startingAt: currentItem
            ) { showSlideshow = false }
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareFiles) }
        .sheet(isPresented: $showInfo) {
            InformationSheet(model: currentModel, session: session) { showInfo = false }
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
    /// The neighbouring video from the same day.
    ///
    /// `dayItems` rather than a pager's page list, because there is no pager
    /// here — this viewer shows one item and the buttons move it.
    private func adjacentVideo(forward: Bool) -> TimelineItem? {
        guard let position = dayItems.firstIndex(where: { $0.id == displayedItem.id })
        else { return nil }
        let candidates = forward
            ? Array(dayItems[dayItems.index(after: position)...])
            : Array(dayItems[..<position].reversed())
        return candidates.first { $0.mediaType == .video }
    }

    private func goToAdjacentVideo(forward: Bool) {
        guard let target = adjacentVideo(forward: forward) else { return }
        displayedItem = target
    }

    var body: some View {
        // One `#if` around the whole thing, content and modifiers together. Two
        // — one choosing the content, another adding the modifiers — breaks the
        // chain: the compiler closes the expression at the first `#endif` and
        // reads `.toolbar` as a new statement.
        #if os(macOS)
        macPager
        // Actions in the toolbar, and Information as an inspector.
        //
        // Both were a floating bar across the bottom of the picture with a
        // sheet behind the info button — a phone's arrangement, because a phone
        // has no window chrome to put anything in. A Mac does, and Photos uses
        // it: the verbs live along the top, and Get Info slides a panel in from
        // the right that the same button closes again. A sheet took the whole
        // window over to show a caption and a map.
        .toolbar { detailToolbar }
        .inspector(isPresented: $showInfo) {
            InformationSheet(
                model: cache.model(for: displayedItem, spaceID: space.id),
                session: session,
                isInspector: true
            ) { showInfo = false }
            // Keyed to the open photo so a swipe with the panel left open
            // rebuilds it for the new item. Without this the inspector kept
            // showing the photo it opened on while you scrolled past others —
            // the content closure held its first model rather than following
            // `displayedItem`.
            .id(displayedItem.id)
            .inspectorColumnWidth(min: 280, ideal: 320, max: 440)
        }
        .onAppear { if showsInfoInitially { showInfo = true } }
        #else
        // tvOS keeps the bar across the bottom. There is no toolbar to move
        // these into and no pointer to open an inspector with — a remote walks
        // a row of buttons, which is exactly what this is.
        ZStack {
            Color.black.ignoresSafeArea()
            AssetPage(
                model: cache.model(for: displayedItem, spaceID: space.id),
                session: session,
                focus: PagerFocus(currentID: displayedItem.id),
                preloader: preloader,
                showsChrome: true,
                onSingleTap: {},
                isZoomed: .constant(false)
            )
        }
        .safeAreaInset(edge: .bottom) { actionBar }
        .sheet(isPresented: $showInfo) {
            InformationSheet(
                model: cache.model(for: displayedItem, spaceID: space.id),
                session: session
            ) { showInfo = false }
        }
        #endif
    }

    #if os(macOS)

    /// Turns the photo on screen. The NAS regenerates the thumbnail and drops
    /// the cached preview, so the grid catches up over delta sync and the open
    /// view re-renders the right way up.
    ///
    /// A second copy of the iOS one, which lives inside `#if os(iOS)` along
    /// with the whole pager — widening that block to reach one function would
    /// drag the swipe machinery onto a platform that cannot swipe.
    private func rotateDisplayed(_ rotation: MediaRotation) {
        Task { [asset = displayedItem] in
            _ = try? await session.client?.rotate(
                spaceID: space.id, assetIDs: [asset.assetID], rotation
            )
        }
    }

    /// The capture stamp as the file recorded it, split into a day line and a
    /// time line for the toolbar.
    ///
    /// Formatted in UTC on purpose: `capturedAt` is the local wall clock stored
    /// as a UTC instant (the timeline's `local_captured_at AT TIME ZONE 'UTC'`),
    /// so reading it back in UTC recovers the time the photo says it was taken —
    /// matching the Information panel rather than shifting by the viewer's zone.
    private static func macStamp(_ date: Date) -> (day: String, time: String) {
        (macDayFormatter.string(from: date), macTimeFormatter.string(from: date))
    }

    private static let macDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    private static let macTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        let model = cache.model(for: displayedItem, spaceID: space.id)

        // Capture date and time, centred — the one thing the Mac viewer had no
        // room for before. The phone shows it in the bottom chrome; a window
        // shows it in the title area, which is what `.principal` is. Follows the
        // swipe because it reads `displayedItem`, and reads the item's own
        // stamp rather than waiting on the detail fetch.
        ToolbarItem(placement: .principal) {
            let stamp = Self.macStamp(displayedItem.capturedAt)
            VStack(spacing: 0) {
                Text(stamp.day)
                    .font(.subheadline.weight(.semibold))
                Text(stamp.time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help("Taken \(stamp.day) at \(stamp.time)")
        }

        // Only while watching a video — on a photo they would have nothing to
        // say. A Mac has no swipe, so what a phone does with a flick needs a
        // button.
        if displayedItem.mediaType == .video {
            ToolbarItem(placement: .navigation) {
                Button {
                    goToAdjacentVideo(forward: false)
                } label: {
                    Label("Previous Video", systemImage: "backward.end")
                }
                .disabled(adjacentVideo(forward: false) == nil)
                .help("Previous video from this day")
                .keyboardShortcut(.leftArrow, modifiers: .command)
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    goToAdjacentVideo(forward: true)
                } label: {
                    Label("Next Video", systemImage: "forward.end")
                }
                .disabled(adjacentVideo(forward: true) == nil)
                .help("Next video from this day")
                .keyboardShortcut(.rightArrow, modifiers: .command)
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                rotateDisplayed(.left)
            } label: {
                Label("Rotate Left", systemImage: "rotate.left")
            }
            .help("Rotate left")
            .disabled(displayedItem.mediaType == .video)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                rotateDisplayed(.right)
            } label: {
                Label("Rotate Right", systemImage: "rotate.right")
            }
            .help("Rotate right")
            .disabled(displayedItem.mediaType == .video)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.toggleFavorite(session.client) }
            } label: {
                Label(
                    model.isFavorite ? "Unfavourite" : "Favourite",
                    systemImage: model.isFavorite ? "heart.fill" : "heart"
                )
            }
            .help(model.isFavorite ? "Remove from favourites" : "Add to favourites")
        }

        // The action neither reference app has: put this photo in a shared
        // space. A row, not a copy — the bytes are already on the NAS.
        if !session.sharedSpaces.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(session.sharedSpaces.filter { $0.id != space.id }) { target in
                        Button {
                            Task { await model.addTo(target, client: session.client) }
                        } label: {
                            Label(target.name, systemImage: "person.2")
                        }
                    }
                } label: {
                    Label("Add to Shared Space", systemImage: model.addedTo.isEmpty
                          ? "rectangle.stack.badge.plus"
                          : "rectangle.stack.badge.person.crop.fill")
                }
                .help("Add to a shared space")
            }
        }

        // Last, and a toggle: it is the only one of these that leaves something
        // on screen, so it reads as a state rather than an action.
        ToolbarItem(placement: .primaryAction) {
            Button {
                showInfo.toggle()
            } label: {
                Label("Information", systemImage: "info.circle")
            }
            .help("Show information")
            .keyboardShortcut("i", modifiers: .command)
        }
    }
    #endif
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

    /// Continues to the next video from the same day once one finishes.
    ///
    /// Videos only: skipping the photos in between is the whole point, and it
    /// is what the old "Play All Videos" mode did — just reached by watching
    /// rather than by choosing it from a menu first.
    ///
    /// Guarded on the finished page still being the one on screen. A clip that
    /// ends a moment after you have already swiped away must not drag the
    /// viewer somewhere you didn't ask to go.
    private func advanceToNextVideo(after finished: TimelineItem) {
        guard PlaybackSettings.autoPlayNextVideo, finished.id == currentID else { return }
        guard let next = nextVideoID(after: finished.id) else { return }
        focus.currentID = next
    }

    /// Stops at the end of the day by returning nil — the last clip stays on
    /// screen where it finished, rather than rolling into yesterday.
    private func nextVideoID(after id: UUID) -> UUID? {
        videoID(from: id, forward: true)
    }

    /// The neighbouring video in the same day, skipping the photos between.
    ///
    /// Skipping them is the point: the horizontal swipe already walks every
    /// item in order, video to photo to video, and that stays exactly as it
    /// was. This is the other thing people want from a day with four clips in
    /// it — the next *clip*, without scrolling past the thirty stills.
    private func videoID(from id: UUID, forward: Bool) -> UUID? {
        let all = pages
        guard let position = all.firstIndex(where: { $0.id == id }) else { return nil }
        let sameDay = sameDayIDs()
        let candidates = forward
            ? Array(all[all.index(after: position)...])
            : Array(all[..<position].reversed())
        return candidates.first { $0.mediaType == .video && sameDay.contains($0.id) }?.id
    }

    /// Whether there is another clip ahead, so the skip control can stay hidden
    /// on the last one rather than doing nothing when pressed.
    private var hasNextVideo: Bool { nextVideoID(after: currentID) != nil }

    private func goToAdjacentVideo(forward: Bool) {
        guard currentItem.mediaType == .video else { return }
        guard let target = videoID(from: currentID, forward: forward) else { return }
        focus.currentID = target
    }

    /// `dayItems` when the grid supplied it. The fallback matters for the
    /// routes that don't — an album, or a viewer opened with only a page list —
    /// where "the same day" still has an obvious meaning.
    private func sameDayIDs() -> Set<UUID> {
        if !dayItems.isEmpty { return Set(dayItems.map(\.id)) }
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: currentItem.capturedAt)
        return Set(
            pages.filter { calendar.startOfDay(for: $0.capturedAt) == day }.map(\.id)
        )
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
        PagerView(items: pages, focus: focus) { entry in
            AssetPage(
                model: cache.model(for: entry, spaceID: space.id),
                session: session,
                focus: focus,
                preloader: preloader,
                showsChrome: showChrome,
                onSingleTap: { showChrome.toggle() },
                onFinished: { advanceToNextVideo(after: entry) },
                isZoomed: $isZoomed
            )
        }
        .ignoresSafeArea()
        // A photo left zoomed shouldn't hold the pager hostage once you've
        // swiped away from it.
        .onChange(of: currentID) { _, _ in
            isZoomed = false
            // Whatever you just left stops. Nil on a photo, so swiping from a
            // clip to a still silences it too.
            preloader.playOnly(
                currentItem.mediaType == .video ? currentItem.assetID : nil
            )
        }
        // No vertical gesture here on purpose. This briefly had swipe-up for
        // the next clip and swipe-down for the previous, which is the Reels
        // convention, not Photos': there, up opens the info panel and down
        // dismisses the viewer. Claiming those would cost two gestures people
        // already know to buy one this app invented. Skipping to the next clip
        // is a button in the chrome instead.
    }
    #endif

    #if os(macOS)
    /// What a swipe walks through: everything the grid had loaded, falling back
    /// through the day to this one photograph. The same rule the phone's pager
    /// uses, so a swipe covers the same run on both.
    private var macPages: [TimelineItem] {
        for candidate in [pageItems, dayItems]
        where candidate.contains(where: { $0.id == item.id }) {
            return candidate
        }
        return [item]
    }

    /// Two fingers, left or right.
    ///
    /// A paging `ScrollView` rather than a swipe gesture, because on a Mac a
    /// two-finger swipe *is* a scroll: the trackpad sends scroll events, not
    /// drags, so a `DragGesture` would never see one. Handing the run of
    /// photographs to a horizontal scroll view lets AppKit's own momentum and
    /// rubber-banding carry the motion — nothing is interpreted and
    /// re-animated on top of the fingers, which is what makes it feel immediate.
    ///
    /// Lazy on purpose: a day of four hundred photographs would otherwise build
    /// four hundred image views before showing the one you opened.
    /// The black gap between two photographs mid-swipe.
    ///
    /// Small on purpose. This is horizontal padding inside each page (see the
    /// note on `macPager`), so half of it also shows as a resting inset — and a
    /// wide one read as a cheap border sitting around the photo rather than a
    /// clean full-bleed. At `24` the resting inset is 12 pt, enough to keep the
    /// picture off the sidebar's glass and no more, while a swipe still parts
    /// two pictures by a visible gutter.
    static let pageGap: CGFloat = 24

    private var macPager: some View {
        // Apple's viewer: the photograph fills the whole main area, and a small
        // gap parts two pictures as you swipe.
        //
        // Each page is sized to the visible region on *both* axes with
        // `containerRelativeFrame` — width so paging snaps one screen at a time,
        // and height so the picture fills top to bottom. Width alone was the
        // bug: a horizontal `ScrollView` leaves the cross axis to the content,
        // so each page collapsed to the image's fitted height and left a gulf of
        // black beneath it — the single thing that made this look half-finished
        // next to Photos. No `GeometryReader`: that measured the whole window
        // and let pictures bleed under the sidebar.
        //
        // The gap is horizontal padding *inside* each page, not spacing between
        // them, because `.paging` snaps by the viewport and would drift by the
        // spacing otherwise. So each page stays exactly one screen wide, paging
        // lands cleanly on one picture (first open included, no neighbour
        // creeping in), and the gap shows as `pageGap` of black between two
        // pictures mid-swipe — a thin `pageGap`-half inset at rest.
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(macPages) { page in
                    AssetPage(
                        model: cache.model(for: page, spaceID: space.id),
                        session: session,
                        focus: PagerFocus(currentID: page.id),
                        preloader: preloader,
                        showsChrome: true,
                        onSingleTap: {},
                        isZoomed: .constant(false)
                    )
                    .padding(.horizontal, Self.pageGap / 2)
                    .containerRelativeFrame([.horizontal, .vertical])
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrolledID)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.black)
        .onChange(of: scrolledID) { _, new in
            guard let new, new != displayedItem.id,
                  let match = macPages.first(where: { $0.id == new }) else { return }
            displayedItem = match
        }
        .onChange(of: displayedItem.id) { _, new in
            if scrolledID != new { scrolledID = new }
            warmNeighbours(around: new)
        }
        // Warm the pictures on either side of the one opened, so the very first
        // swipe is smooth rather than the only rough one.
        .onAppear { warmNeighbours(around: displayedItem.id) }
    }

    /// Decodes the photographs on either side of the one shown before a swipe
    /// reaches them.
    ///
    /// The jank was image arrival, not the scroll: `LazyHStack` builds the next
    /// page only as it slides in, so its `.task` fetched the 2048 px preview
    /// mid-swipe and the picture popped from ThumbHash blur to sharp in the
    /// middle of the transition. Loading the neighbours' models now — the same
    /// models the pages will use, since `ViewerModelCache` hands back one per
    /// item — means the image is already decoded and set when the page appears,
    /// so it slides in whole.
    ///
    /// `load()` guards itself with `hasLoaded`, so warming a neighbour twice (or
    /// warming one that is already the current page) costs nothing. A window of
    /// two each way keeps a run of quick swipes ahead of the fingers.
    private func warmNeighbours(around id: UUID) {
        guard let index = macPages.firstIndex(where: { $0.id == id }) else { return }
        for offset in [-2, -1, 1, 2] {
            let neighbour = index + offset
            guard macPages.indices.contains(neighbour) else { continue }
            let model = cache.model(for: macPages[neighbour], spaceID: space.id)
            Task { await model.load(loader: session.loader, client: session.client) }
        }
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
                    showSlideshow = true
                } label: {
                    ViewerGlyph(symbol: "play.rectangle", glass: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play slideshow")

                // Only while watching a clip that has another after it. A
                // button rather than a gesture: Photos spends up on the info
                // panel and down on dismissing, and neither is worth trading
                // for a skip. One tap, in the chrome that is already open.
                if currentItem.mediaType == .video, hasNextVideo {
                    Button {
                        goToAdjacentVideo(forward: true)
                    } label: {
                        ViewerGlyph(symbol: "forward.end", glass: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next video from this day")
                }

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
            showSlideshow = true
        } label: {
            Label("Slideshow", systemImage: "play.rectangle")
        }

        Divider()
        Button {
            showTagEditor = true
        } label: {
            Label("Edit Tags", systemImage: "tag")
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
        let model = cache.model(for: displayedItem, spaceID: space.id)
        return HStack(spacing: 34) {
            // No swipe on a Mac or an Apple TV, so the thing an iPhone does
            // with a flick needs a button here. Only while watching a video —
            // on a photo they would have nothing to say.
            if displayedItem.mediaType == .video {
                Button {
                    goToAdjacentVideo(forward: false)
                } label: {
                    Image(systemName: "backward.end")
                }
                .disabled(adjacentVideo(forward: false) == nil)
                .help("Previous video from this day")
                #if os(macOS)
                .keyboardShortcut(.leftArrow, modifiers: .command)
                #endif

                Button {
                    goToAdjacentVideo(forward: true)
                } label: {
                    Image(systemName: "forward.end")
                }
                .disabled(adjacentVideo(forward: true) == nil)
                .help("Next video from this day")
                #if os(macOS)
                .keyboardShortcut(.rightArrow, modifiers: .command)
                #endif
            }

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
    /// Read rather than passed in: this page is hosted in a view controller
    /// that outlives any one render, so a flag baked in at build time would
    /// still say "not current" long after the pager arrived here.
    let focus: PagerFocus
    let preloader: VideoPreloader
    let showsChrome: Bool
    let onSingleTap: () -> Void
    var onFinished: () -> Void = {}
    @Binding var isZoomed: Bool

    private var isCurrent: Bool { focus.currentID == model.item.id }

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
        // Only the page you're looking at gets a *layer*. A neighbour still
        // prepares — see the `task` below — but rendering three video layers to
        // have two of them offscreen costs GPU for nothing.
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
                onSingleTap: onSingleTap,
                onFinished: onFinished,
                isActive: true,
                model: preloader.model(for: model.item.assetID)
            )
            .ignoresSafeArea()
        } else if let poster = model.image ?? model.placeholder {
            // Built ahead by the pager and not being watched. Show the poster,
            // but get the bytes moving: this is the page you are one swipe —
            // or one finished clip — away from.
            Image(platformImage: poster).resizable().scaledToFit()
                .task { preloader.warm(assetID: model.item.assetID, client: session.client) }
        }
        #else
        VideoPlayerView(
            assetID: model.item.assetID,
            client: session.client,
            poster: model.image ?? model.placeholder,
            model: preloader.model(for: model.item.assetID)
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
    /// Rendered as a Mac inspector rather than a sheet: no navigation stack, no
    /// Done button, no stated size. The toolbar's info button is what opens and
    /// closes it, so a second dismissal inside the panel would be a control that
    /// competes with the one the user just pressed.
    var isInspector = false
    let onDone: () -> Void

    @State private var showCreditEditor = false
    @State private var showLocationEditor = false

    var body: some View {
        if isInspector {
            content
        } else {
            sheetBody
        }
    }

    private var sheetBody: some View {
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
            #if !os(tvOS)
            // Only where a correction can actually be applied: a shared space,
            // where more than one person's photos are mixed together and the
            // name on one can be wrong.
            InformationPanel(
                detail: detail,
                onEditCredit: detail.isSharedSpace ? { showCreditEditor = true } : nil,
                onEditLocation: { showLocationEditor = true }
            )
            .sheet(isPresented: $showLocationEditor) {
                LocationEditorSheet(
                    session: session,
                    spaceID: detail.spaceID,
                    assetID: detail.assetID,
                    current: detail.latitude.flatMap { lat in
                        detail.longitude.map { (latitude: lat, longitude: $0) }
                    },
                    currentName: detail.placeName
                ) { changed in
                    showLocationEditor = false
                    // Re-read: the server decides the place name, and the panel
                    // should show the words search will actually match.
                    if changed, let client = session.client {
                        Task { await model.loadDetail(client) }
                    }
                }
            }
            .sheet(isPresented: $showCreditEditor) {
                CreditEditorSheet(
                    session: session,
                    spaceID: detail.spaceID,
                    assetIDs: [detail.assetID],
                    currentName: detail.uploadedBy.displayName
                ) { changed in
                    showCreditEditor = false
                    // Re-read rather than patch locally: the server decides what
                    // the effective credit is, and guessing here is how the panel
                    // and the grid end up disagreeing.
                    if changed, let client = session.client {
                        Task { await model.loadDetail(client) }
                    }
                }
            }
            #else
            InformationPanel(detail: detail)
            #endif
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
