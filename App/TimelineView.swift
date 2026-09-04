#if os(macOS)
import AppKit
#endif
import FrameStationAPI
import FrameStationKit
import SwiftUI

/// The library grid.
///
/// Sections come straight from the manifest, so the scroll view knows how many
/// sections exist and how many cells each holds before any bucket is fetched.
/// Bucket contents load when a section scrolls into view.
///
/// Note for scale: this is a sectioned `LazyVGrid`, which behaves well because
/// only visible buckets are ever materialised. ARCHITECTURE.md §9a still calls
/// for a `UICollectionView` before this meets a 100k library — one flat lazy
/// grid at that size stutters, and prefetching needs real control.
// Shared with macOS since the Mac grid stopped using NavigationLink: a hold
// has to mean "select" there, so navigation is driven from state on both.
#if !os(tvOS)
/// A tapped photo together with the context the viewer needs.
///
/// The three used to be separate `@State` properties, with the destination
/// closure reading two of them off the view while only the third drove
/// presentation. That closure is captured, so it could run a render behind the
/// state it was reading: the viewer opened knowing about one photo, with no day
/// and no page list. Swiping did nothing, the slideshow played a single frame,
/// and nothing anywhere said why.
///
/// Travelling as one value makes that impossible — the destination receives
/// the context as its argument rather than looking it up.
struct OpenedPhoto: Identifiable, Hashable {
    let item: TimelineItem
    let dayItems: [TimelineItem]
    let pageItems: [TimelineItem]
    /// Opens with the Information inspector already showing. "Get Info" in the
    /// grid's menu means exactly that, and asking someone to open the photo and
    /// then press a second button would be two steps for one intention.
    var showsInfo = false

    var id: UUID { item.id }
}
#endif

