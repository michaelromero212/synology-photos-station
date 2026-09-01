import FrameStationAPI
import FrameStationKit
import Foundation
import Observation
import SwiftUI

/// The automatic half of the Albums page.
///
/// Everything here is computed by the server from dates and coordinates already
/// in the library — no model, nothing to train, nothing that has to finish
/// overnight before the page works.
@Observable
@MainActor
final class CollectionsStore {
    private(set) var page: CollectionsResponse?
    private(set) var isLoading = false
    /// Whether an answer has ever arrived. Distinct from `page != nil`, which
    /// cannot tell "nothing yet" from "nothing here" — and the page needs that
    /// difference to decide between a spinner and an empty state.
    private(set) var hasLoaded = false

    private weak var session: AppSession?
    private let spaceID: UUID
    /// When the page was last answered, and for which calendar day.
    private var fetchedAt: Date?
    private var fetchedFor: String?

    init(session: AppSession, spaceID: UUID) {
        self.session = session
        self.spaceID = spaceID
    }

    /// Whether it is worth asking again.
    ///
    /// Two reasons it can be. The library may have changed — somebody named an
    /// occasion on another device, or a backup finished — and the answer is
    /// only ever as fresh as the last request. And the *day* may have changed,
    /// which matters more here than anywhere else in the app: half this page is
    /// built from what today is, so a device left on overnight would go on
    /// offering yesterday's "on this day" until somebody touched it. An Apple
    /// TV is exactly that device, and it has no pull-to-refresh to fall back on.
    var isStale: Bool {
        guard let fetchedAt, fetchedFor == Self.dayStamp() else { return true }
        return Date().timeIntervalSince(fetchedAt) > 60
    }

    static func dayStamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Asks again only when it is worth it, so switching tabs back and forth
    /// doesn't put a run of identical queries on a J4125.
    func refreshIfStale() async {
        guard isStale else { return }
        await refresh()
    }

    func refresh() async {
        guard let client = session?.client else { return }
        if page == nil { isLoading = true }
        defer { isLoading = false }
        // Failure is quiet, but it must not be destructive. Assigning the
        // result straight through meant one failed pull-to-refresh replaced a
        // good page with nil — and the page above, seeing nothing, replaced
        // itself with the "no albums yet" empty state. A blip should cost you
        // the update, never the screen.
        if let fresh = try? await client.collections(spaceID: spaceID) {
            page = fresh
            hasLoaded = true
            fetchedAt = Date()
            fetchedFor = Self.dayStamp()
        }
    }
}

/// One collection's cover, or several of them cycling.
///
/// Falls back to a flat fill rather than a spinner: a card that is briefly
/// plain reads as a photograph still arriving, where a spinner in a grid of
/// photographs reads as something being wrong.
///
/// Cycling is opt-in and only the hero asks for it. One card carrying motion
/// reads as alive; a shelf of them crossfading at different offsets reads as a
/// screensaver, and each rotating card costs five thumbnails where a still one
/// costs a single.
struct CollectionCover: View {
    let assetIDs: [UUID]
    let loader: ThumbnailLoader?
    var size: Int = 512
    /// Seconds each photograph holds before the next fades in. Nil holds on the
    /// first and never moves.
    var cycle: Double?

    @State private var images: [PlatformImage] = []
    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isCycling: Bool { cycle != nil && !reduceMotion && images.count > 1 }

