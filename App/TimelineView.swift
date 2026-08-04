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
struct TimelineView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO
    #if os(iOS)
    /// Owned by RootTabView so every tab reads the same backup state.
    let engine: BackupEngine?
    @Binding var backupSettings: BackupSettings
    #endif

    @State private var store: TimelineStore?
    /// Follows the zoom — see TimelineZoom.columns.
    private var columns: Int { (store?.zoom ?? .day).columns }
    @State private var activity: ActivityStore?
    @State private var showActivity = false
    @State private var showSpaces = false
    #if os(iOS)
    @State private var showBackup = false
    /// Dismissing the "not enabled" card lasts for the session, not forever:
    /// the next launch asks once more, because an un-backed-up library is
    /// worth one reminder a day.
    @State private var dismissedBackupPrompt = false
    @State private var showBackupSettings = false
    @State private var showAddToAlbum = false
    @State private var albumResult: String?
    @State private var showPicker = false
    @State private var shareResult: Int?
    @State private var selection = GridSelection()
    @State private var shareFiles: [URL] = []
    @State private var showShare = false
    @State private var confirmDelete = false
    #endif

    private let spacing: CGFloat = 2
    @State private var scrollFraction: Double = 0
    #if os(iOS)
    /// The photo a tap opened, and the day it came from — the slideshows need
    /// to know what "that day" contained.
    @State private var openItem: TimelineItem?
    @State private var openDayItems: [TimelineItem] = []
    #endif

    var body: some View {
        VStack(spacing: 0) {
            // Above the content rather than inside it: the answer to "is my
            // phone backed up?" must not depend on whether the library
            // happens to have photos in it yet.
            #if os(iOS)
            if let engine {
                backupBanner(engine)
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
        .navigationTitle(space.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbar }
        #if os(iOS)
        .navigationDestination(item: $openItem) { opened in
            AssetDetailView(
                item: opened, space: space, session: session, dayItems: openDayItems
            )
        }
        // Selecting photos reuses the tab bar's slot rather than stacking a
        // second bar above it: the actions apply to what you picked, so the
        // places you could navigate to are not the question being asked.
        .toolbar(selection.isActive ? .hidden : .automatic, for: .tabBar)
        #endif
        .sheet(isPresented: $showSpaces) {
            SpacesView(session: session) { showSpaces = false }
        }
        #if os(iOS)
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
            Text("They stay on this iPhone. On the NAS they move to #recycle, and backup won't add them again.")
        }
        .sheet(isPresented: $showPicker) {
            LibraryPickerView(session: session, space: space) { count in
                showPicker = false
                shareResult = count
                Task { await store?.refresh() }
            } onCancel: {
                showPicker = false
            }
        }
        .alert(
            "Added to \(space.name)",
            isPresented: Binding(get: { shareResult != nil }, set: { if !$0 { shareResult = nil } })
        ) {
            Button("OK") { shareResult = nil }
        } message: {
            Text(shareResult.map { "\($0) item\($0 == 1 ? "" : "s") shared." } ?? "")
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
        .modifier(AddToAlbumPresentation(
            session: session, selection: selection,
            isPresented: $showAddToAlbum, result: $albumResult
        ))
        .sheet(isPresented: $showBackupSettings) {
            if let engine {
                BackupSettingsView(
                    session: session, engine: engine, settings: $backupSettings
                ) { showBackupSettings = false }
            }
        }
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
        #endif
        .task(id: space.id) {
            let newStore = session.timelineStore(for: space)
            store = newStore
            await newStore?.load()
        }
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
        _ item: TimelineItem, side: CGFloat, dayItems: [TimelineItem] = []
    ) -> some View {
        #if os(iOS)
        if selection.isActive {
            PhotoCell(item: item, loader: session.loader, side: side)
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
        } else {
            // Not a NavigationLink: the link consumes the press and pushes the
            // photo, so a long press could never start selection. Tap opens,
            // long press selects, and navigation runs off `openItem`.
            PhotoCell(item: item, loader: session.loader, side: side)
                .overlay(alignment: .bottomTrailing) {
                    if engine?.recentlyUploaded.contains(item.assetID) == true {
                        UploadStateBadge(state: .uploaded).padding(5)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    openDayItems = dayItems
                    openItem = item
                }
                // Matches Photos: no mode to find first, and the photo you
                // pressed is already picked.
                .onLongPressGesture {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    selection.begin(with: item)
                }
        }
        #else
        NavigationLink {
            AssetDetailView(item: item, space: space, session: session)
        } label: {
            PhotoCell(item: item, loader: session.loader, side: side)
        }
        .buttonStyle(.plain)
        #endif
    }

    /// The density control. Hidden while selecting, where the contextual
    /// actions take its place.
    private func zoomBar(_ store: TimelineStore) -> some View {
        ZoomBar(zoom: Binding(get: { store.zoom }, set: { _ in })) { newZoom in
            Task { await store.setZoom(newZoom) }
        }
        .padding(.bottom, 6)
    }

    #if os(iOS)
    /// Queued local items grouped by the same day key the server buckets use.
    private var queuedByDay: [String: [(localIdentifier: String, state: UploadState)]] {
        guard let engine, backupSettings.enabled else { return [:] }
        var grouped: [String: [(localIdentifier: String, state: UploadState)]] = [:]
        for entry in engine.queued {
            let key = Self.dayKey(entry.capturedAt, zoom: store?.zoom ?? .day)
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

    private var hasQueuedItems: Bool {
        #if os(iOS)
        return !queuedByDay.isEmpty
        #else
        return false
        #endif
    }

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

    private func grid(_ store: TimelineStore) -> some View {
        GeometryReader { proxy in
            let side = (proxy.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections(store)) { bucket in
                        Section {
                            LazyVGrid(
                                columns: Array(
                                    repeating: GridItem(.fixed(side), spacing: spacing),
                                    count: columns
                                ),
                                spacing: spacing
                            ) {
                                // Not-yet-uploaded photos lead their day: they
                                // are the newest thing that happened, and
                                // burying them under already-safe photos hides
                                // exactly what the user is waiting on.
                                #if os(iOS)
                                ForEach(queuedByDay[bucket.key] ?? [], id: \.localIdentifier) { entry in
                                    PendingTile(
                                        localIdentifier: entry.localIdentifier,
                                        state: entry.state,
                                        side: side
                                    )
                                }
                                #endif
                                let items = store.items[bucket.key] ?? []
                                if items.isEmpty {
                                    // Placeholder tiles keep the section the
                                    // right height so the scrollbar doesn't jump
                                    // when the bucket lands.
                                    ForEach(0..<max(bucket.count, 0), id: \.self) { _ in
                                        Rectangle().fill(.quaternary)
                                            .frame(width: side, height: side)
                                    }
                                } else {
                                    ForEach(items) { item in
                                        gridCell(item, side: side, dayItems: items)
                                    }
                                }
                            }
                        } header: {
                            header(bucket)
                        }
                        .task { await store.loadBucket(bucket.key) }
                        .id(bucket.key)
                    }
                }
            }
            // Reads the scroll view's own offset rather than inferring it from
            // content geometry: a LazyVStack only measures realised rows, so a
            // background GeometryReader reports a height that grows as you
            // scroll and a fraction that never leaves zero.
            .modifier(ScrollFractionReporter { scrollFraction = $0 })
            .safeAreaInset(edge: .bottom) {
                #if os(iOS)
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
                    } onMore: {
                    }
                } else {
                    zoomBar(store)
                }
                #else
                zoomBar(store)
                #endif
            }
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
                    FastScroller(
                        buckets: store.buckets,
                        scrollFraction: scrollFraction
                    ) { bucket in
                        // No animation: an animated scroll per drag update
                        // queues up and the grid slides on after your finger
                        // has already stopped.
                        scroller.scrollTo(bucket.key, anchor: .top)
                        Task { await store.loadBucket(bucket.key) }
                    } onScrubEnd: {}
                    .padding(.vertical, 6)
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
        if !backupSettings.enabled {
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
        .padding(.vertical, 6)
        // `.bar` is unavailable on tvOS; the 10-foot layout uses a plain
        // translucent fill instead.
        #if os(tvOS)
        .background(.thinMaterial)
        #else
        .background(.bar)
        #endif
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Top left, mirroring where Photos and Synology both put activity.
        // `.topBarLeading` doesn't exist on macOS; `.navigation` is the
        // equivalent leading slot there.
        #if os(iOS)
        if selection.isActive {
            ToolbarItem(placement: .principal) {
                Text(selection.count == 1 ? "1 selected" : "\(selection.count) selected")
                    .font(.headline)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    selection.clear()
                } label: {
                    Image(systemName: "xmark")
                }
            }
        }
        #endif

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
