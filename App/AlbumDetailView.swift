import FrameStationAPI
import FrameStationKit
import Foundation
import Observation
import SwiftUI

/// One album's photos, in album order rather than by date.
struct AlbumDetailView: View {
    @Bindable var session: AppSession
    @State var album: AlbumDTO
    let store: AlbumStore

    @State private var items: [TimelineItem] = []
    @State private var isLoading = true
    @State private var lastError: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    /// Set by the settings when they delete the album, so this screen leaves
    /// once they have closed rather than out from under them.
    @State private var wasDeleted = false
    /// Whether this screen has asked the NAS for your libraries again. See
    /// `space(of:)`.
    @State private var refreshedSpaces = false
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @State private var showPicker = false
    #endif

    /// The library's own width, not a number of its own.
    ///
    /// This said 4, which was the library's width when it was written and
    /// silently stopped being it. A photo grid should be a photo grid wherever
    /// you meet one: opening an album and finding its tiles a different size
    /// from the timeline's, the search results' and a trip's is the kind of
    /// small wrongness that reads as carelessness without ever announcing what
    /// it was. Naming the source means the next change to the grid carries here
    /// on its own.
    private let columns = TimelineZoom.day.columns
    private let spacing: CGFloat = PhotoGridMetrics.spacing

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                ProgressView()
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label("Empty album", systemImage: "rectangle.stack")
                } description: {
                    Text(album.mayAdd
                        ? "Add photos from this device and they'll appear here."
                        : "Photos added to this album will appear here.")
                } actions: {
                    #if os(iOS)
                    if album.mayAdd {
                        Button("Add Photos") { showPicker = true }
                            .buttonStyle(.borderedProminent)
                    }
                    #endif
                }
            } else {
                grid
            }
        }
        .navigationTitle(album.name)
        // The floating tab bar is drawn over this — see `FloatingTabBar`.
        .floatingTabBarClearance()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            // Edit and Add, side by side the way the Albums page pairs its own
            // buttons. Edit is the album's settings — its name, who can see
            // it, deleting it — which lived behind an Edit mode on the Albums
            // page; here they belong to the album you're looking at. Always
            // there: someone who may not change an album is told who can.
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Edit") { showSettings = true }
                #if os(iOS)
                if album.mayAdd {
                    Button {
                        showPicker = true
                    } label: {
                        Label("Add Photos", systemImage: "plus")
                    }
                }
                #endif
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: settingsClosed) {
            AlbumSettingsSheet(
                session: session, album: album, store: store, library: library,
                onDeleted: { wasDeleted = true }
            ) { showSettings = false }
        }
        // A tapped "someone reported a photo" in an album you shared lands
        // here, and its Edit is where reported photos are reviewed. See
        // `AppSession.openShared`.
        .onChange(of: session.pendingReportReview, initial: true) { _, spaceID in
            guard let spaceID, spaceID == album.spaceID else { return }
            session.pendingReportReview = nil
            showSettings = true
        }
        #if os(iOS)
        .sheet(isPresented: $showPicker) {
            if let space = session.personalSpace {
                // Uploads land in your own library first, then join the album.
                // An album is a view onto photos, never a place they live —
                // otherwise a photo could exist only inside a collection. A
                // family album then shares them into its library, and an
                // album shared with people with its people.
                LibraryPickerView(session: session, space: space) { _ in
                    showPicker = false
                } onCancel: {
                    showPicker = false
                } onLanded: { placements in
                    Task { await add(placements) }
                }
            }
        }
        #endif
        .overlay(alignment: .bottom) {
            if let lastError {
                Text(lastError).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
        .task { await load() }
        // A photo deleted from the viewer, or added from another screen.
        // See `FollowsOwnChanges`.
        .modifier(FollowsOwnChanges(session: session) { await load() })
        // Photos added from the grid, a new name from another device, people
        // added or gone: the Albums page's list hears of it first. Followed
        // here, so the title and Edit never work from the album as it was when
        // this screen opened — Edit offered to share "its 0 items" with photos
        // in it.
        .onChange(of: store.albums) { _, albums in
            if let latest = albums.first(where: { $0.id == album.id }) { album = latest }
        }
        // An album's contents live on the NAS against the account, so adding to
        // one on the phone changes what this album *is* on every device signed
        // in to it. Opening it here asks — `.task` above runs each time the
        // screen is pushed — but a device left sitting on this screen while
        // another one adds to the album would go on showing what it fetched
        // when it arrived. Coming back to the app is the moment to ask again.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await load() }
        }
    }

    private var grid: some View {
        GeometryReader { proxy in
            ScrollView {
                // The same layout the timeline uses. An album that squared
                // everything off while the timeline kept shapes would be its own
                // inconsistency, inside one app rather than between two.
                PhotoGridSection(
                    entries: items.map(GridEntry.item),
                    width: proxy.size.width,
                    targetHeight: PhotoGridMetrics.targetRowHeight(for: .day),
                    spacing: spacing,
                    columns: columns
                ) { entry, size in
                    if case .item(let item) = entry {
                        NavigationLink {
                            AssetDetailView(item: item, space: space(of: item), session: session)
                        } label: {
                            PhotoCell(item: item, loader: session.loader, size: size)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            // Whose photo it is to take out of a family album
                            // is the NAS's call, and it says why when it's no.
                            if album.mayAdd {
                                Button(role: .destructive) {
                                    Task { await remove(item) }
                                } label: {
                                    // "Remove from Album", not "Delete" — the
                                    // photo stays in the library.
                                    Label("Remove from Album", systemImage: "minus.circle")
                                }
                            }
                        }
                    }
                }
            }
            .refreshable { await load() }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await client.albumItems(album.id).items
            // A library you joined on another device since this one last
            // asked would otherwise open as though it were the album's own.
            if !refreshedSpaces, fresh.contains(where: { item in
                item.spaceID != album.spaceID && !session.spaces.contains { $0.id == item.spaceID }
            }) {
                refreshedSpaces = true
                await session.refreshSpaces()
            }
            items = fresh
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The space a photo here is in, for the viewer: one of your libraries,
    /// usually.
    ///
    /// A photo in an album shared with people is in the album's own space,
    /// which the NAS never lists as a library, so that one is drawn from the
    /// album: shared, so what somebody added is theirs to remove, and anything
    /// yours to remove if you made the album. An album that was shared and
    /// isn't anymore keeps its photos in that space, with nobody else in it.
    /// Anything else opens to look at, not to change.
    private func space(of item: TimelineItem) -> SpaceDTO {
        if let known = session.spaces.first(where: { $0.id == item.spaceID }) { return known }
        if item.spaceID == album.spaceID {
            return SpaceDTO(
                id: item.spaceID, kind: .shared, name: album.name,
                role: album.mayManage ? .owner : album.mayAdd ? .contributor : .viewer,
                memberCount: (album.people?.count ?? 0) + 1
            )
        }
        let wasShared = album.spaceID == nil
        return SpaceDTO(
            id: item.spaceID, kind: wasShared ? .personal : .shared, name: album.name,
            role: wasShared ? .owner : .viewer, memberCount: 1
        )
    }

    /// After the settings close: back to the Albums page if they deleted the
    /// album or left it, otherwise the album as it now is, so a new name
    /// reaches the title. Its photos are asked for again too: sharing an album
    /// puts them in its own space, under new ids, and a reported photo can
    /// have been taken out.
    private func settingsClosed() {
        if wasDeleted {
            dismiss()
        } else {
            if let fresh = store.albums.first(where: { $0.id == album.id }) {
                album = fresh
            }
            Task { await load() }
        }
    }

    private func remove(_ item: TimelineItem) async {
        guard let client = session.client else { return }
        do {
            try await client.removeFromAlbum(album.id, placementID: item.id)
            await load()
            await store.refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The shared library a family album is in, by name. Nil for an album
    /// shared with people, which isn't in one.
    private var library: String? {
        guard let spaceID = album.spaceID else { return nil }
        return session.sharedSpaces.first { $0.id == spaceID }?.name
    }

    #if os(iOS)
    /// Adds exactly the photos the picker sent, once they're on the NAS.
    ///
    /// This used to add whatever was newest in the library's last three days.
    /// The picker closes before its uploads finish, so that was rarely what had
    /// been picked, and in a family album it would have shared the rest of
    /// those days with everyone.
    private func add(_ placements: [UUID]) async {
        guard !placements.isEmpty, let client = session.client else { return }
        do {
            album = try await client.addToAlbum(
                album.id, AlbumAssetsRequest(spaceAssetIDs: placements)
            )
            await load()
            await store.refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
    #endif
}