    var body: some View {
        // The photographs go in an `overlay` on a plain fill rather than beside
        // it in a `ZStack`, and this is not a stylistic choice.
        //
        // `scaledToFill` makes an image *larger* than the space it was offered,
        // which is what cropping means. A ZStack then sizes itself to its
        // largest child — the oversized image — so the card grew past its own
        // bounds and everything anchored to its bottom edge, the whole title
        // block, was pushed outside the clip and thrown away. Overlay content
        // is measured against the view it covers and never resizes it.
        // `PhotoCell` carries a comment about the same trap; this is the second
        // time it has cost a layout.
        Rectangle()
            .fill(.quaternary)
            .overlay {
                ForEach(Array(images.enumerated()), id: \.offset) { position, image in
                    picture(image)
                        .opacity(position == index ? 1 : 0)
                }
            }
            .clipped()
        // Long and eased: a crossfade you can see happening is a transition,
        // where one you only notice afterwards is atmosphere. This wants the
        // second.
        .animation(.easeInOut(duration: 1.4), value: index)
        .animation(.easeOut(duration: 0.3), value: images.count)
        .task(id: assetIDs) { await load() }
        .task(id: isCycling) {
            guard let cycle, isCycling else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(cycle * 1_000_000_000))
                guard !Task.isCancelled else { return }
                index = (index + 1) % images.count
            }
        }
    }

    @ViewBuilder
    private func picture(_ platformImage: PlatformImage) -> some View {
        #if canImport(UIKit)
        Image(uiImage: platformImage).resizable().scaledToFill()
        #else
        Image(nsImage: platformImage).resizable().scaledToFill()
        #endif
    }

    /// The first photograph is fetched on its own and drawn as soon as it
    /// lands; the rest follow behind it. Asking for five at once would make
    /// every card wait for the slowest of five before showing anything.
    private func load() async {
        guard let loader, let first = assetIDs.first else { return }
        images = []
        index = 0
        if let cover = await loader.thumbnail(assetID: first, size: size) {
            images = [cover]
        }
        guard cycle != nil else { return }
        for assetID in assetIDs.dropFirst() {
            guard !Task.isCancelled else { return }
            if let next = await loader.thumbnail(assetID: assetID, size: size) {
                images.append(next)
            }
        }
    }
}

/// The single card at the top of the page.
///
/// One hero rather than a carousel of nine competing for the same glance. The
/// server has already decided what it should be, so this draws what it is given
/// instead of re-litigating the choice on the device.
struct CollectionHeroCard: View {
    let collection: CollectionSummary
    let loader: ThumbnailLoader?

    var body: some View {
        Color.clear
            .aspectRatio(5 / 4, contentMode: .fit)
            .overlay {
                ZStack(alignment: .bottomLeading) {
                    CollectionCover(
                        assetIDs: collection.coverAssetIDs, loader: loader, cycle: 5.5
                    )

                    // Three stops rather than two. A straight black-to-clear ramp
                    // greys the middle of the photograph to hold text that only
                    // sits at the bottom; weighting it low keeps the picture and
                    // still carries white type.
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.85), location: 0),
                            .init(color: .black.opacity(0.45), location: 0.22),
                            .init(color: .clear, location: 0.58),
                        ],
                        startPoint: .bottom, endPoint: .top
                    )

                    VStack(alignment: .leading, spacing: 5) {
                        Text(kicker)
                            .font(.caption2.weight(.heavy))
                            .tracking(1.4)
                            .foregroundStyle(.tint)
                        Text(collection.title)
                            .font(.system(.title, design: .default, weight: .bold))
                            .tracking(-0.4)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        // The hero is the one card with no count badge beside
                        // it, so it carries the count in its own line. The rows
                        // show it on the right, which is why the server stopped
                        // putting it in the subtitle — a trip that said its
                        // count twice was also the trip whose dates got
                        // truncated to make room.
                        Text(detail)
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            // A hairline, not a border. Photographs meeting a black ground with
            // no edge look like holes cut in the page rather than prints on it.
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.09), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var detail: String {
        let counted = collection.count == 1 ? "1 photo" : "\(collection.count) photos"
        return [collection.subtitle, counted].compactMap { $0 }.joined(separator: " · ")
    }

    /// Says what *kind* of thing you are looking at, so a hero that changes
    /// daily never leaves you guessing why this card is the one.
    private var kicker: String {
        switch collection.kind {
        case .onThisDay: return "ON THIS DAY"
        case .anniversary: return "THIS WEEK, BACK THEN"
        case .trip: return "A TRIP"
        case .day: return "THAT DAY"
        case .revisit: return "YOU HAVEN'T BEEN IN A WHILE"
        case .mediaType: return "EVERYTHING OF ONE KIND"
        case .season: return "LOOKING BACK"
        case .recentlyDeleted: return "REMOVED"
        }
    }
}

/// A day or a trip, as a row rather than a tile.
///
/// Rows rather than a second shelf: two horizontal scrollers stacked is a lot
/// of sideways in one screen, and a day has a date and a place worth reading
/// rather than cropping.
struct CollectionRowCard: View {
    let collection: CollectionSummary
    let loader: ThumbnailLoader?

