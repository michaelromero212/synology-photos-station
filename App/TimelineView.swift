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
    /// Whether this grid was pushed onto a stack and needs a way back.
    ///
    /// The grid hides the navigation bar while browsing — the whole top-edge
    /// treatment depends on the library running under the clock rather than
    /// stopping below a bar — which also hides the back chevron the system
    /// would have drawn. That cost nothing while every grid was a tab. A shared
    /// album is a pushed screen now, so without this it is a room with the door
    /// painted over: reachable, and escapable only by someone who already knows
    /// the edge-swipe is there.
    var isPushed = false
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
    /// Pops this grid when it was pushed. Unused when it is a tab's root.
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// Whether there is room for a labeled rail rather than a bare scrubber.
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
    @State private var showFocusedBackup = false
    @State private var showPicker = false
    @State private var showSearch = false
    #if os(iOS)
    /// The pending pull-the-grid, so a stream of landings coalesces into one.
    @State private var landingRefresh: Task<Void, Never>?
    #endif
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
    /// A one-shot request to scroll a section to the top. Zoom re-anchoring and
    /// moved-item review set it; an `.onChange` inside the `ScrollViewReader`
    /// performs the jump with `scrollTo` and clears it.
    ///
    /// Deliberately *not* a `.scrollPosition(id:)` binding. That binding is
    /// two-way: SwiftUI rewrote it on every content-size change, and each
    /// rewrite re-scrolled the view, which re-realized rows in the lazy grid,
    /// which changed the content size again — a feedback loop that never
    /// settled and flung the grid past its end (confirmed on device).
    /// Imperative `scrollTo`, the way the scrubber already jumps, does not loop.
    @State private var pendingJump: String?
    #if os(iOS)
    /// The status bar and Dynamic Island's height, from the window itself.
    ///
    /// Asked of UIKit rather than of a `GeometryReader`, after the SwiftUI route
    /// gave three different wrong answers in a row. A reader placed below the
    /// `ignoresSafeArea` reports zero, because the inset has just been consumed
    /// and zero is the honest answer to the wrong question. One placed above it
    /// as a background measures its own region rather than the screen's —
    /// 20pt, when measured. And the value was never a property of a view to
    /// begin with: it describes the window, so the window is what is asked.
    ///
    /// Cached rather than read raw, which is the part that took a device log to
    /// learn: `keyWindow` is nil on the first layout pass on real hardware, and
    /// a zero here silently halved the top margin and moved the whole library
    /// 62pt a tenth of a second after launch. See `WindowMetrics`.
    private var windowTopInset: CGFloat { WindowMetrics.topInset }
    #endif
    #if !os(tvOS)
    /// The photo a tap opened, the day it came from — the slideshows need to
    /// know what "that day" contained — and everything currently loaded, which
    /// is what the viewer swipes through.
    @State private var openItem: OpenedPhoto?
    /// Which photograph the viewer was opened on, so closing it can tell
    /// whether you went anywhere. Recorded centrally rather than at each of the
    /// three places that open the viewer — see `followViewer`.
    @State private var openedWith: UUID?
    #endif

    var body: some View {
        #if os(iOS)
        // Cheap and only fires when SwiftUI rebuilds this view's identity, which
        // is precisely the event being hunted.
        let _ = LayoutWatch.shared.noteBodyBuild()
        #endif
        return VStack(spacing: 0) {
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
        // The browsing controls, floated over the top of the grid so they can
        // slide away on scroll (see `floatingTopBar`). An overlay, not an inset,
        // so it never resizes the scroll view. iOS only — macOS keeps its window
        // toolbar, tvOS its own chrome.
        #if os(iOS)
        // Under the bar, and outliving it: the grid runs to the top of the
        // display now, so something has to hold the clock and the glyphs up
        // over whatever photograph is passing beneath them — including once the
        // controls have slid away and there is nothing there but library.
        //
        // Both are pushed down by the inset the root gave away. They are inside
        // that `ignoresSafeArea`, so without this they align to the top of the
        // *display* and the controls land on top of the clock — which is the
        // trade for letting the grid have the whole screen: what wants the
        // status bar respected now has to say so.
        .overlay(alignment: .top) { TopEdgeFade(topInset: windowTopInset) }
        .overlay(alignment: .top) { floatingTopBar.padding(.top, windowTopInset) }
        // And the backup banner at the other end, for the same reason the
        // controls are up there: an overlay moves nothing when it goes.
        //
        // It used to be the last item in the scroll content so it would scroll
        // away with the photographs. That is a nicer idea than it is a
        // behavior — dismissing it made the content shorter, and a grid
        // anchored to its own end has to take up the slack, so the library
        // jumped by the banner's height every time someone pressed the X.
        //
        // Aligned to the bottom *inside* the safe area, so it rides above the
        // tab bar rather than under it. Only when the grid is up; the empty-
        // library case still puts it in the stack in `body`, where there is no
        // scroll view for it to disturb.
        .overlay(alignment: .bottom) {
            // Only the connection banner floats now, and only because it is an
            // error rather than a status: a NAS that isn't answering breaks
            // browsing as well as backup, and saying so where somebody is
            // already looking is worth covering a row for. A status is not, and
            // the one that used to float here is gone entirely — see the note
            // at the end of the scroll content.
            //
            // Not while selecting. The selection bar goes here too, and of the
            // two only one is something to act on.
            //
            // Above the floating bar, not through it: eight points off the safe
            // area was right when the system drew the tab bar and reserved its
            // own space, and ours floats twenty-one points from the bottom of
            // the display and reserves nothing.
            if let connection, connection.state != .online, showsGrid, !selection.isActive {
                connectionBanner(connection.state)
                    .padding(.bottom, FloatingTabBarMetrics.contentInset)
                    .allowsHitTesting(true)
            }
        }
        #endif
        // The count takes the title while selecting. It used to sit in the
        // leading slot beside the space name, which left two pieces of text
        // competing for one bar and both of them truncated — "8…" next to
        // "Family Sh…" tells you neither how many nor where.
        .navigationTitle(selectionTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // While you are choosing photographs, the selection bar is the only bar
        // that matters — see `floatingTabBarHidden`. Inside the iOS guard
        // because `selection` does not exist on a television: there is no
        // selecting there, and no floating bar to get out of its way.
        .floatingTabBarHidden(whileSelecting: selection.isActive)
        #endif
        .toolbar { toolbar }
        #if os(macOS)
        .modifier(macChrome)
        #endif
        #if os(iOS)
        // The system bar is for *selecting* now — it carries the count and the
        // way out. While browsing it stays hidden and `floatingTopBar` carries
        // the controls instead, as an overlay that can slide away on scroll for
        // more grid. Crucially this toggles on selection, a discrete action,
        // never on scroll: a scroll-driven bar toggle resized the scroll view's
        // safe area and fed the storm this session already fought. The overlay
        // moves without insetting anything, which is what keeps it safe.
        .toolbar(selection.isActive ? .automatic : .hidden, for: .navigationBar)
        // Only while selecting, and the "only" is load-bearing.
        //
        // Selecting, the bar above returns to carry the count and the X, and
        // the system puts its back chevron in the same corner: two round
        // buttons side by side, one cancelling the selection and one silently
        // throwing it away along with the screen. Photos hides the back button
        // the moment you start selecting, and it is right — you finish with the
        // selection, then you leave.
        //
        // Browsing, this must stay false even though the bar is hidden and its
        // chevron with it, because hiding the back button also disables the
        // swipe-from-the-edge that pops the screen. Hiding it unconditionally
        // was tried and measured: the swipe stopped working. That is survivable
        // for as long as `floatingTopBar` is on screen carrying its own
        // chevron — and that bar slides away on scroll, so someone a few
        // screens down a long shared album would have had no way out at all
        // until they scrolled back up. The gesture is the floor under the
        // button, and it has to stay.
        //
        // A no-op on a grid that is a tab's root, which has nothing to go back
        // to in the first place.
        .navigationBarBackButtonHidden(selection.isActive)
        .navigationDestination(item: $openItem) { opened in
            viewer(for: opened)
        }
        // One place rather than the three that open the viewer, and it cannot
        // be read off `openItem` on the way out because that is already nil by
        // the time the close handler runs.
        .onChange(of: openItem) { _, opened in
            if let opened { openedWith = opened.item.assetID }
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
        .toolbar(tabBarVisibility, for: .tabBar)
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
        // As each item lands, not just when the whole run does.
        //
        // A pending tile retires the moment its upload commits — `queued` is
        // rebuilt from pending and uploading rows only — but the server row
        // behind it arrives on the next delta. Refreshing at the end of the
        // *run* meant that for a backup of a few thousand photos, every one
        // that finished left a hole in the grid until either the run ended or
        // the fifteen-second poll came round. Photographs disappearing on the
        // way to being safe is the worst possible moment to look unreliable.
        //
        // Debounced rather than per item: a thousand finished uploads must not
        // become a thousand delta requests. See `scheduleLandingRefresh`.
        .onChange(of: engine?.progress.done) { _, _ in scheduleLandingRefresh() }
        .onChange(of: session.pendingUploads.completedItems) { _, _ in
            scheduleLandingRefresh()
        }
        // And the same for a batch shared straight from the library: the local
        // tiles retire as each one lands, so without this there is a gap where
        // the photo has left the pending queue and the server row hasn't been
        // read yet — a tile that disappears and comes back.
        .onChange(of: session.pendingUploads.completedBatches) { _, _ in
            Task { await store?.refresh() }
        }
        .onChange(of: uploadingDay) { previous, current in
            followUpload(from: previous, to: current)
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
            #if os(iOS)
            // Says how much library survived. This task runs on every
            // appearance, so in a tab bar it runs on every tab switch, and it
            // used to hand back a brand new store each time — the whole grid
            // discarded and refetched, caught here eight times in three
            // minutes. Stores are kept per space now, so a healthy line reports
            // items already in hand; a zero after the first visit means
            // something is dropping them again.
            LayoutWatch.shared.note(
                "timeline task for space \(space.id.uuidString.prefix(8)) — "
                    + "\(newStore.map(loadedCount) ?? 0) items already in hand"
            )
            #endif
            store = newStore
            await newStore?.load()
        }
        // Coming back to the app should not mean coming back to a stale
        // library. Photos this device didn't upload — from a phone, from
        // another person in a shared space — arrive with no local event to
        // announce them, and with pull-to-refresh gone this is the refresh that
        // catches them: every return to the foreground, and a cold reopen.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await store?.refresh() }
            #if os(iOS)
            // Returning to the app is the acknowledgment pull-to-refresh used
            // to be — the "just uploaded" cloud badges are no longer news, so
            // they retire.
            engine?.clearUploadBadges()
            #endif
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
        #if os(iOS)
        // Outermost, and that is the entire trick.
        //
        // `ignoresSafeArea` declines the safe area as it stands at the point it
        // is applied — it does not stop a *later* modifier from insetting the
        // result. Everything above re-establishes the top: the navigation
        // title, the toolbars, the destinations. Applied down on the scroll
        // view, or even directly on the stack, it was overruled by forty
        // modifiers' worth of chrome and did nothing at all while reading as
        // correct. Measured both times: container 737 of a 874pt screen, and a
        // safe area of zero where the grid asked for it.
        //
        // `readTopSafeArea` goes above it, because below it the answer is
        // always zero.
        .ignoresSafeArea(.container, edges: .top)
        #endif
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
    /// staring at the gray square. Fifteen seconds of that reads as a broken
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
            // One gesture, and the second click recognized by timing.
            //
            // Any double-tap recognizer — competing *or* simultaneous — makes
            // a single click wait to see whether a second one is coming, so
            // the highlight always arrived a visible beat after the press.
            // Measured: the ring was absent immediately after the click and
            // present two seconds later.
            //
            // AppKit does not work that way and neither does the Finder: the
            // first click selects at once, and a second one soon after means
            // open. Deciding from the interval is that behavior exactly, and
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
                Label("Add to Shared Album", systemImage: "person.2")
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
    /// scrolling into view, which is the unbounded behavior this is meant to
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
    /// One day's tiles, in the order the photographs were taken.
    ///
    /// Not-yet-uploaded photos used to lead their day, on the reasoning that
    /// they were what the user was waiting on and shouldn't be buried. The cost
    /// was worse than the problem: a photo taken at nine in the morning sat at
    /// the head of its day until it finished uploading and then **jumped** down
    /// to where it belonged. Adding a batch meant watching the grid shuffle
    /// itself for as long as the upload ran, which reads as the app not knowing
    /// where things go.
    ///
    /// They are placed by capture time now — the same ordering the store uses,
    /// from the date PHAsset already gave us — so a tile appears where it will
    /// stay, and finishing the upload swaps the picture underneath it without
    /// moving anything.
    private func entries(for bucket: TimelineBucket, items: [TimelineItem]) -> [GridEntry] {
        #if os(iOS)
        let queued = queuedByDay[bucket.key] ?? []
        #endif

        if items.isEmpty {
            // Placeholders keep the section the right height so the scrollbar
            // doesn't jump when the bucket lands. Nothing to interleave with
            // yet, so the pending tiles lead — there is no order to be wrong
            // about.
            var entries: [GridEntry] = []
            #if os(iOS)
            entries = queued.map {
                .pending(localIdentifier: $0.localIdentifier, state: $0.state)
            }
            #endif
            entries.append(contentsOf: (0..<max(bucket.count, 0)).map { GridEntry.placeholder($0) })
            return entries
        }

        #if os(iOS)
        guard !queued.isEmpty else { return items.map(GridEntry.item) }

        // Sorted on `(date, id)` rather than date alone. `sorted(by:)` is not a
        // stable sort, and a day can easily hold several photos sharing a
        // second — a burst, or a video and its still. Ties broken by anything
        // that varies between body builds would let those tiles swap places on
        // an unrelated redraw, which is the flicker this method exists to stop.
        let dated: [(date: Date, id: String, entry: GridEntry)] =
            items.map { ($0.capturedAt, "i\($0.id.uuidString)", .item($0)) }
            + queued.map {
                (
                    $0.capturedAt,
                    "p\($0.localIdentifier)",
                    .pending(localIdentifier: $0.localIdentifier, state: $0.state)
                )
            }

        return dated
            .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
            .map(\.entry)
        #else
        return items.map(GridEntry.item)
        #endif
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

    #if os(iOS)
    /// Which day a given asset sits in, loading buckets until it turns up.
    ///
    /// Buckets are fetched as they scroll into view, so a freshly moved item is
    /// usually in one nobody has looked at yet. Searching loaded buckets first
    /// keeps the common case free; the walk is bounded by the manifest, which is
    /// small even for a large library.
    /// The full-screen viewer a tap opens.
    ///
    /// Lifted out of the `navigationDestination` closure for the same reason
    /// `macChrome` is lifted out of `body`: inline, the type-checker gave up —
    /// "unable to type-check this expression in reasonable time" — and adding a
    /// single argument to the initializer was enough to tip it over.
    @ViewBuilder
    private func viewer(for opened: OpenedPhoto) -> some View {
        AssetDetailView(
            item: opened.item, space: space, session: session,
            dayItems: opened.dayItems, pageItems: opened.pageItems,
            onClose: followViewer
        )
        .photoZoomTransition(id: opened.id, in: photoTransition)
    }

    /// Walks the grid to the day of whatever the viewer finished on.
    ///
    /// Auto-play works through a day's clips and swiping carries on past the day
    /// it opened from, neither of which the grid sees — so returning left you
    /// wherever the tap happened, hunting for where you actually got to. The
    /// day goes to the top, which in a grid running oldest to newest puts the
    /// *next* day directly below it: the one you reach for after finishing this
    /// day's videos.
    ///
    /// A method rather than a closure at the call site. That view builder is
    /// already at the type-checker's limit and an inline closure tipped it into
    /// "unable to type-check this expression in reasonable time".
    private func followViewer(to assetID: UUID) {
        guard let store else { return }
        // Closing the viewer is a return to this screen, and a screen you have
        // just come back to shows its controls — whatever the scroll direction
        // was when you left it. Without this the bar stays wherever the last
        // gesture before the tap put it, which on the way into the library is
        // hidden: you come back from a photo to a grid with no way out of it
        // but scrolling.
        scrollProgress.showTopBar()

        let opened = openedWith
        openedWith = nil

        // Only follow the viewer somewhere it actually went.
        //
        // This used to scroll on every close, and the common case is the one it
        // got wrong: tap a photograph in the day you are already looking at,
        // come straight back, and the grid was already showing exactly what you
        // wanted — then a beat later, once the bucket lookup returned, it
        // yanked that day's header to the top of the screen. That late,
        // uninvited jump is the flinch on the way out of a photo.
        //
        // Following is for when the viewer carried you into a *different* day
        // by swiping, which is the case it was written for and the only one that
        // needs the grid to move at all.
        // Not knowing where you came from is a reason to stay put, not a reason
        // to jump: leaving the grid where the user left it is the answer that is
        // never wrong, and moving it is only right with evidence that the viewer
        // carried them somewhere.
        guard let opened, assetID != opened else { return }
        Task {
            guard let key = await bucketKey(for: assetID, in: store),
                  await bucketKey(for: opened, in: store) != key
            else { return }
            pendingJump = key
        }
    }

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
    /// The day at the top right now — read from the scrubber fraction — is the
    /// anchor. It has to be read *before* the swap: the moment the new manifest
    /// lands it describes a bucket that no longer exists, and it is translated
    /// *after*, because the keys it translates into don't exist until then.
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
        // Which day is at the top right now, read from the scrubber fraction
        // rather than a scroll binding — that is enough to return to it after
        // the density changes.
        let anchor = store.buckets.bucket(atFraction: scrollProgress.fraction)?.key
        Task {
            await store.setZoom(newZoom)
            guard let anchor, let target = store.buckets.counterpart(of: anchor) else { return }
            // After the grid has settled, not before: the manifest swap needs a
            // beat to lay the new sections out, or `scrollTo` finds no target.
            try? await Task.sleep(nanoseconds: 100_000_000)
            pendingJump = target
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
    #if os(iOS)
    /// Pulls the grid shortly after uploads stop landing.
    ///
    /// The window it closes is the one between a pending tile retiring and its
    /// server row arriving. Doing it per item would put one delta request on
    /// the NAS per photograph — precisely the wrong thing during the backup
    /// this exists to smooth — so each landing pushes the refresh out rather
    /// than adding one, and a burst of two hundred arrivals costs a single
    /// request shortly after the last of them.
    ///
    /// Six hundred milliseconds: long enough that a steady stream of uploads
    /// coalesces, short enough that a single share feels immediate.
    private func scheduleLandingRefresh() {
        landingRefresh?.cancel()
        landingRefresh = Task { [store] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await store?.refresh()
        }
    }
    #endif

    /// Carries `capturedAt` through rather than only using it to pick the day:
    /// `entries(for:items:)` needs it to put the tile in the right place
    /// *within* that day.
    private var queuedByDay: [String: [QueuedTile]] {
        var grouped: [String: [QueuedTile]] = [:]
        let zoom = store?.zoom ?? .day

        if let engine, backupSettings.enabled,
           backupSettings.targetSpace(in: session.spaces)?.id == space.id {
            for entry in engine.queued {
                let key = Self.dayKey(entry.capturedAt, zoom: zoom)
                grouped[key, default: []].append(
                    QueuedTile(
                        localIdentifier: entry.localIdentifier,
                        state: entry.state,
                        capturedAt: entry.capturedAt
                    )
                )
            }
        }

        for entry in session.pendingUploads.items(in: space.id) {
            let key = Self.dayKey(entry.capturedAt, zoom: zoom)
            grouped[key, default: []].append(
                QueuedTile(
                    localIdentifier: entry.localIdentifier,
                    state: entry.state,
                    capturedAt: entry.capturedAt
                )
            )
        }
        return grouped
    }

    /// A photo on its way up, and where it belongs while it travels.
    private struct QueuedTile {
        let localIdentifier: String
        let state: UploadState
        let capturedAt: Date
    }

    /// The day holding whatever is on the wire right now, or nil when nothing is.
    ///
    /// Read from the tiles this grid is already drawing rather than from the
    /// engine, which means it is right for a shared album as well as for the
    /// library: `queuedByDay` is scoped to this space, so an upload bound
    /// somewhere else never moves this screen.
    private var uploadingDay: String? {
        let zoom = store?.zoom ?? .day
        for (_, tiles) in queuedByDay {
            if let sending = tiles.first(where: { $0.state == .uploading }) {
                return Self.dayKey(sending.capturedAt, zoom: zoom)
            }
        }
        return nil
    }

    /// Goes to meet the photographs as they arrive.
    ///
    /// The grid opens on the newest day, and an upload very often isn't there —
    /// a backlog being backed up, or a folder of last summer being added — so
    /// without this the tiles appear correctly and invisibly, somewhere up the
    /// library, and you would have to go looking for the thing you just started.
    ///
    /// Once per run, and only on the way *up*: `previous == nil` is the moment
    /// the first item goes on the wire. Following each item instead would drag
    /// the grid along behind a backup, one jump per photograph, which is the
    /// opposite of helpful.
    ///
    /// And never while you are doing something else with the screen. A jump is
    /// worth it when you are watching the grid and not when you are choosing
    /// photos in it or looking at one full-screen — moving the floor under
    /// either of those is how a nicety becomes a bug report.
    private func followUpload(from previous: String?, to current: String?) {
        guard previous == nil, let current else { return }
        guard !selection.isActive, openItem == nil else { return }
        pendingJump = current
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

    /// How many items the grid is actually holding, across every loaded day.
    /// Cheap — a sum of counts, not a flatten — and only read by `LayoutWatch`.
    private func loadedCount(_ store: TimelineStore) -> Int {
        store.items.values.reduce(0) { $0 + $1.count }
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
    /// Generic in the value because it only ever reads the keys — the days that
    /// exist on the phone. What is queued *in* each day is the caller's business.
    static func mergedBuckets<Queued>(
        _ store: TimelineStore,
        queued: [String: Queued]
    ) -> [TimelineBucket] {
        var buckets = store.buckets
        let known = Set(buckets.map(\.key))
        let extra = queued.keys.filter { !known.contains($0) }
        guard !extra.isEmpty else { return buckets }
        buckets.append(contentsOf: extra.map { TimelineBucket(key: $0, count: 0, place: nil) })
        // Ascending, to match the store's oldest-first order — the merged
        // phone-only days slot in by date the same way the server buckets do.
        return buckets.sorted { $0.key < $1.key }
    }
    #endif

    /// The count of media in this grid, closing the scroll the way Photos and
    /// Synology both do. Centered, quiet, and given real vertical room so it
    /// reads as an ending rather than another row.
    #if os(iOS)
    /// How the bottom tab bar shows and hides.
    ///
    /// Hidden while selecting — the selection bar reuses that slot. Otherwise it
    /// splits by OS: on iOS 26 the system's `tabBarMinimizeBehavior` owns the
    /// scroll-driven recede, so we stay out of its way with `.automatic` and let
    /// it track the gesture; below 26 there is no native minimize, so the chrome
    /// flag still drives it — now safe at the end of the grid because
    /// `ScrollProgress` freezes that flag through the bottom bounce.
    private var tabBarVisibility: Visibility {
        if selection.isActive { return .hidden }
        if #available(iOS 26.0, *) { return .automatic }
        return scrollProgress.chromeHidden ? .hidden : .automatic
    }
    #endif

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
                // Dates scroll away with their photographs rather than docking
                // at the top.
                //
                // A pinned header has to be opaque — it has content passing
                // under it — and an opaque band held against the top of an
                // edge-to-edge grid is a slab sitting between the glass and the
                // library, directly under the very fade meant to let one dissolve
                // into the other. Letting it go means the top of the screen is
                // photographs and nothing else, which is the whole point of
                // running them up there. Photos does the same.
                //
                // What it costs: deep inside a day of a hundred photographs
                // there is no date on screen. The scrubber answers that on
                // demand, which is where it was already being asked.
                //
                // `spacing: 0` stays, and every gap still lives inside the
                // header. It was that way because stack spacing sits *above* a
                // pinned header and left a gap for a row to slide through, and
                // it is kept because the space above a date and the space below
                // it are doing different jobs — see `header`.
                LazyVStack(alignment: .leading, spacing: 0) {
                    // The library's size, at the top — above the oldest photo,
                    // the way Apple heads a library. The grid runs oldest→newest
                    // and opens on the newest, so you meet this only by scrolling
                    // all the way back. `store.total` is the manifest's own
                    // count, known before any bucket loads.
                    if store.total > 0 {
                        gridFooter(store.total)
                    }

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
                            // the section, so a jump lands with the date itself
                            // at the top of the screen and its photographs
                            // below — land on the section and the date is the
                            // one thing scrolled off.
                            header(bucket).id(bucket.key)
                        }
                    }

                    // Nothing here, deliberately. The library ends on its last
                    // photograph, which comes to rest eight points above the
                    // floating bar and nothing else.
                    //
                    // A count and a backup status lived here briefly and were
                    // taken out: a line of text at the end of the grid adds its
                    // own height to the distance between the newest row and the
                    // bar, and that space read as a gap rather than as
                    // information. What is being backed up is legible from the
                    // photographs themselves — pending tiles, and a cloud on
                    // each one as it lands — and the total is in More.
                    //
                    // The older rule that emptied this stack still stands and is
                    // the reason a status cannot simply come back when a backup
                    // starts: anything here that appears or disappears resizes
                    // the content under a grid anchored to its own end, and the
                    // library jumps by its height.

                    // macOS rounds the window's bottom corners, which would clip
                    // the newest row now that it rests at the very bottom — the
                    // count footer used to hold this space before it moved to the
                    // top. A little clearance keeps that last row off the curve.
                    #if os(macOS)
                    Color.clear.frame(height: 16)
                    #endif
                }
                // Marks the sections as scroll targets, which is what lets
                // `scrollPosition` below name one. On the stack rather than on
                // the `Section`s — see the note above about wrapping those.
                .scrollTargetLayout()
            }
            // Land on the newest — at the bottom — and scroll up for older, the
            // way Apple's Library opens. The grid runs oldest→newest now (see
            // `TimelineStore.buckets`), so the bottom is the most recent day;
            // this anchors there on first layout and keeps the newest in view as
            // the last day's real heights land. Proven in an isolated repro
            // before it went in: it holds through placeholder→real resizing and
            // clamps at both ends without the overscroll void.
            .defaultScrollAnchor(.bottom)
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
            // cannot work: at that instant the lazy stack has realized almost
            // nothing, so the scroll finds no such section and silently does
            // nothing. Timing it with sleeps only turns that into a race, and a
            // race that fights the layout is how the grid ended up frozen.
            // Binding the position lets SwiftUI resolve it once the section
            // actually exists, which is the whole difference.
            //
            // No `anchor: .top`. With it, the binding re-pinned whatever section
            // it tracked to the very top on every layout pass — and in a library
            // only a screen or so tall, pinning a late day to the top leaves the
            // rest of the screen empty below it. That was the black void you
            // could scroll into past the end of the grid. Without the anchor the
            // position still tracks and still scrolls when assigned, but SwiftUI
            // clamps to the content, so the last day rests at the bottom the way
            // Photos ends a library. The scrubber still lands a day up top
            // through its own `scrollTo(_:anchor:.top)`, which clamps and cannot
            // overscroll into empty space.
            // Imperative jumps only — see `pendingJump`. No `.scrollPosition`
            // binding: its two-way write-back turned every content-size wobble
            // into a re-scroll, and the grid never stopped moving.
            .onChange(of: pendingJump) { _, target in
                guard let target else { return }
                scroller.scrollTo(target, anchor: .top)
                pendingJump = nil
            }
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
                        pendingJump = key
                    }
                }
            }
            #endif
            #if os(iOS)
            // Drag across tiles to select a run of them. Inert until a selection
            // is already open, so an ordinary drag still means scroll.
            .selectionSweep(selection, space: Self.gridSpace)
            #endif
            // Not on iOS. The grid's content is *meant* to run up into the
            // status bar and under the Dynamic Island there, the way Photos
            // lets a library reach the top of the display, and `TopEdgeFade`
            // covers that strip instead of a clip cutting it off.
            //
            // The scroll view's own frame is untouched by this — it still stops
            // at the safe area, so the pinned date still pins below the island
            // and nothing about the scroll metrics changes. Only the overflow
            // that was being thrown away is now drawn. Ignoring the safe area
            // here instead was the obvious-looking move and the wrong one: it
            // consumes the inset rather than converting it, so the pinned date
            // came up level with the clock.
            //
            // macOS and tvOS keep the trim. Neither has the fade, and neither
            // wants photos over its window chrome.
            #if !os(iOS)
            // The top edge only. `.clipped()` did all four, and the bottom one
            // was the price: see `TopEdgeClip`.
            .clipShape(TopEdgeClip())
            #endif
            #if os(iOS)
            // The top inset, by hand, in two parts.
            //
            // `windowTopInset` is the safe area, which the view gives up at the
            // root (see `body`) so photographs can reach the top of the display
            // — without putting it back here the first row would sit under the
            // Dynamic Island permanently rather than merely passing beneath it.
            // Taken from the window, because by this point the inset has been
            // consumed: `proxy.safeAreaInsets.top` reads 0 here, and using it
            // was how this quietly inset by 54 instead of 113.
            //
            // The bar's height is the second part, so the pinned date comes to
            // rest *below* the controls instead of level with them. Without
            // that the date and the space name shared the same 20pt of screen,
            // and the only way to separate them was a scrim heavy enough to
            // bury one, which dragged the fade a row and a half down the page.
            //
            // A *constant* margin, and that distinction is the whole safety
            // argument. What stormed the layout before was an inset that
            // changed as you scrolled: each change resized the scroll view,
            // which re-realized rows, which resized it again. This one is the
            // same on every frame, so there is no loop to enter — the bar still
            // hides by sliding, as an overlay, touching nothing.
            .contentMargins(
                .top, windowTopInset + TopEdgeFade.barHeight, for: .scrollContent
            )
            // And the same trick at the other end, for the floating tab bar.
            // Photographs still pass *under* the glass as you scroll — a content
            // margin moves where the grid comes to rest, not where it is drawn —
            // but the last row of the library now stops on top of the bar rather
            // than half beneath it.
            .contentMargins(
                .bottom, FloatingTabBarMetrics.contentInset, for: .scrollContent
            )
            #endif
            // Reads the scroll view's own offset rather than inferring it from
            // content geometry: a LazyVStack only measures realized rows, so a
            // background GeometryReader reports a height that grows as you
            // scroll and a fraction that never leaves zero.
            .modifier(ScrollActivityReporter(progress: scrollProgress))
            #if os(iOS)
            // The other half of `LayoutWatch`: the geometry says the grid moved,
            // these say what it was reacting to. Without them a content-height
            // change is a fact with no cause attached, which is exactly how the
            // launch flash got misattributed twice.
            .onChange(of: store.buckets.count) { old, new in
                LayoutWatch.shared.note("buckets \(old) → \(new)")
            }
            .onChange(of: store.state) { _, new in
                LayoutWatch.shared.note("store state → \(new)")
            }
            .onChange(of: loadedCount(store)) { old, new in
                LayoutWatch.shared.note("loaded items \(old) → \(new)")
            }
            #endif
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
                            Label("Add to Shared Album", systemImage: "person.2.badge.plus")
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
                    #if os(iOS)
                    // A review bar when a batch has just landed and wants
                    // checking; otherwise nothing. The zoom pill used to sit
                    // here — density is a rare, deliberate change, not a bar
                    // worth floating over every photo — so with it gone the
                    // newest row (or the backup banner) meets the tab bar
                    // directly, which is what the library opening on the newest
                    // wants underneath it.
                    if let review, let onReviewDone {
                        MoveReviewBar(
                            review: review, onDone: onReviewDone,
                            onRemoveOriginals: onRemoveOriginals
                        )
                    }
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
            // No pull-to-refresh. With the library running oldest→newest and
            // opening on the newest, a pull from the top would mean scrolling all
            // the way to the oldest photo first — impossible in a library of
            // thousands. Refresh is automatic instead: a cold open loads fresh,
            // returning to the foreground refreshes (and clears the badges), and
            // the poll keeps it current while you watch. Force-quit and reopen is
            // the manual refresh.
            #if !os(tvOS)
            .overlay(alignment: .trailing) {
                if store.buckets.count > 1 {
                    // A phone gets the scrubber that stays out of the way; a
                    // Mac or an iPad gets the rail that says something while
                    // nobody is touching it. The difference is available width,
                    // not preference — a labeled rail costs horizontal space a
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
    /// Present while backup is running, because "is my phone backed up" is a
    /// question people ask constantly and a banner that only appears during
    /// work can't answer it — and present whenever the NAS is unreachable,
    /// whatever backup is doing.
    ///
    /// Nothing at all when backup is simply off. That case used to raise a
    /// prompt here; it lives in Settings now.
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
            // Nothing. Backup being off used to raise a dismissible prompt here
            // with a "Set Up Now" on it, on the reasoning that a status row you
            // have to know to tap is how people end up months later with nothing
            // backed up. It has been taken out deliberately: turning backup on
            // lives in Settings, and a panel that appears over the newest row of
            // someone's library to tell them about a setting is the kind of
            // thing that makes an app feel like it is selling you something.
            //
            // The connection banner above is not the same kind of thing and
            // stays — that one explains why the tiles are gray, which is the app
            // accounting for its own state rather than nagging about a choice.
            EmptyView()
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
    /// The date a group of photographs was taken, and where.
    ///
    /// Between an edge-to-edge grid and the glass at the top, this is the only
    /// piece of the screen that is plain text on the page, so its typography is
    /// carrying the whole thing. Three deliberate choices:
    ///
    /// **Baselines, not centers.** Two sizes on one line aligned by their boxes
    /// sit at visibly different heights, which is what made the date and the
    /// place read as two things that happened to collide rather than one line.
    ///
    /// **A real step in size.** `.headline` beside `.subheadline` is 17 against
    /// 15 — too close to establish which is the heading, so the pair read as
    /// undifferentiated small text and the band around them looked like padding
    /// with nothing in it. `.title3` gives the date somewhere to stand.
    ///
    /// **Weighted spacing.** Three times as much room above as below, so the
    /// header binds to the photographs it belongs to rather than floating
    /// between two days. It was 16 and 8, which is the right idea and not enough
    /// of it to read.
    ///
    /// No background. It had one only because it used to pin, and a pinned
    /// header needs something opaque to hide the row passing beneath it. These
    /// scroll now, so nothing passes beneath — and having none is what lets a
    /// date wash out under the top fade on its way off screen, exactly as the
    /// photographs around it do, instead of riding up as a solid black bar.
    private func header(_ bucket: TimelineBucket) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.displayDate(bucket.key))
                .font(.subheadline.weight(.semibold))
            if let place = bucket.place {
                Text("· \(place)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        // Measured off Synology's grid rather than chosen: its heading sits
        // about eleven points below the previous day's last row and ten above
        // its own first, at roughly fifteen points of type. This was `.title3`
        // — twenty points — with twenty-four above, so each day cost about
        // twenty points of vertical space more than it needed and the date
        // competed with the photographs instead of labelling them.
        //
        // The place keeps its own size and stays secondary. Both halves at one
        // size is what the reference does; the grayer place is ours, and it is
        // the part that makes a long county name read as a caption rather than
        // as more heading.
        // Eight, not eleven, because the line box adds about four points of
        // leading above the cap height before any padding applies — so twelve
        // measured as sixteen on screen. Eight lands the visible gap on twelve
        // and the whole day heading on about thirty-four points, which is the
        // reference.
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if os(iOS)
    /// Whether the floating bar is allowed to slide away on scroll.
    ///
    /// Never, on a pushed grid, because there the bar carries the only way out.
    ///
    /// Hiding the navigation bar — which this whole top-edge treatment depends
    /// on — also takes the swipe-from-the-edge that pops a screen with it.
    /// Measured, not assumed: the same edge swipe pops a collection's grid,
    /// which keeps its bar, and does nothing in a shared album, which doesn't.
    /// That cost nothing while every grid was a tab with nowhere to go back to.
    /// Now one of them is a pushed screen, and a chevron that slides away on
    /// scroll would have left someone a few screens into a long shared album
    /// with no exit at all until they scrolled back to the top.
    ///
    /// The cost is a strip of chrome over the photographs in shared albums
    /// only. Worth it: the alternative is a room you can get stuck in.
    private var barHidden: Bool {
        scrollProgress.topBarHidden && !isPushed
    }

    /// The browsing controls, floated over the top of the grid so they can
    /// slide away on scroll without insetting the scroll view (the safe way —
    /// see `ScrollProgress.topBarHidden`). Shown only while browsing; selection
    /// hands the top back to the system bar, so this yields to it then. The grid
    /// runs full height underneath, so what the bar slides off of is more grid.
    @ViewBuilder
    private var floatingTopBar: some View {
        if !selection.isActive {
            HStack(spacing: 8) {
                // Leading, where the system would have put it, and on the same
                // glass as its neighbours so it reads as part of the bar rather
                // than as something left over from a navigation bar that isn't
                // there.
                if isPushed {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.backward")
                            .font(.body.weight(.semibold))
                            .frame(width: 38, height: 38)
                            .glassCircle(fallback: .regularMaterial)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                }

                // The personal library only, and once, which is the whole point
                // of it being here.
                //
                // Activity is one inbox for the whole account — everything
                // anyone has added to anything you can see. Repeating its door
                // on every shared album suggested otherwise: four albums, four
                // bells, each looking like it might hold that album's news, all
                // four opening the same list. It belongs on the one screen that
                // is unambiguously "your library, everything in it", which is
                // also the screen you land on.
                if space.kind == .personal {
                    Button { showActivity = true } label: {
                        Image(systemName: (activity?.unreadCount ?? 0) > 0 ? "bell.badge.fill" : "bell")
                            .symbolRenderingMode((activity?.unreadCount ?? 0) > 0 ? .multicolor : .monochrome)
                            .font(.body.weight(.medium))
                            .frame(width: 38, height: 38)
                            .glassCircle(fallback: .regularMaterial)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        (activity?.unreadCount ?? 0) > 0
                            ? "Recent activity, \(activity?.unreadCount ?? 0) new"
                            : "Recent activity"
                    )
                }

                Spacer(minLength: 8)

                // The switcher only, and nothing when there is nothing to switch
                // between. A personal library does not need to be captioned
                // "Personal Space" every time you look at it — the name earned
                // its place when this was an opaque bar with room to spare, and
                // now that photographs run behind the chrome it is one more
                // thing between you and them.
                //
                // On glass where it does appear, like the buttons either side.
                // The library passes behind this bar now, and the first thing it
                // passes behind is the pinned date — two pieces of white text at
                // the same size in the same place read as one broken line, and a
                // surface of its own is what separates them.
                if let spaceSwitcher {
                    spaceSwitcher
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .glassCapsule(fallback: .regularMaterial)
                        .contentShape(Capsule())

                    Spacer(minLength: 8)
                }

                // Only on a shared album, and that asymmetry is deliberate.
                //
                // Search is a button in the corner of the tab bar now, the way
                // Photos has it, and the personal library's magnifier moved
                // there. But a tab can only search one library and `/search` is
                // per-space, so the tab searches the personal one — which would
                // leave a shared album with no way to search itself at all.
                // Until search can span libraries, the album that the corner
                // button cannot reach keeps its own.
                if space.kind == .shared {
                    Button { showSearch = true } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.body.weight(.medium))
                            .frame(width: 38, height: 38)
                            .glassCircle(fallback: .regularMaterial)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search \(space.name)")
                }

                Button { showPicker = true } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.medium))
                        .frame(width: 38, height: 38)
                        .glassCircle(fallback: .regularMaterial)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(space.kind == .shared ? "Add to \(space.name)" : "Add Photos")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            // No background of its own. `TopEdgeFade` is a separate overlay
            // that stays put when this bar slides away, which is the point —
            // the wash is what keeps the clock readable over the library, so it
            // cannot be something that leaves with the controls. The flat
            // `.bar` fill and the `Divider` that used to be here are precisely
            // what made the library stop dead in a line below the island.
            // Absorb taps across the whole bar so a tap on its empty middle
            // doesn't fall through to a photo behind it — and stop intercepting
            // once it has slid away.
            .contentShape(Rectangle())
            .allowsHitTesting(!barHidden)
            // The slide+fade. Offset alone can't fully clear a bar that begins at
            // the safe-area top, so opacity carries it the rest of the way up.
            .offset(y: barHidden ? -120 : 0)
            .opacity(barHidden ? 0 : 1)
            .animation(.easeOut(duration: 0.26), value: barHidden)
        }
    }
    #endif

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
            // Personal library only — see the note in `floatingTopBar`. One
            // account-wide inbox deserves one door, not one per album.
            if space.kind == .personal {
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
            }

            #if os(iOS)
            // Declared before `+` so it lands to its left: adding a control
            // beside one people already reach for is fine, sliding that one
            // over is not.
            //
            // Shared albums only — see the note in `floatingTopBar`. The
            // personal library's search is the button in the tab bar's corner.
            if space.kind == .shared {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSearch = true
                    } label: {
                        Label("Search \(space.name)", systemImage: "magnifyingglass")
                    }
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

#if !os(iOS)
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
///
/// iPhone and iPad no longer use this. There the row above the frame is wanted
/// — it is the library reaching the top of the display — and `TopEdgeFade`
/// covers that strip rather than a clip removing it. The Mac and the TV have no
/// such fade, and neither wants photographs over its own window chrome.
private struct TopEdgeClip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(
            x: rect.minX, y: rect.minY,
            width: rect.width, height: rect.height + 320
        ))
    }
}
#endif

