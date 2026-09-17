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
    private(set) var hasLoaded = false

    private weak var session: AppSession?
    /// When the list was last answered, for `isStale`.
    private var fetchedAt: Date?

    init(session: AppSession) { self.session = session }

    /// Whether it is worth asking again.
    ///
    /// Albums live on the NAS against the account, not the device, so every
    /// device a person signs in on is already looking at the same list — but
    /// only as of the last time it asked. This is what makes that "already"
    /// true in practice rather than in principle: make an album on the phone
    /// and the iPad, sitting on the same page, went on showing the list it
    /// fetched when the tab was first built. The data was never out of sync;
    /// the screen was.
    ///
    /// A minute, matching the collections beside it, so flipping between tabs
    /// doesn't put a run of identical queries on a J4125.
    var isStale: Bool {
        guard let fetchedAt else { return true }
        return Date().timeIntervalSince(fetchedAt) > 60
    }

    func refreshIfStale() async {
        guard isStale else { return }
        await refresh()
    }

    func refresh() async {
        guard let client = session?.client else { return }
        // Only the first time. A refresh behind a list that is already on
        // screen must not announce itself — this drives the empty state, and
        // flipping it on every poll would make the page flicker between having
        // albums and deciding whether it has any.
        if !hasLoaded { isLoading = true }
        defer { isLoading = false }
        do {
            // Assigned only on success. A blip should cost you the update,
            // never the list you were looking at.
            albums = try await client.albums().albums
            hasLoaded = true
            fetchedAt = Date()
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

/// Where a tap on a shared album goes.
///
/// Carries the id rather than the `SpaceDTO`, because a pushed value is a
/// snapshot taken at the moment of the tap, and a shared album can be renamed
/// from inside itself. Resolving the id against the session on every body keeps
/// the title honest — the same staleness that once made a rename look as though
/// it hadn't taken.
struct SharedAlbumRoute: Hashable {
    let spaceID: UUID
}

/// Albums — what the library noticed, what you filed by hand, and what the
/// family shares.
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
    /// How many distinct places the library knows, for the Places row.
    ///
    /// Fetched here rather than added to the collections payload: the endpoint
    /// already exists and Search already calls it, and one small request is a
    /// cheaper thing to own than another field on a response that four clients
    /// decode.
    @State private var placeTotal = 0
    /// The place the Places list handed back, pushed as its own screen.
    @State private var pickedPlace: String?
    @Environment(\.scenePhase) private var scenePhase

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
        // Shared albums count, on the platforms that list them here. Without
        // this, someone whose whole use of the app is one family album saw
        // "Nothing to show yet" on the page their album lives on.
        #if !os(macOS)
        guard session.sharedSpaces.isEmpty else { return false }
        #endif
        return store.albums.isEmpty && (collections.page?.isEmpty ?? true)
    }

    var body: some View {
        Group {
            if let store {
                if hasNothing {
                    // Says what the page is *for*, not just that it is empty.
                    // "No albums yet" over a library that has plenty of photos
                    // reads as a fault; the truth is that trips and occasions
                    // need a few months of photographs behind them before there
                    // is anything to notice.
                    VStack(spacing: 0) {
                        ContentUnavailableView {
                            Label("Nothing to show yet", systemImage: "sparkles.rectangle.stack")
                        } description: {
                            Text(
                                "Trips, holidays and the days worth keeping appear here on "
                                + "their own as your library grows. You can also make an album "
                                + "by hand at any time."
                            )
                        } actions: {
                            Button("New Album") { showCreate = true }
                                .buttonStyle(.borderedProminent)
                        }
                        // The utilities stay reachable. They are the one thing
                        // that works on day one, and burying them behind an
                        // empty state would make Recently Deleted unreachable
                        // exactly when somebody has just deleted something.
                        if let space = session.personalSpace, let found = collections?.page {
                            utilities(found, space: space)
                                .padding(.bottom, spacing)
                        }
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
        .navigationDestination(item: $pickedPlace) { place in
            if let space = session.personalSpace {
                CollectionDetailView(
                    session: session, space: space,
                    // `.revisit` is the kind that means "everything from one
                    // place, whenever it was" — exactly this, and already
                    // handled end to end.
                    collection: CollectionSummary(
                        kind: .revisit, key: place, title: place,
                        subtitle: nil, count: 0, coverAssetIDs: []
                    )
                )
            }
        }
        .task {
            let created = store ?? AlbumStore(session: session)
            store = created
            await created.refresh()
        }
        .task(id: session.personalSpace?.id) {
            guard let space = session.personalSpace, let client = session.client else { return }
            // One row's worth: the count, not the list. The list is fetched by
            // the screen behind the row, and only if somebody opens it.
            placeTotal = (try? await client.places(spaceID: space.id, limit: 1))?.total ?? 0
        }
        // Keyed on the space so switching personal libraries rebuilds it, and
        // separate from the albums load because either can fail alone.
        .task(id: session.personalSpace?.id) {
            guard let space = session.personalSpace else { return }
            let created = CollectionsStore(session: session, spaceID: space.id)
            collections = created
            await created.refresh()
        }
        // Coming back to the tab, or to the app, should not mean coming back to
        // a page somebody else changed an hour ago on a different device. The
        // collections are computed on the NAS from one library, so every
        // platform already agrees about *what* they are — this is what makes
        // them agree about *when*.
        // Albums alongside the collections, and that is the fix rather than an
        // afterthought: these three triggers existed and asked only about the
        // half of the page the server computes. The half you make yourself —
        // the albums — was fetched once when the tab was built and then never
        // again, so an album created on another device showed up on this one
        // only after the view happened to be torn down and rebuilt.
        .onAppear {
            Task { await collections?.refreshIfStale() }
            Task { await store?.refreshIfStale() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await collections?.refreshIfStale() }
            Task { await store?.refreshIfStale() }
        }
        // The backstop, for a device that is simply left on the page — an Apple
        // TV, or a Mac in a corner. It has no pull-to-refresh to reach for, and
        // half of what this page shows depends on what day it is.
        //
        // Ten minutes rather than the timeline's fifteen seconds: this is a
        // handful of aggregate queries where `/changes` is a cursor comparison,
        // and nothing here is urgent enough to be worth asking more often.
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600_000_000_000)
                guard !Task.isCancelled else { return }
                await collections?.refreshIfStale()
                await store?.refreshIfStale()
            }
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
                        // First, and above the hero, because it answers a
                        // different question from everything below it. The rest
                        // of this page is about remembering; this one is about
                        // reassurance — "did the photographs I took this week
                        // actually get here" — and somebody asking that should
                        // not have to scroll past a card about 2019.
                        standing(found, space: space)
                        automatic(found, space: space)
                    }
                    manual(store, side: side)
                    sharedAlbums()
                    if let space = session.personalSpace {
                        places(space: space)
                    }
                    if let space = session.personalSpace, let found = collections?.page {
                        utilities(found, space: space)
                    }
                }
                .padding(.vertical, spacing)
            }
            .refreshable {
                await store.refresh()
                await collections?.refresh()
            }
        }
    }


    /// The two shelves that are always there.
    ///
    /// Everything below these is the library's opinion — a trip it noticed, a
    /// day it thought was busy, a place you haven't been. These two are not
    /// opinions. One is "did my photographs get here", the other is "the ones I
    /// said I liked", and both are true on the first day and on the ten
    /// thousandth. A page made only of suggestions has nothing to stand on when
    /// it has nothing to suggest.
    ///
    /// Above the hero deliberately. The hero is the most interesting thing
    /// today; these are the things somebody came to the page *for*, and making
    /// them scroll past a card about 2019 to reach one is the wrong order.
    @ViewBuilder
    private func standing(_ found: CollectionsResponse, space: SpaceDTO) -> some View {
        let shelves = [found.recentlyAdded, found.favourites].compactMap { $0 }
        if !shelves.isEmpty {
            VStack(spacing: 8) {
                ForEach(shelves, id: \.key) { shelf in
                    NavigationLink {
                        CollectionDetailView(session: session, space: space, collection: shelf)
                    } label: {
                        CollectionRowCard(collection: shelf, loader: session.loader)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, spacing)
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

        if !found.revisits.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("You haven't been in a while")
                ForEach(found.revisits) { place in
                    NavigationLink {
                        CollectionDetailView(session: session, space: space, collection: place)
                    } label: {
                        CollectionRowCard(collection: place, loader: session.loader)
                            .padding(.horizontal, spacing)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
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

    /// What the family shares, on the same page as what you filed yourself.
    ///
    /// These had a tab of their own. It was the wrong shape twice over: a whole
    /// tab that was empty for anyone who shares nothing, and — for anyone who
    /// does — a second place to go looking for "a set of photos with a name on
    /// it", which is exactly what an album is. Photos puts Shared Albums on the
    /// same page as your own albums, and it is right: the thing that differs is
    /// who can see them, not what they are.
    ///
    /// Below your own albums rather than above. Yours are the ones you reach
    /// for daily; these are the ones you visit when somebody adds to them, and
    /// the notification is what sends you.
    ///
    /// Not on a Mac. A window has a sidebar, and the sidebar already gives every
    /// shared album a row of its own — putting them here as well would be the
    /// same list twice, and these rows would be the dead half of it, since the
    /// destination that answers them belongs to the tab bar's stack.
    @ViewBuilder
    private func sharedAlbums() -> some View {
        #if !os(macOS)
        let shared = session.sharedSpaces
        if !shared.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Shared Albums")
                VStack(spacing: 8) {
                    ForEach(shared) { space in
                        NavigationLink(value: SharedAlbumRoute(spaceID: space.id)) {
                            sharedAlbumRow(space)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, spacing)
            }
        }
        #endif
    }

    #if !os(macOS)
    private func sharedAlbumRow(_ space: SpaceDTO) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 17))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(
                    .quaternary.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(space.name)
                    .font(.system(.body, design: .default, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                // The people, not the photographs. A shared album's count
                // changes whenever anyone adds anything, so a number of photos
                // here would be wrong more often than right — and who is in it
                // is the fact that makes it different from an album of your own.
                Text(
                    space.memberCount == 1
                        ? "Just you" : "\(space.memberCount) people"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(
            .quaternary.opacity(0.35),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .contentShape(Rectangle())
    }
    #endif

    /// Set with a little more care than a list header usually gets: tighter
    /// tracking and a touch more weight, because these are the only words on
    /// the page that aren't either a photograph or a fact about one.
    /// A way in by *where*, which for an old library is often the only way in
    /// somebody has.
    ///
    /// "Somewhere near the lake, a few summers ago" is a question a person can
    /// actually ask; "August 2021" usually isn't. Every photograph with GPS
    /// already carries a place name from import, so this costs nothing to offer
    /// and gets better as the library grows.
    ///
    /// Reuses Search's list rather than growing a second one, and a picked
    /// place opens as a `revisit` collection, which is already keyed by place
    /// name and already knows how to fetch one. Nothing new on the server.
    @ViewBuilder
    private func places(space: SpaceDTO) -> some View {
        if placeTotal > 0 {
            NavigationLink {
                AllPlacesView(session: session, space: space, total: placeTotal) { name in
                    pickedPlace = name
                }
            } label: {
                utilityRow("Places", systemImage: "map", count: placeTotal)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, spacing)
        }
    }

    /// The file-shaped things, at the bottom, behind one door each.
    ///
    /// Apple gives media types a section apiece and the page becomes a filing
    /// cabinet. They are a filter over what you already have, not a thing that
    /// happened, so they sit below everything that did.
    @ViewBuilder
    private func utilities(_ found: CollectionsResponse, space: SpaceDTO) -> some View {
        VStack(spacing: 0) {
            if !found.mediaTypes.isEmpty {
                NavigationLink {
                    MediaTypesView(session: session, space: space, types: found.mediaTypes)
                } label: {
                    // The photographs behind them, not how many categories
                    // there are. "Media Types · 6" meaning six kinds sits in the
                    // same column as "Recently Deleted · 3" meaning three
                    // photos, and one of those readings has to win.
                    utilityRow(
                        "Media Types", systemImage: "square.grid.2x2",
                        count: found.mediaTypes.reduce(0) { $0 + $1.count }
                    )
                }
                .buttonStyle(.plain)
            }
            if let deleted = found.recentlyDeleted {
                NavigationLink {
                    RecentlyDeletedView(session: session, space: space)
                } label: {
                    utilityRow("Recently Deleted", systemImage: "trash", count: deleted.count)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, spacing)
    }

    private func utilityRow(_ title: String, systemImage: String, count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)
            Text(title)
                .font(.system(.body, design: .default, weight: .medium))
                .foregroundStyle(.primary)
            Spacer()
            Text("\(count)")
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }

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