    var body: some View {
        HStack(spacing: 14) {
            // Large enough to be a photograph rather than an icon. At the 54pt
            // it started out, every cover read as a coloured square and the row
            // looked like a settings screen.
            CollectionCover(
                assetIDs: collection.coverAssetIDs, loader: loader, size: 256
            )
            .frame(width: 76, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.35), radius: 5, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(collection.title)
                    .font(.system(.body, design: .default, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let subtitle = collection.subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 10)

            Text("\(collection.count)")
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// The photos inside one collection.
///
/// Flat and date-ordered, like search results: a collection is not a library,
/// and day headers over fourteen photos from one afternoon would be more chrome
/// than content. Ascending here rather than descending — a day reads forward.
struct CollectionDetailView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO
    let collection: CollectionSummary

    @State private var items: [TimelineItem] = []
    @State private var isLoading = true
    @State private var failure: String?

    private let spacing: CGFloat = PhotoGridMetrics.spacing

    var body: some View {
        Group {
            if isLoading, items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure, items.isEmpty {
                ContentUnavailableView(
                    "Can't Open This", systemImage: "wifi.slash", description: Text(failure)
                )
            } else {
                grid
            }
        }
        .navigationTitle(collection.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    private var grid: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let subtitle = collection.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }

                    PhotoGridSection(
                        entries: items.map { GridEntry.item($0) },
                        width: proxy.size.width,
                        targetHeight: PhotoGridMetrics.targetRowHeight(for: .day),
                        spacing: spacing,
                        columns: TimelineZoom.day.columns
                    ) { entry, size in
                        if case .item(let item) = entry {
                            NavigationLink {
                                AssetDetailView(
                                    item: item, space: space, session: session,
                                    pageItems: items
                                )
                            } label: {
                                PhotoCell(item: item, loader: session.loader, size: size)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, spacing)
                }
            }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await client.collectionItems(
                spaceID: space.id, kind: collection.kind, key: collection.key
            ).items
            failure = nil
        } catch {
            failure = ConnectionMonitor.mediaMessage(for: error, state: nil)
        }
    }
}

#if !os(tvOS)
/// Giving a day the name it actually had.
///
/// The library can work out that a day was busy, where it happened and how much
/// of it was video. It cannot work out that it was an engagement party — nothing
/// in a photograph's metadata says so, and a model guessing from faces and
/// scenery would land on "Saturday Afternoon" and be confidently beside the
/// point.
///
/// So the app finds the occasion and the person supplies the meaning, once. That
/// is the thing a library you own can do that a guessing one cannot: be right,
/// and stay right every year afterwards.
struct NameOccasionSheet: View {
    let session: AppSession
    let spaceID: UUID
    let collection: CollectionSummary
    let onFinished: (Bool) -> Void

    @State private var name: String
    @State private var everyYear: Bool
    @State private var isSaving = false
    @State private var failure: String?

    init(
        session: AppSession, spaceID: UUID, collection: CollectionSummary,
        onFinished: @escaping (Bool) -> Void
    ) {
        self.session = session
        self.spaceID = spaceID
        self.collection = collection
        self.onFinished = onFinished
        // Pre-filled when renaming, so correcting a typo isn't retyping.
        _name = State(initialValue: collection.isNamed ? collection.title : "")
        // Suggested, not assumed. A date that comes round every year is usually
        // a birthday or an anniversary, and that is worth defaulting to — but a
        // party on the same date once is still a party, so it stays a switch.
        _everyYear = State(initialValue: collection.recursAnnually && !collection.isNamed)
    }

    /// The first day of the run, which is what the server keys a name to.
    private var day: String {
        collection.key.components(separatedBy: "..").first ?? collection.key
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Sarah's engagement", text: $name)
                        .autocorrectionDisabled(false)
                        .submitLabel(.done)
                        .onSubmit(save)
                } header: {
                    Text("What was this?")
                } footer: {
                    if let subtitle = collection.subtitle {
                        Text(subtitle)
                    }
                }

                Section {
                    Toggle("Every year on this date", isOn: $everyYear)
                } footer: {
                    if collection.recursAnnually {
                        Text(
                            "You have photographs on this date most years — so this "
                            + "is probably a birthday or an anniversary."
                        )
                    } else {
                        Text(
                            "On for a birthday or an anniversary. Off for something "
                            + "that happened once."
                        )
                    }
                }

                if collection.isNamed {
                    Section {
                        Button(role: .destructive) {
                            name = ""
                            save()
                        } label: {
                            Text("Remove Name")
                        }
                    } footer: {
                        Text("The day goes back to whatever the library works out for it.")
                    }
                }

                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .disabled(isSaving)
            .navigationTitle(collection.isNamed ? "Rename" : "Name This Day")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onFinished(false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func save() {
        guard let client = session.client else { return }
        isSaving = true
        failure = nil
        Task {
            defer { isSaving = false }
            do {
                try await client.nameOccasion(
                    spaceID: spaceID, day: day, name: name, everyYear: everyYear
                )
                onFinished(true)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
#endif

extension View {
    /// Adds "Name this day" to a card, without adding anything to the card.
    ///
    /// A context menu rather than a visible button: the page's whole argument is
    /// that it shows few things, and hanging a control off every row to support
    /// an action most people take once would undo that. Long-press is where iOS
    /// keeps secondary actions, and it costs the layout nothing.
    @ViewBuilder
    func nameable(
        _ collection: CollectionSummary,
        onName: @escaping (CollectionSummary) -> Void
    ) -> some View {
        #if os(tvOS)
        self
        #else
        contextMenu {
            Button {
                onName(collection)
            } label: {
                Label(
                    collection.isNamed ? "Rename" : "Name This Day",
                    systemImage: collection.isNamed ? "pencil" : "textformat"
                )
            }
        }
        #endif
    }
}

/// What was removed, and the way back.
///
/// Personal space only — shared-space removals are recovered through File
/// Station, which is why the bin carries DSM's own name. Anything DSM has
/// already reclaimed is absent rather than offered, so the list never promises
/// a restore it cannot perform.
struct RecentlyDeletedView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO

    @State private var items: [TimelineItem] = []
    @State private var isLoading = true
    @State private var selection: Set<UUID> = []
    @State private var isRestoring = false
    @State private var notice: String?

    private let spacing: CGFloat = PhotoGridMetrics.spacing

    var body: some View {
        Group {
            if isLoading, items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Removed", systemImage: "trash")
                } description: {
                    Text("Photos you remove from \(space.name) wait here before they go for good.")
                }
            } else {
                grid
            }
        }
        .navigationTitle("Recently Deleted")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !selection.isEmpty {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isRestoring ? "Restoring…" : "Restore \(selection.count)") {
                        restore()
                    }
                    .disabled(isRestoring)
                    .fontWeight(.semibold)
                }
            }
        }
        .task { await load() }
    }

    private var grid: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let notice {
                        Text(notice)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    // No countdown. The bin is DSM's, emptied on its schedule,
                    // and a number this app cannot enforce would be a promise
                    // it has no way to keep.
                    Text("Tap to choose what to put back.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12).padding(.bottom, 6)

                    PhotoGridSection(
                        entries: items.map { GridEntry.item($0) },
                        width: proxy.size.width,
                        targetHeight: PhotoGridMetrics.targetRowHeight(for: .day),
                        spacing: spacing,
                        columns: TimelineZoom.day.columns
                    ) { entry, size in
                        if case .item(let item) = entry {
                            PhotoCell(item: item, loader: session.loader, size: size)
                                .opacity(selection.contains(item.assetID) ? 1 : 0.55)
                                .overlay(alignment: .bottomTrailing) {
                                    if selection.contains(item.assetID) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.white, .tint)
                                            .padding(5)
                                    }
                                }
                                .onTapGesture {
                                    if selection.contains(item.assetID) {
                                        selection.remove(item.assetID)
                                    } else {
                                        selection.insert(item.assetID)
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, spacing)
                }
            }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        isLoading = true
        defer { isLoading = false }
        items = (try? await client.deletedItems(spaceID: space.id).items) ?? []
    }

    private func restore() {
        guard let client = session.client, !selection.isEmpty else { return }
        isRestoring = true
        let chosen = Array(selection)
        Task {
            defer { isRestoring = false }
            let result = try? await client.restore(spaceID: space.id, assetIDs: chosen)
            let n = result?.updated ?? 0
            notice = n == 1 ? "1 photo put back." : "\(n) photos put back."
            selection.removeAll()
            await load()
        }
    }
}

/// Everything of one shape. Behind one door, not twelve.
struct MediaTypesView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO
    let types: [CollectionSummary]

    var body: some View {
        List(types) { type in
            NavigationLink {
                CollectionDetailView(session: session, space: space, collection: type)
            } label: {
                CollectionRowCard(collection: type, loader: session.loader)
                    .padding(.vertical, 4)
            }
        }
        .navigationTitle("Media Types")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