#if os(iOS)
/// The fade Photos runs across the top of the library.
///
/// Blur rather than a tint: a flat color over a photograph reads as a panel
/// laid on top of it, and what is being imitated here is the library carrying on
/// underneath.
///
/// It reaches full strength at the very top rather than easing in from nothing,
/// because the clock and the battery have to stay readable over a bright photo,
/// and it is a material rather than a color so they stay readable over a dark
/// one too.
///
/// Where full strength has to reach is not negotiable: the controls sit on it,
/// and it must still be solid at the bottom of them. So the mask holds flat to
/// there and spends its whole falloff below, on grid — `hold`, computed from the
/// inset it is handed, is that point.
///
/// **This is the app's own fade and not the system's, deliberately.** iOS 26
/// draws exactly this — a true progressive blur with no tint — for
/// `scrollEdgeEffectStyle(.soft, for: .top)`, and it was tried here. It renders
/// nothing: the effect attaches to a *bar*, and this screen hides the navigation
/// bar so the browsing controls can be a floating overlay that slides away on
/// scroll. Verified by removing this view on 26 and finding the photographs
/// sharp and unwashed right up to the clock. Do not re-add it expecting it to
/// take over; it will look correct in the source and do nothing on screen.
private struct TopEdgeFade: View {
    /// 38pt button + 8pt above and below, from `floatingTopBar`. Also what the
    /// grid holds clear at the top of its content, so the pinned date comes to
    /// rest below the bar instead of inside it.
    static let barHeight: CGFloat = 54

