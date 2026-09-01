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

/// Albums — what the library noticed, and what you filed by hand.
///
/// Two halves. Above: collections the server worked out from dates and
/// coordinates — today in earlier years, days that stood out. Below: the albums
/// you made yourself.
///
/// The ordering is the argument. Apple's Albums tab reaches roughly twenty-five
/// rows before your own albums, most of them media types, and it reads as a
/// filing cabinet — organised by what a file *is* rather than by what happened.
/// So this opens on one hero, keeps the automatic sections few, drops any that
/// would be thin, and puts your own albums above the file-shaped stuff rather
/// than below it.
struct AlbumsView: View {
    @Bindable var session: AppSession

    @State private var store: AlbumStore?
    @State private var collections: CollectionsStore?
    @State private var showCreate = false
    /// The card being named, if any. Held here rather than per-card so only one
    /// sheet can ever be up.
    ///
    /// Declared on every platform even though only iOS and macOS can present the
    /// sheet: the call sites that assign it sit inside shared layout code, and
    /// gating the property alone left tvOS with closures referring to something
    /// that wasn't there. An unused optional is cheaper than a fourth `#if`.
    @State private var naming: CollectionSummary?

    private let columns = 2
    private let spacing: CGFloat = 14

    /// Whether there is genuinely nothing to draw.
    ///
    /// "Nothing" and "not yet" are different answers and this has to tell them
    /// apart: treating an unanswered collections request as empty put the "no
    /// albums yet" screen over a library that had plenty, every time the
    /// request was slow or failed. So both halves must have actually reported
    /// before this is allowed to be true.
    private var hasNothing: Bool {
        guard let store, !store.isLoading else { return false }
        guard let collections, collections.hasLoaded else { return false }
        return store.albums.isEmpty && (collections.page?.isEmpty ?? true)
    }

    var body: some View {
        Group {
            if let store {
                if hasNothing {
                    ContentUnavailableView {
                        Label("No albums yet", systemImage: "rectangle.stack")
                    } description: {
                        Text("Group photos by trip, person, or occasion — separate from the timeline.")
                    } actions: {
                        Button("New Album") { showCreate = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    page(store)
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
        #if !os(tvOS)
        .sheet(item: $naming) { collection in
            if let space = session.personalSpace {
                NameOccasionSheet(
                    session: session, spaceID: space.id, collection: collection
                ) { changed in
                    naming = nil
                    // Re-read rather than patch: the server decides what a day
                    // ends up called, and an annual name changes every year of
                    // it at once — not just the card that was tapped.
                    if changed { Task { await collections?.refresh() } }
                }
            }
        }
        #endif
        .task {
            let created = store ?? AlbumStore(session: session)
            store = created
            await created.refresh()
        }
        // Keyed on the space so switching personal libraries rebuilds it, and
        // separate from the albums load because either can fail alone.
        .task(id: session.personalSpace?.id) {
            guard let space = session.personalSpace else { return }
            let created = CollectionsStore(session: session, spaceID: space.id)
            collections = created
            await created.refresh()
        }
    }

    /// The page: what the library noticed, then what you filed.
    @ViewBuilder
    private func page(_ store: AlbumStore) -> some View {
        GeometryReader { proxy in
            let side = (proxy.size.width - spacing * CGFloat(columns + 1)) / CGFloat(columns)
            ScrollView {
                // Generous, and deliberately so. The page holds few things;
                // letting them sit apart is most of what stops it reading as a
                // list of settings.
                VStack(alignment: .leading, spacing: 30) {
                    if let space = session.personalSpace, let found = collections?.page {
                        automatic(found, space: space)
                    }
                    manual(store, side: side)
                }
                .padding(.vertical, spacing)
            }
            .refreshable {
                await store.refresh()
                await collections?.refresh()
            }
        }
    }

    /// Everything the server worked out. Each section is absent rather than
    /// empty when it found nothing — a heading with nothing under it is worse
    /// than no heading.
    @ViewBuilder
    private func automatic(_ found: CollectionsResponse, space: SpaceDTO) -> some View {
        if let hero = found.hero {
            NavigationLink {
                CollectionDetailView(session: session, space: space, collection: hero)
            } label: {
                CollectionHeroCard(collection: hero, loader: session.loader)
            }
            .buttonStyle(.plain)
            .nameable(hero) { naming = $0 }
            .padding(.horizontal, spacing)
        }

        // Trips before days: a fortnight away is a bigger thing than a busy
        // Saturday, and the page should be ordered by what mattered rather than
        // by what happened most recently.
        if !found.trips.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Trips")
                ForEach(found.trips) { trip in
                    NavigationLink {
                        CollectionDetailView(session: session, space: space, collection: trip)
                    } label: {
                        CollectionRowCard(collection: trip, loader: session.loader)
                            .padding(.horizontal, spacing)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .nameable(trip) { naming = $0 }
                }
            }
        }

        if !found.days.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Days worth keeping")
                ForEach(found.days) { day in
                    NavigationLink {
                        CollectionDetailView(session: session, space: space, collection: day)
                    } label: {
                        CollectionRowCard(collection: day, loader: session.loader)
                            .padding(.horizontal, spacing)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .nameable(day) { naming = $0 }
                }
            }
        }
    }

    @ViewBuilder
    private func manual(_ store: AlbumStore, side: CGFloat) -> some View {
        if !store.albums.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Your Albums")
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
                .padding(.horizontal, spacing)
            }
        }
    }

    /// Set with a little more care than a list header usually gets: tighter
    /// tracking and a touch more weight, because these are the only words on
    /// the page that aren't either a photograph or a fact about one.
    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(.title3, design: .default, weight: .bold))
            .tracking(-0.3)
            .padding(.horizontal, spacing)
            .padding(.bottom, 10)
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