struct TimelineView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO
    #if os(iOS)
    /// Owned by RootTabView so every tab reads the same backup state.
    let engine: BackupEngine?
    @Binding var backupSettings: BackupSettings
    #endif
    /// A control for changing which space is shown, put in the title's place.
    ///
    /// Supplied by the host rather than built here, because the grid has no
    /// business knowing what else it could be showing — the Shared tab knows
    /// which spaces exist, and the personal tab has nothing to switch between.
    ///
    /// It lives here rather than being wrapped around this view from outside so
    /// that it can be withdrawn during a selection: the title belongs to the
    /// count then, and a space switcher would both fight it for the slot and
    /// offer to navigate away mid-selection.
    var spaceSwitcher: AnyView?
    /// Told where a selection went, so the host can follow it there.
    ///
    /// The grid can share photos but cannot navigate to the result — it only
    /// knows the space it is showing. The Shared tab owns which space is on
    /// screen, so it is the thing that can land you in the destination.
    ///
    /// Carries the source alongside the destination ids: the originals stay put
    /// now, and offering to remove them later means knowing which they were.
    #if os(iOS)
    var onShared: ((SpaceDTO, ShareAssetsResponse, SpaceDTO) -> Void)?
    /// Items that have just landed in this space, offered for checking.
    ///
    /// Passed in rather than owned here because the sharing happens in the space
    /// being left, and this is the space being arrived at — two different
    /// instances of this view.
    var review: MoveReview?
    /// Dismisses the review bar. Held by the host for the same reason.
    var onReviewDone: (() -> Void)?
    /// Clears the originals out of the space they were shared from. Held by the
    /// host because the source is a different space from this one.
    var onRemoveOriginals: (() -> Void)?
    #endif

    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// Whether there is room for a labelled rail rather than a bare scrubber.
    ///
    /// Size class rather than idiom: an iPad in a narrow split view is a phone
    /// as far as available width is concerned, and a rail that eats sixty
    /// points of a third-width column would be taking them from the grid.
    private var wantsRail: Bool {
        #if os(macOS)
        return true
        #elseif os(iOS)
        return sizeClass == .regular
        #else
        return false
        #endif
    }
    /// Ties a tapped tile to the viewer it grows into. Both ends must name the
    /// same namespace or the system falls back to a push without saying so.
    @Namespace private var photoTransition
    @State private var store: TimelineStore?
    /// What the date editor is about to act on. Held here rather than read off
    /// the selection because macOS has no multi-select — there it's whichever
    /// one photo was right-clicked — and one sheet serving both is better than
    /// two that drift.
    @State private var editingItems: [TimelineItem] = []
    @State private var showDateEditor = false
    /// Follows the zoom — see TimelineZoom.columns.
    private var columns: Int { (store?.zoom ?? .day).columns }
    @State private var activity: ActivityStore?
    @State private var showActivity = false
    @State private var showSpaces = false
    #if os(macOS)
    /// Files on their way up from this Mac. No automatic backup and no Focused
    /// Backup here — a Mac is not suspended out from under a transfer, and it
    /// has no photo library of its own to sweep.
    @State private var macUploads = MacUploads()
    @State private var showFileImporter = false
    @State private var isDropTargeted = false
    @State private var showUploadQueue = false
    /// When and where the last click landed, so a second one on the same tile
    /// can be read as a double-click without a gesture that delays the first.
    @State private var lastClickAt = Date.distantPast
    @State private var lastClickedID: UUID?
    #endif
    #if os(iOS)
    @State private var showBackup = false
    /// Dismissing the "not enabled" card lasts for the session, not forever:
    /// the next launch asks once more, because an un-backed-up library is
    /// worth one reminder a day.
    @State private var dismissedBackupPrompt = false
    @State private var showBackupSettings = false
    @State private var showFocusedBackup = false
    @State private var showPicker = false
    @State private var showSearch = false
    @State private var showMoveTo = false
    @State private var moveError: String?
    /// Owned by RootTabView, read here because this is where a broken
    /// connection has to be visible.
    @Environment(\.connectionMonitor) private var connection
    #endif

    // Selecting photos, and everything that acts on a selection. Not iOS-only:
    // a Mac has more room for a contact sheet than anything else does, and
    // "select these forty and re-date them" is the case it is best at.
    #if !os(tvOS)
    @State private var showAddToAlbum = false
    @State private var showTagEditor = false
    @State private var albumResult: String?
    @State private var selection = GridSelection()
    @State private var shareFiles: [URL] = []
    @State private var showShare = false
    @State private var confirmDelete = false
    #endif

    private let spacing: CGFloat = PhotoGridMetrics.spacing
    /// Held, not read. The grid hands this to the fast scroller and to the
    /// reporter and never touches `.fraction` itself — see `ScrollProgress`.
    @State private var scrollProgress = ScrollProgress()
    /// The section currently at the top of the viewport, bound to the scroll
    /// view so it both reports and drives. Written a handful of times per
    /// scroll — once per section boundary crossed — which is why this can be
    /// ordinary `@State` where `ScrollProgress.fraction` could not be.
    @State private var topBucket: String?
    #if !os(tvOS)
    /// The photo a tap opened, the day it came from — the slideshows need to
    /// know what "that day" contained — and everything currently loaded, which
    /// is what the viewer swipes through.
    @State private var openItem: OpenedPhoto?
    #endif

    var body: some View {
        VStack(spacing: 0) {
            // Only when there's no grid to carry it. The banner rides at the
            // top of the scroll content instead, so it scrolls away with the
            // photos — pinning it here and hiding it on scroll instead was
            // worse than it sounds: it resized the scroll container mid-gesture
            // and the grid snapped back to the top.
            //
            // The original reason it sat outside still holds, though, which is
            // why it stays here in every other state: the answer to "is my
            // phone backed up?" must not depend on the library having photos in
            // it yet, and an empty library has nothing to scroll.
            #if os(iOS)
            if let engine, !showsGrid {
                backupBanner(engine)
                    .animation(.easeOut(duration: 0.2), value: connection?.state)
            }
            #endif

            Group {
                if let store {
                    content(store)
                } else {
                    ProgressView()
                }
            }
            .frame(maxHeight: .infinity)
        }
        // The count takes the title while selecting. It used to sit in the
        // leading slot beside the space name, which left two pieces of text
        // competing for one bar and both of them truncated — "8…" next to
        // "Family Sh…" tells you neither how many nor where.
        .navigationTitle(selectionTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbar }
        #if os(macOS)
        .modifier(macChrome)
        #endif
        #if os(iOS)
        // Scrolling into the library stands the whole bar down — title and
        // icons both — leaving the pinned date as the only thing across the
        // top, and scrolling back brings it up. Deliberately un-animated: an
        // explicit `.animation` on this drove the bar up past the status bar
        // and lurched the grid with it. The navigation controller's own
        // transition is the one that looks right.
        //
        // Never while selecting, though: the count and the cancel button live
        // in that bar, and losing them mid-selection strands you.
        .toolbar(
            scrollProgress.chromeHidden && !selection.isActive ? .hidden : .automatic,
            for: .navigationBar
        )
        .navigationDestination(item: $openItem) { opened in
            AssetDetailView(
                item: opened.item, space: space, session: session,
                dayItems: opened.dayItems, pageItems: opened.pageItems
            )
            .photoZoomTransition(id: opened.id, in: photoTransition)
        }
        // The bottom bar stands down on the same signal as the top one, so
        // scrolling into the library leaves nothing but photos — the whole
        // point of letting them run under the glass in the first place is that
        // there is then something worth uncovering.
        //
        // Selecting hides it too, and for a different reason: selection reuses
        // the tab bar's slot rather than stacking a second bar above it, since
        // the actions apply to what you picked and the places you could
        // navigate to are not the question being asked. Which is also why this
        // one hides during selection where the navigation bar does not — that
        // bar is carrying the count and the way out.
        .toolbar(
            selection.isActive || scrollProgress.chromeHidden ? .hidden : .automatic,
            for: .tabBar
        )
        #endif
        .sheet(isPresented: $showSpaces) {
            SpacesView(session: session) { showSpaces = false }
        }
        // Outside the iOS block: correcting a date is one of the few edits
        // macOS can do too, and it is the same sheet either way. Not tvOS —
        // nobody is fixing a timestamp with a remote.
        #if !os(tvOS)
        .sheet(isPresented: $showDateEditor) {
            DateTimeEditorSheet(items: editingItems) { plan in
                try? await session.client?.setCaptureTimes(spaceID: space.id, items: plan)
            } onFinished: { done in
                showDateEditor = false
                editingItems = []
                guard let done else { return }
                #if os(iOS)
                albumResult = done
                selection.clear()
                #endif
                // Re-dated photos belong to other days now, so their buckets
                // are wrong until the manifest is refetched. The one edit where
                // waiting for the next poll would leave a visibly wrong grid.
                Task { await store?.refresh() }
            }
        }
        #endif
        #if !os(tvOS)
        .sheet(isPresented: $showShare, onDismiss: { selection.clear() }) {
            ShareSheet(items: shareFiles)
        }
        .confirmationDialog(
            selection.count == 1
                ? "Remove this photo from \(space.name)?"
                : "Remove \(selection.count) photos from \(space.name)?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task {
                    _ = await selection.remove(from: space, client: session.client)
                    await store?.refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Say what removal actually does. It is not a deletion from the
            // phone, and it is not permanent on the NAS either.
            #if os(iOS)
            Text("They stay on this iPhone. On the NAS they move to #recycle, and backup won't add them again.")
            #else
            Text("On the NAS they move to #recycle. Nothing is removed from anyone's phone.")
            #endif
        }
        #endif
        #if os(iOS)
        // No confirmation when the sheet closes. The photos appearing in the
        // grid behind it *is* the confirmation, and an alert on top of that
        // makes you dismiss a dialog to look at the thing it is describing.
        .sheet(isPresented: $showPicker) {
            LibraryPickerView(session: session, space: space) { _ in
                showPicker = false
                Task { await store?.refresh() }
            } onCancel: {
                showPicker = false
            }
        }
        .sheet(isPresented: $showBackup) {
            if let engine {
                BackupHubView(
                    session: session, engine: engine, settings: $backupSettings
                ) { showBackup = false }
            }
        }
        // "Set Up Now" is a promise to set backup up, so it opens the settings
        // rather than a hub the settings are one more tap inside.
        // Its own stack rather than a push: search is a place you go and come
        // back from, and pushing it would leave the grid's scroll position and
        // the viewer's navigation tangled up with it.
        .sheet(isPresented: $showSearch) {
            NavigationStack {
                SearchView(session: session, space: space)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showSearch = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showMoveTo) {
            MoveToSheet(session: session, source: space, count: selection.count) {
                showMoveTo = false
            } onConfirm: { destination in
                showMoveTo = false
                share(to: destination)
            }
        }
        .alert(
            "Couldn't share these",
            isPresented: Binding(get: { moveError != nil }, set: { if !$0 { moveError = nil } })
        ) {
            Button("OK") { moveError = nil }
        } message: {
            Text(moveError ?? "")
        }
        .fullScreenCover(isPresented: $showFocusedBackup) {
            if let engine {
                FocusedBackupView(engine: engine) { showFocusedBackup = false }
            }
        }
        .sheet(isPresented: $showBackupSettings) {
            if let engine {
                BackupSettingsView(
                    session: session, engine: engine, settings: $backupSettings
                ) { showBackupSettings = false }
            }
        }
        #endif
        #if !os(tvOS)
        .modifier(AddToAlbumPresentation(
            session: session, selection: selection,
            isPresented: $showAddToAlbum, result: $albumResult
        ))
        .modifier(MetadataPresentation(
            session: session, space: space, selection: selection,
            showTags: $showTagEditor,
            result: $albumResult
        ))
        #endif
        .sheet(isPresented: $showActivity) {
            if let activity {
                ActivityInboxView(session: session, store: activity) { item in
                    showActivity = false
                    // Jump to where it happened.
                    if let match = session.spaces.first(where: { $0.id == item.spaceID }) {
                        session.selectedSpace = match
                    }
                } onDone: {
                    showActivity = false
                }
            }
        }
        .task {
            let store = activity ?? ActivityStore(session: session)
            activity = store
            await store.refresh()
        }
        #if os(iOS)
        // A finished backup should show up without the user having to think
        // about it; the cloud badges survive until they pull to refresh.
        .onChange(of: engine?.completedRuns) { _, _ in
            Task { await store?.refresh() }
        }
        // And the same for a batch shared straight from the library: the local
        // tiles retire as each one lands, so without this there is a gap where
        // the photo has left the pending queue and the server row hasn't been
        // read yet — a tile that disappears and comes back.
        .onChange(of: session.pendingUploads.completedBatches) { _, _ in
            Task { await store?.refresh() }
        }
        #endif
        #if os(macOS)
        // The same courtesy for a Mac upload, which had none.
        //
        // iOS announces its own arrivals twice over — a finished backup run and
        // a finished share batch each nudge the grid — and the Mac relied on
        // the fifteen-second poll instead. So a photo you had just dragged in
        // sat invisible until the next tick, and leaving the page and coming
        // back looked like the only way to see it. Something this app did
        // itself should never wait to be discovered.
        .onChange(of: macUploads.completed) { _, _ in
            Task { await store?.refresh() }
        }
        #endif
        .task(id: space.id) {
            let newStore = session.timelineStore(for: space)
            store = newStore
            await newStore?.load()
        }
        // Coming back to the app should not mean coming back to a stale
        // library. Photos this device didn't upload — from a phone, from
        // another person in a shared space — arrive with no local event to
        // announce them, so without this the only way to see them was to know
        // to pull down.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await store?.refresh() }
        }
        // And while you're actually looking at it, keep it current.
        //
        // Cheap on purpose: `/changes` answers an unchanged library with an
        // empty list, so a tick costs a few hundred bytes and no image traffic.
        // Keyed on the scene phase as well as the space so the loop is torn
        // down when the app leaves the foreground rather than polling a NAS
        // from someone's pocket.
        .task(id: PollKey(space: space.id, isActive: scenePhase == .active)) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                // Read each time round rather than captured once: the whole
                // point is that the cadence changes as the grid does.
                try? await Task.sleep(nanoseconds: pollInterval)
                guard !Task.isCancelled else { return }
                await store?.refresh()
            }
        }
    }

    /// Restarts the poll when either the space or the foreground state changes.
    private struct PollKey: Equatable {
        let space: UUID
        let isActive: Bool
    }

    /// How long to wait before asking the NAS what changed.
    ///
    /// Two speeds, because there are two situations and one interval cannot
    /// serve both. Normally nothing is expected, a tick is a courtesy, and
    /// fifteen seconds is fast enough that a photo taken in the next room turns
    /// up while you're still looking at the grid.
    ///
    /// But a grid holding an undelivered photo is *waiting for a specific
    /// answer*, and it is nearly always the person who just uploaded it who is
    /// staring at the grey square. Fifteen seconds of that reads as a broken
    /// upload — which is exactly the complaint, and why "it appears if I leave
    /// the tab and come back" was the workaround. So while anything is
    /// undelivered this polls at two seconds and stops the moment the last one
    /// lands.
    ///
    /// The fast rate costs nothing worth counting: `/changes` answers an
    /// unchanged library with an empty list, and the burst only lasts as long as
    /// the derivation queue does.
    private var pollInterval: UInt64 {
        store?.hasPendingDerivations == true ? 2_000_000_000 : 15_000_000_000
    }

    @ViewBuilder
    private func content(_ store: TimelineStore) -> some View {
        switch store.state {
        case .idle, .loading:
            ProgressView("Loading library…")

        case .failed(let reason):
            ContentUnavailableView("Couldn't load", systemImage: "exclamationmark.triangle", description: Text(reason))

        // Queued-but-not-yet-uploaded photos still count as content: on a fresh
        // library the whole camera roll is pending, and "No photos yet" while
        // the backup is visibly running is just wrong.
        case .loaded where store.buckets.isEmpty && !hasQueuedItems:
            ContentUnavailableView(
                "No photos yet",
                systemImage: "square.on.square",
                description: Text("Photos backed up to \(space.name) will appear here.")
            )

        case .loaded:
            grid(store)
        }
    }


    /// One tile.
    ///
    /// Selection and navigation are different enough that they'd read as two
    /// cells, but the branch lives inside the builder rather than across a
    /// `#if` — braces have to balance within each conditional block.
    @ViewBuilder
    private func gridCell(
        _ item: TimelineItem, size: CGSize, dayItems: [TimelineItem] = []
    ) -> some View {
        #if os(macOS)
        // One branch, always. There used to be two — a selecting cell and a
        // browsing cell — and on a Mac that was the bug: the first click turned
        // selection on, the cell swapped to the other branch, and double-click
        // and right-click both vanished with it. You could select and then do
        // nothing but select more.
        //
        // A Mac tile answers all three gestures at once and always has.
        PhotoCell(item: item, loader: session.loader, size: size)
            .overlay(alignment: .topLeading) {
                if selection.contains(item) {
                    SelectionMark(isPicked: true).padding(5)
                }
            }
            .overlay {
                if selection.contains(item) {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .contentShape(Rectangle())
            // One gesture, and the second click recognised by timing.
            //
            // Any double-tap recogniser — competing *or* simultaneous — makes
            // a single click wait to see whether a second one is coming, so
            // the highlight always arrived a visible beat after the press.
            // Measured: the ring was absent immediately after the click and
            // present two seconds later.
            //
            // AppKit does not work that way and neither does the Finder: the
            // first click selects at once, and a second one soon after means
            // open. Deciding from the interval is that behaviour exactly, and
            // it leaves one gesture on the tile, which fires immediately.
            .onTapGesture {
                let now = Date()
                let isSecondClick = lastClickedID == item.id
                    && now.timeIntervalSince(lastClickAt) <= NSEvent.doubleClickInterval
                lastClickAt = now
                lastClickedID = item.id

                if isSecondClick {
                    // Undo the selection the first click made — opening is what
                    // the pair meant, not "select then open".
                    lastClickedID = nil
                    selection.clear()
                    openItem = OpenedPhoto(
                        item: item, dayItems: dayItems, pageItems: loadedItemsInOrder()
                    )
                } else if NSEvent.modifierFlags.contains(.command) {
                    // ⌘-click adds to what is picked; a plain click replaces it.
                    selection.isActive = true
                    selection.toggle(item)
                } else {
                    selection.clear()
                    selection.begin(with: item)
                }
            }
            .contextMenu { macCellMenu(for: item) }
        #elseif !os(tvOS)
        if selection.isActive {
            // Identical on every platform: once you're selecting, a click and a
            // tap mean the same thing.
            PhotoCell(item: item, loader: session.loader, size: size)
                .overlay(alignment: .topLeading) {
                    SelectionMark(isPicked: selection.contains(item)).padding(5)
                }
                .overlay {
                    if selection.contains(item) {
                        Rectangle().fill(.black.opacity(0.25))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { selection.toggle(item) }
                // Lets a drag across the grid find this tile. Reports only
                // while selecting, so browsing pays nothing for it.
                #if os(iOS)
                .sweepTarget(item, in: Self.gridSpace, active: selection.isActive)
                #endif
        } else {
            #if os(iOS)
            // Not a NavigationLink: the link consumes the press and pushes the
            // photo, so a long press could never start selection. Tap opens,
            // long press selects, and navigation runs off `openItem`.
            PhotoCell(item: item, loader: session.loader, size: size)
                .overlay(alignment: .bottomTrailing) {
                    if engine?.recentlyUploaded.contains(item.assetID) == true {
                        UploadStateBadge(state: .uploaded).padding(5)
                    }
                }
                // The one being checked, once the grid has scrolled to its day.
                // A ring rather than a dimming of everything else: the point is
                // to find this photo among its neighbours, not to hide them.
                .overlay {
                    if review?.current == item.assetID {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: review?.index)
                .contentShape(Rectangle())
                .onTapGesture {
                    // Snapshotted at the tap rather than recomputed in the
                    // viewer: the pager's contents must not shuffle underneath
                    // a swipe because a bucket finished loading behind it.
                    openItem = OpenedPhoto(
                        item: item, dayItems: dayItems, pageItems: loadedItemsInOrder()
                    )
                }
                // Matches Photos: no mode to find first, and the photo you
                // pressed is already picked.
                .onLongPressGesture {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    selection.begin(with: item)
                }
                .photoTransitionSource(id: item.id, in: photoTransition)
            #endif
        }
        #else
        NavigationLink {
            AssetDetailView(
                    item: item, space: space, session: session,
                    // So the next/previous video controls have a day to
                    // walk. There is no pager on these platforms.
                    dayItems: dayItems
                )
        } label: {
            PhotoCell(item: item, loader: session.loader, size: size)
        }
        .buttonStyle(.plain)
        #endif
    }

    #if os(macOS)
    /// Everything the Mac window adds around the grid: where a photo opens,
    /// the file picker, the drop target and its border.
    ///
    /// Lifted out of `body` because the type-checker gave up on it inline —
    /// "unable to type-check this expression in reasonable time". A view
    /// builder is one enormous generic expression, and each `#if` branch adds
    /// to the same one.
    private var macChrome: some ViewModifier {
        MacTimelineChrome(
            openItem: $openItem,
            showFileImporter: $showFileImporter,
            isDropTargeted: $isDropTargeted,
            space: space,
            session: session,
            uploads: macUploads
        )
    }

    /// What right-click offers, over whatever is actually picked.
    ///
    /// The rule that makes this behave: right-clicking a photo that is *not*
    /// in the selection acts on that photo alone and replaces the selection
    /// with it — the way the Finder does. Right-clicking one that is already
    /// picked acts on the whole set. Without that, a menu raised over an
    /// unpicked tile would silently act on forty photos somewhere else.
    ///
    /// Delete says how many it will take, because "Delete" over a selection you
    /// cannot see all of is the one item here you cannot undo by repeating it.
    @ViewBuilder
    private func macCellMenu(for item: TimelineItem) -> some View {
        let targets: [TimelineItem] = selection.contains(item) ? selection.picked : [item]
        let n = targets.count
        let noun = n == 1 ? "Photo" : "Photos"

        Button {
            focus(item)
            openItem = OpenedPhoto(
                item: item, dayItems: dayItems(containing: item),
                pageItems: loadedItemsInOrder(), showsInfo: true
            )
        } label: {
            Label("Get Info", systemImage: "info.circle")
        }

        Divider()

        Button {
            focus(item)
            Task {
                shareFiles = await selection.downloadOriginals(
                    from: space, client: session.client
                )
                if !shareFiles.isEmpty { showShare = true }
            }
        } label: {
            Label("Share…", systemImage: "square.and.arrow.up")
        }

        Divider()

        // Videos carry rotation in the container rather than in EXIF, so the
        // server declines them — offering the verb anyway would be a menu item
        // that reports failure every time.
        if targets.allSatisfy({ $0.mediaType != .video }) {
            Button {
                focus(item)
                for target in targets { rotateOne(target, .left) }
            } label: {
                Label("Rotate Counterclockwise", systemImage: "rotate.left")
            }
            Button {
                focus(item)
                for target in targets { rotateOne(target, .right) }
            } label: {
                Label("Rotate Clockwise", systemImage: "rotate.right")
            }
            Divider()
        }

        Button {
            focus(item)
            showAddToAlbum = true
        } label: {
            Label("Add to Album…", systemImage: "rectangle.stack.badge.plus")
        }

        if !session.sharedSpaces.isEmpty {
            Menu {
                ForEach(session.sharedSpaces.filter { $0.id != space.id }) { target in
                    Button(target.name) {
                        focus(item)
                        Task {
                            _ = try? await session.client?.share(
                                spaceID: space.id,
                                assetIDs: targets.map(\.assetID),
                                to: target.id
                            )
                            await store?.refresh()
                        }
                    }
                }
            } label: {
                Label("Add to Shared Space", systemImage: "person.2")
            }
        }

        Button {
            focus(item)
            editingItems = targets
            showDateEditor = true
        } label: {
            Label("Edit Date & Time…", systemImage: "calendar")
        }

        Divider()

        // Counted, like Photos. "Delete" over a selection you cannot see all of
        // is the one item here that repeating will not undo.
        Button(role: .destructive) {
            focus(item)
            confirmDelete = true
        } label: {
            Label("Delete \(n) \(noun)", systemImage: "trash")
        }
    }

    /// The day a photo belongs to, for the viewer's next/previous walk.
    ///
    /// Found by searching what is loaded rather than by recomputing the bucket
    /// key: the store's key derivation is private, and duplicating it here
    /// would be a second implementation of the one rule that decides which day
    /// a photo belongs to.
    private func dayItems(containing item: TimelineItem) -> [TimelineItem] {
        guard let store else { return [item] }
        for (_, bucket) in store.items where bucket.contains(where: { $0.id == item.id }) {
            return bucket
        }
        return [item]
    }

    /// Points the selection at what the menu is about to act on.
    ///
    /// A right-click on an unpicked photo means "this one", so the selection
    /// becomes exactly that — otherwise every action below would read a set the
    /// user was not looking at.
    private func focus(_ item: TimelineItem) {
        guard !selection.contains(item) else { return }
        selection.clear()
        selection.begin(with: item)
    }

    /// Turns one photo. The regenerated thumbnail arrives over delta sync.
    private func rotateOne(_ item: TimelineItem, _ rotation: MediaRotation) {
        Task {
            _ = try? await session.client?.rotate(
                spaceID: space.id, assetIDs: [item.assetID], rotation
            )
        }
    }
    #endif

    #if !os(tvOS)
    /// Turns the selection and reports what took.
    ///
    /// No confirmation step: a rotation is one tap to undo in the opposite
    /// direction, and asking someone to confirm every quarter turn is how
    /// straightening a dozen photos becomes a chore.
    private func rotate(_ rotation: MediaRotation) {
        Task {
            let result = await selection.rotate(
                rotation, in: space, client: session.client
            )
            guard let result else { return }
            albumResult = "\(result.updated) item\(result.updated == 1 ? "" : "s") rotated"
            selection.clear()
        }
    }
    #endif

    /// Asks the loader to warm a day's thumbnails.
    ///
    /// Capped rather than the whole bucket: a day with six hundred photos would
    /// otherwise queue six hundred fetches on the strength of one section
    /// scrolling into view, which is the unbounded behaviour this is meant to
    /// replace. A couple of screens' worth is what "about to be seen" means.
    private func prefetchThumbnails(for key: String, in store: TimelineStore) async {
        guard let loader = session.loader, let items = store.items[key] else { return }
        await loader.prefetch(
            items.prefix(60).map { ($0.assetID, $0.thumbnailVersion) },
            size: PhotoGridMetrics.thumbnailPixels
        )
    }

    /// Everything one section draws, in order.
    ///
    /// Pending, real and placeholder tiles all end up in one list so the
    /// justified layout can size them together — a row that stopped at the last
    /// uploaded photo and started again underneath would show the seam.
    private func entries(for bucket: TimelineBucket, items: [TimelineItem]) -> [GridEntry] {
        var entries: [GridEntry] = []

        // Not-yet-uploaded photos lead their day: they are the newest thing
        // that happened, and burying them under already-safe photos hides
        // exactly what the user is waiting on.
        #if os(iOS)
        for queued in queuedByDay[bucket.key] ?? [] {
            entries.append(.pending(localIdentifier: queued.localIdentifier, state: queued.state))
        }
        #endif

        if items.isEmpty {
            // Placeholders keep the section the right height so the scrollbar
            // doesn't jump when the bucket lands.
            entries.append(contentsOf: (0..<max(bucket.count, 0)).map { GridEntry.placeholder($0) })
        } else {
            entries.append(contentsOf: items.map(GridEntry.item))
        }

        return entries
    }

    /// Draws one entry at the size the layout worked out for it.
    @ViewBuilder
    private func cell(
        _ entry: GridEntry, size: CGSize, dayItems: [TimelineItem]
    ) -> some View {
        switch entry {
        case .item(let item):
            gridCell(item, size: size, dayItems: dayItems)
        case .placeholder:
            Rectangle().fill(.quaternary)
                .frame(width: size.width, height: size.height)
        #if os(iOS)
        case .pending(let localIdentifier, let state):
            PendingTile(localIdentifier: localIdentifier, state: state, size: size)
        #endif
        }
    }

    /// The density control. Hidden while selecting, where the contextual
    /// actions take its place.
    private func zoomBar(_ store: TimelineStore) -> some View {
        ZoomBar(zoom: store.zoom) { newZoom in
            apply(newZoom)
        }
        .padding(.bottom, 6)
    }

    /// The zoom pill, when there is a reason for it to be there.
    ///
    /// It stands down on the same signal as the two bars around it, so scrolling
    /// into the library leaves nothing but photographs — which is the whole
    /// point of a bar that a photo can pass behind. Coming back up brings all
    /// three together.
    ///
    /// The `ZStack` is load-bearing. `.animation` has to hang off something that
    /// survives the pill leaving, or there is nothing left to run the transition
    /// on and the bar simply blinks out — and it collapses to nothing when empty,
    /// so the inset gives its height back rather than leaving a gap.
    ///
    /// Not on macOS, where the same two steps live in the window toolbar.
    @ViewBuilder
    private func floatingZoom(_ store: TimelineStore) -> some View {
        #if !os(macOS)
        ZStack {
            if !scrollProgress.chromeHidden {
                zoomBar(store)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.28), value: scrollProgress.chromeHidden)
        #endif
    }

    #if os(iOS)
    /// Which day a given asset sits in, loading buckets until it turns up.
    ///
    /// Buckets are fetched as they scroll into view, so a freshly moved item is
    /// usually in one nobody has looked at yet. Searching loaded buckets first
    /// keeps the common case free; the walk is bounded by the manifest, which is
    /// small even for a large library.
    private func bucketKey(for assetID: UUID, in store: TimelineStore) async -> String? {
        if let key = store.items.first(where: { _, items in
            items.contains { $0.assetID == assetID }
        })?.key {
            return key
        }
        for bucket in store.buckets where store.items[bucket.key] == nil {
            await store.loadBucket(bucket.key)
            if store.items[bucket.key]?.contains(where: { $0.assetID == assetID }) == true {
                return bucket.key
            }
        }
        return nil
    }

    /// Shares the selection into another space, then hands the result upward.
    ///
    /// This space is refreshed even though nothing left it: the copies are new
    /// rows the server has just announced, and re-reading is honest where
    /// guessing which rows changed is not.
    private func share(to destination: SpaceDTO) {
        let assetIDs = selection.picked.map(\.assetID)
        guard let client = session.client, !assetIDs.isEmpty else { return }
        Task {
            do {
                let result = try await client.share(
                    spaceID: space.id, assetIDs: assetIDs, to: destination.id
                )
                selection.clear()
                await store?.refresh()
                onShared?(destination, result, space)
            } catch {
                // Said out loud. An action that silently does nothing leaves
                // people wondering whether it half-happened, and half-happened
                // is exactly what they will assume.
                moveError = error.localizedDescription
            }
        }
    }
    #endif

    /// Takes one step along the zoom ladder, if there is one to take.
    ///
    /// Shared by the pill, the pinch, and the Mac's toolbar and keyboard
    /// shortcuts, so they can't drift into disagreeing about what a step does.
    ///
    /// Keeps your place across a density change.
    ///
    /// `topBucket` is whatever section is at the top right now, so the anchor
    /// costs nothing to read. It has to be read *before* the swap, though —
    /// the moment the new manifest lands it describes a bucket that no longer
    /// exists — and translated *after*, because the keys it translates into
    /// don't exist until then.
    ///
    /// Without this, zooming out to find 2012 and back in to look at it landed
    /// you in 2026, which made the whole control useless for the one thing
    /// people zoom out to do.
    #if os(macOS)
    /// Reads the store's zoom, writes through `apply` so the scroll anchor is
    /// carried across — assigning `store.zoom` directly would change the grid
    /// under you and drop you at the top of the library.
    private var zoomBinding: Binding<TimelineZoom> {
        Binding(
            get: { store?.zoom ?? .day },
            set: { apply($0) }
        )
    }
    #endif

    private func apply(_ newZoom: TimelineZoom?) {
        guard let newZoom, let store else { return }
        let anchor = topBucket
        Task {
            await store.setZoom(newZoom)
            guard let anchor, let target = store.buckets.counterpart(of: anchor) else { return }
            // After the grid has settled, not before.
            //
            // Replacing every section resets the scroll to the top, and that
            // reset writes to this very binding — so assigning first means
            // SwiftUI overwrites the anchor a moment later with the new first
            // section. One wait, then assign, and the binding sticks.
            try? await Task.sleep(nanoseconds: 100_000_000)
            topBucket = target
        }
    }

    #if os(iOS)
    /// Queued local items grouped by the same day key the server buckets use.
    ///
    /// Two sources, both showing photos that exist on the phone and not yet on
    /// the NAS: the backup queue, and anything shared straight from the library.
    ///
    /// Scoped to this space, which it wasn't. The backup queue targets the
    /// personal space, so before this every shared space's grid drew the phone's
    /// entire backlog of pending uploads as though they were on their way *there*
    /// — tiles for photos that were never going to appear.
    private var queuedByDay: [String: [(localIdentifier: String, state: UploadState)]] {
        var grouped: [String: [(localIdentifier: String, state: UploadState)]] = [:]
        let zoom = store?.zoom ?? .day

        if let engine, backupSettings.enabled,
           backupSettings.targetSpace(in: session.spaces)?.id == space.id {
            for entry in engine.queued {
                let key = Self.dayKey(entry.capturedAt, zoom: zoom)
                grouped[key, default: []].append((entry.localIdentifier, entry.state))
            }
        }

        for entry in session.pendingUploads.items(in: space.id) {
            let key = Self.dayKey(entry.capturedAt, zoom: zoom)
            grouped[key, default: []].append((entry.localIdentifier, entry.state))
        }
        return grouped
    }

    /// The photo's own wall clock, matching how the server buckets it.
    static func dayKey(_ date: Date, zoom: TimelineZoom) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        switch zoom {
        case .year: formatter.dateFormat = "yyyy"
        case .month: formatter.dateFormat = "yyyy-MM"
        case .day: formatter.dateFormat = "yyyy-MM-dd"
        }
        return formatter.string(from: date)
    }
    #endif

    /// Whether the grid itself is on screen, as opposed to a spinner, an error,
    /// or the empty state.
    ///
    /// Two places have to agree about this — the banner rides inside the grid
    /// and above everything else — so the condition lives here rather than
    /// being spelled out twice and drifting.
    private var showsGrid: Bool {
        guard let store, store.state == .loaded else { return false }
        return !store.buckets.isEmpty || hasQueuedItems
    }

    private var hasQueuedItems: Bool {
        #if os(iOS)
        return !queuedByDay.isEmpty
        #else
        return false
        #endif
    }

    #if !os(tvOS)
    /// Every item the grid has actually loaded, in the order they're drawn.
    ///
    /// Not the whole library — buckets load as they scroll into view, and that
    /// is the honest scope for a swipe: everything you could have reached by
    /// scrolling is in here, and a bucket nobody has looked at yet isn't worth
    /// blocking a tap on.
    private func loadedItemsInOrder() -> [TimelineItem] {
        guard let store else { return [] }
        return sections(store).flatMap { store.items[$0.key] ?? [] }
    }
    #endif

    /// The sections to draw. Only iOS has a local backup queue to merge in.
    private func sections(_ store: TimelineStore) -> [TimelineBucket] {
        #if os(iOS)
        return Self.mergedBuckets(store, queued: queuedByDay)
        #else
        return store.buckets
        #endif
    }

    #if os(iOS)
    /// Server buckets plus any day that so far exists only on this phone.
    ///
    /// A photo taken this morning has no bucket yet — without this it would be
    /// invisible until its upload finished, which is the opposite of what a
    /// backup indicator is for.
    static func mergedBuckets(
        _ store: TimelineStore,
        queued: [String: [(localIdentifier: String, state: UploadState)]]
    ) -> [TimelineBucket] {
        var buckets = store.buckets
        let known = Set(buckets.map(\.key))
        let extra = queued.keys.filter { !known.contains($0) }
        guard !extra.isEmpty else { return buckets }
        buckets.append(contentsOf: extra.map { TimelineBucket(key: $0, count: 0, place: nil) })
        return buckets.sorted { $0.key > $1.key }
    }
    #endif

    /// The count of media in this grid, closing the scroll the way Photos and
    /// Synology both do. Centred, quiet, and given real vertical room so it
    /// reads as an ending rather than another row.
    private func gridFooter(_ count: Int) -> some View {
        Text("\(count.formatted(.number)) \(count == 1 ? "Item" : "Items")")
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 30)
            .padding(.bottom, 28)
            .accessibilityLabel(
                count == 1 ? "1 item in this library" : "\(count) items in this library"
            )
    }

    private func grid(_ store: TimelineStore) -> some View {
        GeometryReader { proxy in
            ScrollViewReader { scroller in
            ScrollView {
                // `spacing: 0`, and every gap lives inside the header instead.
                // Stack spacing sits *above* a pinned header, so at 18 the
                // header docked 18pt down from the top and the row it was
                // meant to be covering slid through the gap.
                //
                // Nothing is attached to the `Section`s themselves either: a
                // `LazyVStack` only pins what it can still recognise as a
                // section, and a modifier wrapped round one is a good way to
                // quietly lose the pinning. The per-bucket `.task` and `.id`
                // hang off the content and the header instead.
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    // Inside the scroll content, above the first date, so it
                    // scrolls out of the way like Synology's does rather than
                    // holding a strip of the screen forever.
                    #if os(iOS)
                    if let engine {
                        backupBanner(engine)
                            .animation(.easeOut(duration: 0.2), value: connection?.state)
                    }
                    #endif

                    ForEach(sections(store)) { bucket in
                        Section {
                            let items = store.items[bucket.key] ?? []
                            PhotoGridSection(
                                entries: entries(for: bucket, items: items),
                                width: proxy.size.width,
                                targetHeight: PhotoGridMetrics.targetRowHeight(
                                    for: store.zoom
                                ),
                                spacing: spacing,
                                columns: columns
                            ) { entry, size in
                                cell(entry, size: size, dayItems: items)
                            }
                            .task {
                                await store.loadBucket(bucket.key)
                                // Warm this day's thumbnails as soon as its
                                // contents are known. Buckets are fetched as
                                // they come into view, so this runs a screen or
                                // so ahead of the tiles themselves — the bytes
                                // are usually local by the time a cell asks.
                                await prefetchThumbnails(for: bucket.key, in: store)
                            }
                        } header: {
                            // The scrubber's target. On the header rather than
                            // the section so a jump lands with the date at the
                            // top of the screen, where the pinned one sits.
                            header(bucket).id(bucket.key)
                        }
                    }

                    // The library's floor: the count of everything in this
                    // grid, and where the scroll stops. Last in the stack so
                    // there is nothing to scroll past it, the way Photos and
                    // Synology both end a library. `store.total` is the
                    // manifest's own count, so it is known before the buckets
                    // are — a person scrolling to the bottom always finds it
                    // filled in.
                    if store.total > 0 {
                        gridFooter(store.total)
                    }
                }
                // Marks the sections as scroll targets, which is what lets
                // `scrollPosition` below name one. On the stack rather than on
                // the `Section`s — see the note above about wrapping those.
                .scrollTargetLayout()
            }
            // The grid has its own scrubber (`FastScroller` below), so the
            // system indicator is the second bar that showed on the right while
            // scrolling. Hidden here, leaving only the scrubber — the way Photos
            // shows one, not two.
            .scrollIndicators(.hidden)
            // Which section is at the top, maintained by SwiftUI in both
            // directions: it reports where you are as you scroll, and scrolls
            // when it's assigned to.
            //
            // Assigning is how a density change keeps its place. The imperative
            // alternative — `scrollTo` right after swapping every bucket —
            // cannot work: at that instant the lazy stack has realised almost
            // nothing, so the scroll finds no such section and silently does
            // nothing. Timing it with sleeps only turns that into a race, and a
            // race that fights the layout is how the grid ended up frozen.
            // Binding the position lets SwiftUI resolve it once the section
            // actually exists, which is the whole difference.
            .scrollPosition(id: $topBucket, anchor: .top)
            #if os(iOS)
            // Walks the grid to whichever moved item is being pointed at.
            //
            // Scrolls to the item's *section* rather than the tile, because
            // sections are what this grid can be scrolled to — and it is enough:
            // the ring on the tile is what actually finds it once its day is on
            // screen. The bucket has to be loaded to know which day that is, so
            // an item in a day nobody has scrolled to yet is fetched first.
            .onChange(of: review?.index) { _, _ in
                guard let assetID = review?.current else { return }
                Task {
                    if let key = await bucketKey(for: assetID, in: store) {
                        topBucket = key
                    }
                }
            }
            #endif
            #if os(iOS)
            // Drag across tiles to select a run of them. Inert until a selection
            // is already open, so an ordinary drag still means scroll.
            .selectionSweep(selection, space: Self.gridSpace)
            #endif
            // Keeps photos out of the strip above the pinned date. The scroll
            // view's frame stops at the safe area but its content draws past
            // it, so without this a row slides up under the status bar and sits
            // there in plain sight above the date — and, while the bar is up,
            // behind the title too, which on iOS 26 has no background of its
            // own to hide it.
            //
            // The top edge only. `.clipped()` did all four, and the bottom one
            // was the price: see `TopEdgeClip`.
            .clipShape(TopEdgeClip())
            // Reads the scroll view's own offset rather than inferring it from
            // content geometry: a LazyVStack only measures realised rows, so a
            // background GeometryReader reports a height that grows as you
            // scroll and a fraction that never leaves zero.
            .modifier(ScrollActivityReporter(progress: scrollProgress))
            // Skipped entirely on macOS rather than applied with nothing in
            // it. An inset whose content is empty still lays out, and it
            // covered the grid: every click on a photograph went into an
            // invisible zero-height bar instead of the tile under it, so
            // nothing selected, nothing opened, and right-click raised no menu.
            // The `#if` belongs outside the modifier.
            //
            // Selecting on a Mac is not a *mode* you enter and leave — it is a
            // state a tile is in, the way a file in the Finder is. The bar, the
            // "1 item selected" title and the X to escape were a phone's modal
            // selection transplanted; right-click carries these actions there.
            #if !os(macOS)
            .safeAreaInset(edge: .bottom) {
                #if !os(tvOS)
                if selection.isActive {
                    SelectionBar(selection: selection) {
                        Task {
                            shareFiles = await selection.downloadOriginals(
                                from: space, client: session.client
                            )
                            if !shareFiles.isEmpty { showShare = true }
                        }
                    } onAddToAlbum: {
                        showAddToAlbum = true
                    } onDelete: {
                        confirmDelete = true
                    } moreMenu: {
                        // First, and on its own, because it is the only entry
                        // here that puts photos in front of other people rather
                        // than annotating them where they sit.
                        #if os(iOS)
                        Button {
                            showMoveTo = true
                        } label: {
                            Label("Add to Shared Space", systemImage: "person.2.badge.plus")
                        }
                        Divider()
                        #endif

                        Button {
                            showTagEditor = true
                        } label: {
                            Label("Edit Tags", systemImage: "tag")
                        }

                        Divider()
                        // Corrections to what the photo says about itself,
                        // grouped away from the library actions above: these
                        // two change the file on the NAS, not just this library's
                        // opinion of it.
                        Button {
                            editingItems = selection.picked
                            showDateEditor = true
                        } label: {
                            Label("Edit Date & Time", systemImage: "calendar")
                        }
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
                } else {
                    // Takes the pill's slot while a review is running: checking
                    // what just arrived is the one job on screen, and two
                    // floating bars stacked over the photos is one too many.
                    #if os(iOS)
                    if let review, let onReviewDone {
                        MoveReviewBar(
                            review: review, onDone: onReviewDone,
                            onRemoveOriginals: onRemoveOriginals
                        )
                    } else {
                        floatingZoom(store)
                    }
                    #else
                    floatingZoom(store)
                    #endif
                }
                #else
                // tvOS keeps its pill up. Hiding chrome on scroll is a gesture
                // idiom; on a remote the bar is somewhere you *navigate* to,
                // and one that disappears as you move down the grid is one you
                // can no longer reach.
                zoomBar(store)
                #endif
            }
            #endif
            .refreshable {
                await store.refresh()
                #if os(iOS)
                // The cloud means "this just went up". After a deliberate
                // refresh it isn't news any more, so it retires.
                engine?.clearUploadBadges()
                #endif
            }
            #if !os(tvOS)
            .overlay(alignment: .trailing) {
                if store.buckets.count > 1 {
                    // A phone gets the scrubber that stays out of the way; a
                    // Mac or an iPad gets the rail that says something while
                    // nobody is touching it. The difference is available width,
                    // not preference — a labelled rail costs horizontal space a
                    // phone has already given to photographs.
                    //
                    // No animation on the scroll in either: an animated scroll
                    // per drag update queues up and the grid slides on after
                    // your finger has already stopped.
                    if wantsRail {
                        TimelineRail(
                            buckets: store.buckets,
                            progress: scrollProgress
                        ) { bucket in
                            scroller.scrollTo(bucket.key, anchor: .top)
                            Task { await store.loadBucket(bucket.key) }
                        } onScrubEnd: {}
                        .padding(.vertical, 6)
                    } else {
                        FastScroller(
                            buckets: store.buckets,
                            progress: scrollProgress
                        ) { bucket in
                            scroller.scrollTo(bucket.key, anchor: .top)
                            Task { await store.loadBucket(bucket.key) }
                        } onScrubEnd: {}
                        .padding(.vertical, 6)
                    }
                }
            }
            #endif
            }
        }
    }


    #if os(iOS)
    /// Pinned above the grid: always present while backup is on, because
    /// "is my phone backed up" is a question people ask constantly and a
    /// banner that only appears during work can't answer it.
    @ViewBuilder
    private func backupBanner(_ engine: BackupEngine) -> some View {
        // Ahead of both backup states, and shown even when backup is off. A
        // NAS that isn't answering breaks browsing too — tiles beyond the cache
        // stay blank and tapping one fails — so this is the more useful thing
        // to say regardless of whether anything is being uploaded.
        if let connection, connection.state != .online {
            connectionBanner(connection.state)
        } else if space.kind != .personal {
            // Backup is about *this phone's camera roll*, which has nothing to
            // do with a library the family contributes to. Offering "turn on
            // Photo Backup" above a shared space invites the reading that it
            // would back up into that space, and it wouldn't — backup has one
            // target, chosen in its own settings.
            //
            // A broken connection still shows above, because that breaks
            // browsing here as much as anywhere.
            EmptyView()
        } else if !backupSettings.enabled {
            // Backup being off is worth interrupting for once, with the action
            // attached — a status row you have to know to tap is how people end
            // up months later with nothing backed up. Dismissible, because
            // being nagged forever about a deliberate choice is worse.
            if !dismissedBackupPrompt {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Photo Backup Not Enabled")
                                .font(.headline)
                            Text("Turn on to continue backing up photos.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button {
                            withAnimation { dismissedBackupPrompt = true }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Button("Set Up Now") { showBackupSettings = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.primary.opacity(0.12))
                        .foregroundStyle(.primary)
                }
                .padding(14)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        } else {
            runningBanner(engine)
        }
    }

    /// Why the library is unreachable, in the terms that decide what to do
    /// about it.
    ///
    /// "No signal" and "the NAS isn't answering" are separated deliberately:
    /// one resolves itself and the other means somebody should go and look at
    /// the box. Collapsing them into "offline" would leave a NAS that has been
    /// down since Tuesday looking like a bad cell.
    ///
    /// Not a button. It clears itself within seconds of the server coming
    /// back, and a tappable banner whose only action is the one already
    /// running invites a tap that changes nothing.
    private func connectionBanner(_ state: ConnectionMonitor.State) -> some View {
        let isOffline = state == .offline
        return HStack(spacing: 12) {
            Image(systemName: isOffline ? "wifi.slash" : "exclamationmark.icloud.fill")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text(isOffline ? "No Internet Connection" : "Can't Reach FrameStation")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Text(
                    isOffline
                        ? "Photos will sync when you're back online."
                        : "Your library is unavailable and backups are paused."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// The status row, once backup is actually on.
    private func runningBanner(_ engine: BackupEngine) -> some View {
        Button { showBackup = true } label: {
            HStack(spacing: 12) {
                Image(systemName: bannerIcon(engine))
                    .font(.title3)
                    .foregroundStyle(bannerTint(engine))

                VStack(alignment: .leading, spacing: 1) {
                    Text(bannerTitle(engine))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    if let detail = bannerDetail(engine) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Reachable from the bar itself, not only from inside the hub.
                //
                // The moment somebody wants to force a backlog through is the
                // moment they are looking at this bar and seeing a number that
                // is not moving fast enough — whether the backup is running,
                // paused, or suspended because the NAS was unreachable an hour
                // ago. Making them open Photo Backup first to find it puts two
                // taps between the impulse and the thing.
                if backupSettings.enabled, engine.progress.pending > 0 {
                    Button {
                        showFocusedBackup = true
                    } label: {
                        Text("Focus")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(.tint.opacity(0.18), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    /// Off is a status too — hiding the bar when backup is disabled leaves the
    /// question "is my phone backed up?" unanswered, which is the one thing
    /// this bar exists to answer.
    private func bannerTitle(_ engine: BackupEngine) -> String {
        guard backupSettings.enabled else { return "Photo Backup Off" }
        return engine.progress.pending > 0 ? "Backing Up" : "Photo Backup Complete"
    }

    private func bannerDetail(_ engine: BackupEngine) -> String? {
        guard backupSettings.enabled else { return "Tap to turn on" }
        guard engine.progress.pending > 0 else { return nil }
        let count = engine.progress.pending
        return "\(count) item\(count == 1 ? "" : "s") left"
    }

    private func bannerIcon(_ engine: BackupEngine) -> String {
        guard backupSettings.enabled else { return "icloud.slash" }
        return engine.progress.pending > 0 ? "icloud.and.arrow.up" : "checkmark.icloud.fill"
    }

    private func bannerTint(_ engine: BackupEngine) -> Color {
        guard backupSettings.enabled else { return .secondary }
        return engine.progress.pending > 0 ? Color.accentColor : Color.green
    }
    #endif

    /// The date that rides at the top of the grid.
    ///
    /// Pinned, so it holds at the top of the viewport while its own photos
    /// scroll under it and then gets pushed off by the next date coming up —
    /// the hand-off in screenshots two through four. Two details make that read
    /// correctly rather than merely happen:
    ///
    /// The breathing room above a date is *inside* the header. It has to be:
    /// spacing between stack children stays behind when a header pins, so a gap
    /// carried by the stack becomes a window onto the photos sliding past.
    ///
    /// And the fill is opaque to the leading edge. A translucent header lets the
    /// row underneath ghost through it, and two dates overlapping mid-hand-off
    /// is the exact thing this layout is supposed to avoid.
    private func header(_ bucket: TimelineBucket) -> some View {
        HStack(spacing: 6) {
            Text(Self.displayDate(bucket.key))
                .font(.headline)
            if let place = bucket.place {
                Text("· \(place)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.headerFill)
    }

    /// The app's own background, so photos disappear cleanly underneath rather
    /// than showing through. `.systemBackground` has no macOS spelling and
    /// `.windowBackgroundColor` has no iOS one, hence the split.
    static var headerFill: Color {
        #if os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #elseif os(tvOS)
        return Color.black
        #else
        return Color(uiColor: .systemBackground)
        #endif
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Top left, mirroring where Photos and Synology both put activity.
        // `.topBarLeading` doesn't exist on macOS; `.navigation` is the
        // equivalent leading slot there.
        // Selecting strips the bar back to a way out and a count, and nothing
        // else — the count moves into the title, where there is room for it.
        //
        // Everything else up here belongs to *browsing*: activity, search, and
        // adding photos are all things you do to a library, not to a selection.
        // Leaving them alongside the count left six controls fighting over one
        // bar, with both the count and the space name truncated to make room
        // for buttons that did nothing useful in that moment.
        #if !os(tvOS)
        if selection.isActive {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    selection.clear()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Done selecting")
            }
        }
        #endif
        #if os(macOS)
        // Adding from a Mac is choosing files, not backing up a library. The
        // drop target on the grid does the same job for people who drag; this
        // is the same action where a Mac keeps its actions.
        if !selection.isActive {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showFileImporter = true
                } label: {
                    Label("Add Photos", systemImage: "plus")
                }
                .keyboardShortcut("i", modifiers: .command)
            }
        }
        // Only while there is something to report. A permanently parked
        // progress ring is furniture; one that appears when an upload starts is
        // information.
        if macUploads.pending > 0 || macUploads.completed > 0 || macUploads.failed > 0 {
            ToolbarItem(placement: .primaryAction) {
                MacUploadStatusButton(uploads: macUploads, isPresented: $showUploadQueue)
            }
        }
        // No Select button. Pressing and holding a photo starts a selection
        // that already holds it, which is both fewer steps and the same gesture
        // the phone uses. A button that only put you *into* a mode, leaving you
        // to then go and pick something, was the longer road to the same place.
        if !selection.isActive {
            // The three zoom levels as one control, the way Photos does it.
            //
            // These were a pair of ⌘+ / ⌘− buttons, which is a *relative*
            // control for what is really a choice between three named things:
            // going from years to days meant pressing the same button twice
            // and watching to see where you ended up. A segmented control
            // shows all three, says which one you are on, and reaches any of
            // them in one click.
            //
            // The labels are Apple's — "All Photos" rather than "Days" —
            // because that is the wording anyone who has used Photos already
            // has, and our `.day` zoom is the same thing it names.
            ToolbarItem(placement: .principal) {
                Picker("Zoom", selection: zoomBinding) {
                    Text("Years").tag(TimelineZoom.year)
                    Text("Months").tag(TimelineZoom.month)
                    Text("All Photos").tag(TimelineZoom.day)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                .disabled(store == nil)
            }
        }
        #endif

        #if !os(tvOS)
        // Takes the title's slot, and only while browsing.
        if !isSelecting, let spaceSwitcher {
            ToolbarItem(placement: .principal) { spaceSwitcher }
        }
        #endif

        // The browsing controls, and only while browsing. See the note above.
        if !isSelecting {
            ToolbarItem(placement: Self.leadingPlacement) {
                Button {
                    showActivity = true
                } label: {
                    Image(systemName: (activity?.unreadCount ?? 0) > 0
                          ? "bell.badge.fill" : "bell")
                        .symbolRenderingMode((activity?.unreadCount ?? 0) > 0 ? .multicolor : .monochrome)
                }
                .accessibilityLabel(
                    (activity?.unreadCount ?? 0) > 0
                        ? "Recent activity, \(activity?.unreadCount ?? 0) new"
                        : "Recent activity"
                )
            }

            #if os(iOS)
            // Declared before `+` so it lands to its left: adding a control
            // beside one people already reach for is fine, sliding that one
            // over is not.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSearch = true
                } label: {
                    Label("Search \(space.name)", systemImage: "magnifyingglass")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    showPicker = true
                } label: {
                    Label(
                        space.kind == .shared ? "Add to \(space.name)" : "Add Photos",
                        systemImage: "plus"
                    )
                }
            }
            #endif
        }
    }

    /// Names the coordinate space the sweep measures tiles in. Shared by the
    /// cells that report their frames and the gesture that reads them, so the
    /// two cannot drift onto different spaces and silently never match.
    static let gridSpace = "photo-grid"

    /// Whether a selection is open.
    ///
    /// `selection` itself only exists off tvOS — there is no multi-select with a
    /// remote — so anything outside a `#if` has to ask through here. The toolbar
    /// referred to it directly and compiled fine on iOS while breaking the tvOS
    /// build, which is the failure mode this exists to remove.
    private var isSelecting: Bool {
        #if os(tvOS) || os(macOS)
        // macOS has no selection *mode* — see the bottom-bar note. Reporting
        // false keeps the toolbar and the space name where they were.
        return false
        #else
        return selection.isActive
        #endif
    }

    /// Where you are, or what you've picked — never both at once.
    private var selectionTitle: String {
        #if os(tvOS) || os(macOS)
        return space.name
        #else
        guard selection.isActive else { return space.name }
        return selection.count == 1 ? "1 item selected" : "\(selection.count) items selected"
        #endif
    }

    static var leadingPlacement: ToolbarItemPlacement {
        #if os(macOS)
        return .navigation
        #else
        return .topBarLeading
        #endif
    }

    /// `2026-07-18` → `Jul 18`, `2026-07` → `July 2026`, `2026` → `2026`.
    static func displayDate(_ key: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        let display = DateFormatter()

        switch key.count {
        case 4:
            return key
        case 7:
            parser.dateFormat = "yyyy-MM"
            display.dateFormat = "MMMM yyyy"
        default:
            parser.dateFormat = "yyyy-MM-dd"
            display.dateFormat = "MMM d"
        }

        guard let date = parser.date(from: key) else { return key }
        display.timeZone = TimeZone(identifier: "UTC")
        return display.string(from: date)
    }
}

/// Trims the grid at the top edge and lets it run off the bottom.
///
/// The grid used to be `.clipped()`, which trims all four. The top edge is the
/// one that had to be trimmed — a row drawn above the frame sits under the
/// status bar in plain sight above the pinned date — but the bottom edge came
/// along with it, and that is what stopped the library dead at the tab bar.
/// Photos ended behind a bar with nothing passing under it, so the glass down
/// there had nothing to be glass over and read as a solid slab.
///
/// The overhang has to clear the zoom bar, the tab bar and the home indicator
/// stacked together, and there is nothing below the screen for the surplus to
/// spill onto, so it is set generously rather than measured.
private struct TopEdgeClip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(
            x: rect.minX, y: rect.minY,
            width: rect.width, height: rect.height + 320
        ))
    }
}


#if os(macOS)
/// The Mac grid's window furniture, as a modifier rather than more lines of
/// `body`. See `TimelineView.macChrome`.
private struct MacTimelineChrome: ViewModifier {
    @Binding var openItem: OpenedPhoto?
    @Binding var showFileImporter: Bool
    @Binding var isDropTargeted: Bool
    let space: SpaceDTO
    @Bindable var session: AppSession
    let uploads: MacUploads

    func body(content: Content) -> some View {
        content
            .navigationDestination(item: $openItem) { opened in
                AssetDetailView(
                    item: opened.item, space: space, session: session,
                    dayItems: opened.dayItems, pageItems: opened.pageItems,
                    showsInfoInitially: opened.showsInfo
                )
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: MacUploads.acceptedTypes,
                allowsMultipleSelection: true
            ) { result in
                guard case .success(let urls) = result,
                      let client = session.client else { return }
                uploads.add(urls, to: space.id, client: client)
            }
            // Dropping onto the library is the gesture a Mac user reaches for
            // first, and it is the same action as the toolbar button — same
            // queue, same code path, so the two cannot behave differently.
            .dropDestination(for: URL.self) { urls, _ in
                guard let client = session.client else { return false }
                uploads.add(urls, to: space.id, client: client)
                return true
            } isTargeted: { isDropTargeted = $0 }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.tint, lineWidth: 3)
                        .padding(6)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isDropTargeted)
    }
}
#endif