    /// Long enough to read as a fade rather than an edge, and no longer: past
    /// this it stops looking like an edge treatment and starts looking like a
    /// panel.
    private static let taper: CGFloat = 26
    /// Full strength fills whatever is left.
    ///
    /// The two together come to exactly `barHeight`, so the wash finishes on the
    /// same line where the grid's content begins — and that is a constraint, not
    /// a coincidence. Whatever sits at that line is opaque: either the first row
    /// of photographs or, when a date is pinned there, its own background. A
    /// fade that runs past it has its tail painted over, which stops the ramp
    /// dead partway down and draws the hard line across the screen that it was
    /// supposed to prevent. It was 40 + 26 against a 54pt margin, so the last
    /// 12pt of gradient was being covered by the pinned date's black.
    private static let crown: CGFloat = barHeight - taper

    /// The status bar's own height, handed in rather than sensed. The grid gives
    /// the safe area up at the root so photographs can reach the top of the
    /// display, and a given-up inset reads as zero everywhere below it.
    let topInset: CGFloat

    var body: some View {
        // One sheet, and Liquid Glass where there is Liquid Glass to be had.
        //
        // It was two materials stacked, on the theory that a material samples
        // what is behind it, so the upper sheet re-blurs the lower one's output
        // and the blur genuinely *weakens* where only one is left, rather than
        // merely going transparent. That is true, and it was the wrong trade. A
        // material in dark mode does not only blur — it darkens — and two of
        // them compound the darkening as surely as the blur, which is how the
        // top of the library ended up a gray slab you could not read a
        // photograph through. Apple's is a blur with almost no tint at all: on
        // theirs you can still make out the turf, the netting, the map.
        //
        // Glass is the closer instrument on 26 — it is built to be seen
        // through, where a material is built to obscure. Below 26 a single
        // `.ultraThinMaterial` is the lightest thing available, and one sheet of
        // it is a great deal lighter than the two it replaces.
        //
        // Still one view and not two stacked end to end: a material's blur
        // kernel is clamped at its own bounds, so adjacent sheets cannot blend
        // and leave a ruler-straight seam across the screen no matter how
        // exactly their alphas match at the join.
        let total = topInset + Self.crown + Self.taper
        let hold = (topInset + Self.crown) / max(total, 1)

        Color.clear
            .frame(height: total)
            .glassBackground(
                in: Rectangle(),
                // Nothing here is pressed; `interactive` is a touch affordance
                // and this is scenery.
                interactive: false,
                fallback: .ultraThinMaterial
            )
            .mask { Self.falloff(holdingTo: hold) }
            // Decoration. The bar in front does its own hit testing, and a tap
            // on the strip beside it belongs to the grid underneath.
            .allowsHitTesting(false)
    }

    /// An eased ramp rather than a straight one. A linear fade holds too much
    /// weight through its middle and then stops, which is the banding you see
    /// across a cheap scrim; easing it off at both ends leaves no edge to find.
    private static func falloff(holdingTo hold: CGFloat) -> LinearGradient {
        let span = max(1 - hold, 0.0001)
        return LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: hold),
                .init(color: .black.opacity(0.94), location: hold + span * 0.25),
                .init(color: .black.opacity(0.72), location: hold + span * 0.5),
                .init(color: .black.opacity(0.34), location: hold + span * 0.75),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
#endif


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
