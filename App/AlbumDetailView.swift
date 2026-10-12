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
    @State private var showRename = false
    @State private var newName = ""
    @State private var confirmDelete = false
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
            // Only what you may do here: a viewer of a shared library gets no
            // menu at all, rather than one whose every item says no.
            if album.mayAdd || album.mayManage {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        #if os(iOS)
                        if album.mayAdd {
                            Button {
                                showPicker = true
                            } label: {
                                Label("Add Photos", systemImage: "plus")
                            }
                        }
                        #endif
                        if album.mayManage {
                            Button {
                                newName = album.name
                                showRename = true
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                confirmDelete = true
                            } label: {
                                Label("Delete Album", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete “\(album.name)”?", isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete Album", role: .destructive) {
                Task {
                    if await store.delete(album) { dismiss() }
                }
            }
        } message: {
            Text(album.deletionMessage(library: library))
        }
        #if os(iOS)
        .sheet(isPresented: $showPicker) {
            if let space = session.personalSpace {
                // Uploads land in your own library first, then join the album.
                // An album is a view onto photos, never a place they live —
                // otherwise a photo could exist only inside a collection. A
                // family album then shares them into its library.
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
        .alert("Rename Album", isPresented: $showRename) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { Task { await rename() } }
        }
        .overlay(alignment: .bottom) {
            if let lastError {
                Text(lastError).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
        .task { await load() }
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
                    if case .item(let item) = entry,
                       let space = session.spaces.first(where: { $0.id == item.spaceID }) {
                        NavigationLink {
                            AssetDetailView(item: item, space: space, session: session)
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
            items = try await client.albumItems(album.id).items
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func rename() async {
        guard let client = session.client else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            album = try await client.updateAlbum(album.id, UpdateAlbumRequest(name: trimmed))
            await store.refresh()
        } catch {
            lastError = error.localizedDescription
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

    /// The shared library a family album is in, by name.
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
