import FrameStationAPI
import FrameStationKit
import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class AlbumStore {
    private(set) var albums: [AlbumDTO] = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    private weak var session: AppSession?
    init(session: AppSession) { self.session = session }

    func refresh() async {
        guard let client = session?.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            albums = try await client.albums().albums
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func create(name: String) async -> AlbumDTO? {
        guard let client = session?.client else { return nil }
        do {
            let album = try await client.createAlbum(CreateAlbumRequest(name: name))
            await refresh()
            return album
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func delete(_ album: AlbumDTO) async {
        guard let client = session?.client else { return }
        do {
            try await client.deleteAlbum(album.id)
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

/// Albums — collections you build by hand, cutting across dates.
struct AlbumsView: View {
    @Bindable var session: AppSession

    @State private var store: AlbumStore?
    @State private var showCreate = false

    private let columns = 2
    private let spacing: CGFloat = 14

    var body: some View {
        Group {
            if let store {
                if store.albums.isEmpty && !store.isLoading {
                    ContentUnavailableView {
                        Label("No albums yet", systemImage: "rectangle.stack")
                    } description: {
                        Text("Group photos by trip, person, or occasion — separate from the timeline.")
                    } actions: {
                        Button("New Album") { showCreate = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    grid(store)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Albums")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreate = true
                } label: {
                    Label("New Album", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            if let store {
                NewAlbumSheet(session: session, store: store) { showCreate = false }
            }
        }
        .task {
            let created = store ?? AlbumStore(session: session)
            store = created
            await created.refresh()
        }
    }

    private func grid(_ store: AlbumStore) -> some View {
        GeometryReader { proxy in
            let side = (proxy.size.width - spacing * CGFloat(columns + 1)) / CGFloat(columns)
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columns),
                    spacing: spacing
                ) {
                    ForEach(store.albums) { album in
                        NavigationLink {
                            AlbumDetailView(session: session, album: album, store: store)
                        } label: {
                            AlbumCard(album: album, side: side, loader: session.loader)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await store.delete(album) }
                            } label: {
                                Label("Delete Album", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(spacing)
            }
            .refreshable { await store.refresh() }
        }
    }
}

private struct AlbumCard: View {
    let album: AlbumDTO
    let side: CGFloat
    let loader: ThumbnailLoader?

    @State private var cover: PlatformImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                if let cover {
                    Image(platformImage: cover)
                        .resizable().scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: "rectangle.stack")
                        .font(.largeTitle).foregroundStyle(.tertiary)
                }
            }
            .frame(width: side, height: side)
            .clipped()

            Text(album.name).font(.subheadline.weight(.medium)).lineLimit(1)
            Text("\(album.itemCount) item\(album.itemCount == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: album.coverAssetID) {
            guard let assetID = album.coverAssetID, let loader else { return }
            cover = await loader.thumbnail(assetID: assetID, size: 512)
        }
    }
}

private struct NewAlbumSheet: View {
    @Bindable var session: AppSession
    let store: AlbumStore
    let onDone: () -> Void

    @State private var name = ""
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Iceland 2012", text: $name)
                } header: {
                    Text("Name")
                } footer: {
                    Text("Albums are private to you. Nobody else can see them, even for photos from a shared library.")
                }
            }
            .navigationTitle("New Album")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDone)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        isCreating = true
                        Task {
                            await store.create(
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                            isCreating = false
                            onDone()
                        }
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating
                    )
                }
            }
        }
    }
}
