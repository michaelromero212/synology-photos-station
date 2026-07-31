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

    @State private var store: TimelineStore?
    #if os(iOS)
    @Environment(\.backupContainer) private var modelContainer
    #endif
    @State private var columns = 3
    @State private var showSpaces = false
    #if os(iOS)
    @State private var showBackup = false
    @State private var backupSettings = BackupSettings.load()
    @State private var engine: BackupEngine?
    #endif

    private let spacing: CGFloat = 2

    var body: some View {
        Group {
            if let store {
                content(store)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Photos")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbar }
        .sheet(isPresented: $showSpaces) {
            SpacesView(session: session) { showSpaces = false }
        }
        #if os(iOS)
        .sheet(isPresented: $showBackup) {
            if let engine {
                BackupSettingsView(
                    session: session, engine: engine,
                    settings: $backupSettings
                ) { showBackup = false }
            }
        }
        #endif
        .task(id: space.id) {
            let newStore = session.timelineStore(for: space)
            store = newStore
            await newStore?.load()
        }
        #if os(iOS)
        .task {
            guard engine == nil, let container = modelContainer else { return }
            engine = BackupEngine(
                container: container, session: session, settings: backupSettings
            )
        }
        #endif
    }

    @ViewBuilder
    private func content(_ store: TimelineStore) -> some View {
        switch store.state {
        case .idle, .loading:
            ProgressView("Loading library…")

        case .failed(let reason):
            ContentUnavailableView("Couldn't load", systemImage: "exclamationmark.triangle", description: Text(reason))

        case .loaded where store.buckets.isEmpty:
            ContentUnavailableView(
                "No photos yet",
                systemImage: "square.on.square",
                description: Text("Photos backed up to \(space.name) will appear here.")
            )

        case .loaded:
            #if os(iOS)
            VStack(spacing: 0) {
                if let engine, backupSettings.enabled, engine.progress.total > 0 {
                    backupBanner(engine)
                }
                grid(store)
            }
            #else
            grid(store)
            #endif
        }
    }

    private func grid(_ store: TimelineStore) -> some View {
        GeometryReader { proxy in
            let side = (proxy.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                    ForEach(store.buckets) { bucket in
                        Section {
                            LazyVGrid(
                                columns: Array(
                                    repeating: GridItem(.fixed(side), spacing: spacing),
                                    count: columns
                                ),
                                spacing: spacing
                            ) {
                                let items = store.items[bucket.key] ?? []
                                if items.isEmpty {
                                    // Placeholder tiles keep the section the
                                    // right height so the scrollbar doesn't jump
                                    // when the bucket lands.
                                    ForEach(0..<bucket.count, id: \.self) { _ in
                                        Rectangle().fill(.quaternary)
                                            .frame(width: side, height: side)
                                    }
                                } else {
                                    ForEach(items) { item in
                                        NavigationLink {
                                            AssetDetailView(item: item, space: space, session: session)
                                        } label: {
                                            PhotoCell(item: item, loader: session.loader, side: side)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        } header: {
                            header(bucket)
                        }
                        .task { await store.loadBucket(bucket.key) }
                    }
                }
            }
            .refreshable { await store.refresh() }
        }
    }

    #if os(iOS)
    /// Pinned above the grid, matching Synology's "Photo Backup Complete" row —
    /// but this one stays put and reports failures instead of vanishing.
    private func backupBanner(_ engine: BackupEngine) -> some View {
        Button { showBackup = true } label: {
            HStack(spacing: 10) {
                Image(systemName: engine.progress.isComplete
                      ? "checkmark.icloud.fill" : "icloud.and.arrow.up")
                    .foregroundStyle(engine.progress.isComplete ? Color.green : Color.accentColor)
                Text(engine.progress.summary).font(.subheadline)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.35))
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
        // The space switcher, matching Synology's nav-title chevron: this is
        // where Personal ↔ Family Shared happens.
        ToolbarItem(placement: .principal) {
            Menu {
                ForEach(session.spaces) { candidate in
                    Button {
                        session.selectedSpace = candidate
                    } label: {
                        Label(
                            candidate.name,
                            systemImage: candidate.kind == .personal ? "person.crop.square" : "person.2"
                        )
                    }
                }
            } label: {
                VStack(spacing: 0) {
                    Text("Photos").font(.headline)
                    HStack(spacing: 3) {
                        Text(space.name).font(.caption)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Zoom", selection: Binding(
                    get: { store?.zoom ?? .day },
                    set: { newZoom in Task { await store?.setZoom(newZoom) } }
                )) {
                    Text("Year").tag(TimelineZoom.year)
                    Text("Month").tag(TimelineZoom.month)
                    Text("Day").tag(TimelineZoom.day)
                }
                Picker("Columns", selection: $columns) {
                    ForEach([2, 3, 4, 5], id: \.self) { Text("\($0) across").tag($0) }
                }
                Divider()
                Button {
                    showSpaces = true
                } label: {
                    Label("Manage Spaces…", systemImage: "person.2.badge.gearshape")
                }
                #if os(iOS)
                Button {
                    showBackup = true
                } label: {
                    Label("Backup…", systemImage: "icloud.and.arrow.up")
                }
                #endif
            } label: {
                Image(systemName: "square.grid.2x2")
            }
        }
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
