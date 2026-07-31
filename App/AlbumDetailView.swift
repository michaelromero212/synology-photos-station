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
    @State private var showRename = false
    @State private var newName = ""
    #if os(iOS)
    @State private var showPicker = false
    #endif

    private let columns = 4
    private let spacing: CGFloat = 2

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                ProgressView()
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label("Empty album", systemImage: "rectangle.stack")
                } description: {
                    Text("Add photos from this device and they'll appear here.")
                } actions: {
                    #if os(iOS)
                    Button("Add Photos") { showPicker = true }
                        .buttonStyle(.borderedProminent)
                    #endif
                }
            } else {
                grid
            }
        }
        .navigationTitle(album.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    #if os(iOS)
                    Button {
                        showPicker = true
                    } label: {
                        Label("Add Photos", systemImage: "plus")
                    }
                    #endif
                    Button {
                        newName = album.name
                        showRename = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showPicker) {
            if let space = session.personalSpace {
                // Uploads land in your own library first, then join the album.
                // An album is a view onto photos, never a place they live —
                // otherwise a photo could exist only inside a collection.
                LibraryPickerView(session: session, space: space) { _ in
                    showPicker = false
                    Task { await addRecentUploads(to: space) }
                } onCancel: {
                    showPicker = false
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
    }

    private var grid: some View {
        GeometryReader { proxy in
            let side = (proxy.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columns),
                    spacing: spacing
                ) {
                    ForEach(items) { item in
                        if let space = session.spaces.first(where: { $0.id == item.spaceID }) {
                            NavigationLink {
                                AssetDetailView(item: item, space: space, session: session)
                            } label: {
                                PhotoCell(item: item, loader: session.loader, side: side)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
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

    #if os(iOS)
    /// After the picker uploads into the space, pull the newest placements in
    /// and attach them.
    ///
    /// Reads the space's own timeline rather than tracking ids through the
    /// upload: the picker's job is to get photos into a library, and an album
    /// is a second, separate step that shouldn't complicate it.
    private func addRecentUploads(to space: SpaceDTO) async {
        guard let client = session.client else { return }
        do {
            let existing = Set(items.map(\.id))
            let manifest = try await client.timeline(spaceID: space.id, zoom: TimelineZoom.day)
            var candidates: [UUID] = []
            for bucket in manifest.buckets.prefix(3) {
                let page = try await client.bucket(spaceID: space.id, key: bucket.key, zoom: TimelineZoom.day)
                candidates.append(contentsOf: page.items.map(\.id).filter { !existing.contains($0) })
            }
            guard !candidates.isEmpty else { return }
            album = try await client.addToAlbum(
                album.id, AlbumAssetsRequest(spaceAssetIDs: candidates)
            )
            await load()
            await store.refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
    #endif
}
