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

    init(session: AppSession, spaceID: UUID) {
        self.session = session
        self.spaceID = spaceID
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
        }
    }
}

/// One collection's cover.
///
/// Falls back to a flat fill rather than a spinner: a card that is briefly
/// plain reads as a photo still arriving, where a spinner in a grid of
/// photographs reads as something being wrong.
struct CollectionCover: View {
    let assetID: UUID?
    let loader: ThumbnailLoader?
    var size: Int = 512

    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                #if canImport(UIKit)
                Image(uiImage: image).resizable().scaledToFill()
                #else
                Image(nsImage: image).resizable().scaledToFill()
                #endif
            }
        }
        .task(id: assetID) {
            guard let assetID, let loader else { return }
            if let loaded = await loader.thumbnail(assetID: assetID, size: size) {
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
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
        // A clear spacer sets the shape and the content overlays it. Putting
        // `.aspectRatio(_:contentMode: .fill)` on the stack itself made the card
        // grow past the screen edge instead: `fill` preserves the ratio by
        // expanding in *both* directions, so a full-width card became a
        // wider-than-full-width one and dragged the rows below it along.
        Color.clear
            .aspectRatio(5 / 4, contentMode: .fit)
            .overlay {
                ZStack(alignment: .bottomLeading) {
                    CollectionCover(assetID: collection.coverAssetID, loader: loader)

                    // A scrim, not a shadow. White text with a drop shadow
                    // disappears over a bright photograph, which is most of them.
                    LinearGradient(
                        colors: [.black.opacity(0.78), .black.opacity(0.15), .clear],
                        startPoint: .bottom, endPoint: .top
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(kicker)
                            .font(.caption2.weight(.bold))
                            .tracking(1.2)
                            .foregroundStyle(.tint)
                        Text(collection.title)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                        if let subtitle = collection.subtitle {
                            Text(subtitle)
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    private var kicker: String {
        switch collection.kind {
        case .onThisDay: return "ON THIS DAY"
        case .trip: return "TRIP"
        case .day: return "THAT DAY"
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
        HStack(spacing: 12) {
            CollectionCover(assetID: collection.coverAssetID, loader: loader, size: 256)
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 1) {
                Text(collection.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let subtitle = collection.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

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
