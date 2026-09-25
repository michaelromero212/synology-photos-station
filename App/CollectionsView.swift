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

/// One collection's cover.
///
/// Falls back to a flat fill rather than a spinner: a card that is briefly
/// plain reads as a photograph still arriving, where a spinner in a grid of
/// photographs reads as something being wrong.
///
/// Still, and there the moment it is. The hero used to crossfade through five
/// covers and fade each one in as it landed; on the one card at the top of the
/// page that read as the page still settling, and he asked for the picture to
/// simply show up. The ids after the first are stand-ins, tried in order when
/// the first can't be drawn.
///
/// Letterboxed frames are trimmed — see `Letterbox`. A video exported from
/// iMovie, saved from a feed or transferred off a camcorder often carries its
/// black bars inside the picture, and filling a card with it fills the card
/// with bars.
struct CollectionCover: View {
    let assetIDs: [UUID]
    let loader: ThumbnailLoader?
    let size: Int

    @State private var image: PlatformImage?

    init(assetIDs: [UUID], loader: ThumbnailLoader?, size: Int = 512) {
        self.assetIDs = assetIDs
        self.loader = loader
        self.size = size
        // Already decoded in memory: drawn on the first frame rather than one
        // after it, so coming back to the page doesn't blink the hero gray.
        _image = State(initialValue: assetIDs.first.flatMap { first in
            loader?.cachedThumbnail(assetID: first, size: size)
                .map { Letterbox.trimmed($0, key: "\(first)-\(size)") }
        })
    }

    var body: some View {
        // The photograph goes in an `overlay` on a plain fill rather than beside
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
                if let image {
                    Image(platformImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: assetIDs) { await load() }
    }

    private func load() async {
        guard let loader else { return }
        for assetID in assetIDs.prefix(3) {
            guard !Task.isCancelled else { return }
            if let cover = await loader.thumbnail(assetID: assetID, size: size) {
                let trimmed = Letterbox.trimmed(cover, key: "\(assetID)-\(size)")
                // No animation, even one inherited from whatever redrew the
                // page: the picture is either there or it isn't.
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { image = trimmed }
                return
            }
        }
    }
}

/// Takes black bands off the edges of a picture.
///
/// Only a matched pair on opposite edges, uniform and very dark: that is what a
/// letterbox or pillarbox is, and it is almost never what a photograph is. A
/// night sky darkens one edge, not two, and it has stars in it.
enum Letterbox {
    /// Keyed like the loader's own memory cache, so a card rebuilt by its parent
    /// doesn't measure the same picture again. `NSCache` is its own lock.
    nonisolated(unsafe) private static let cache = NSCache<NSString, PlatformImage>()

    static func trimmed(_ image: PlatformImage, key: String) -> PlatformImage {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let result = trim(image) ?? image
        cache.setObject(result, forKey: key as NSString)
        return result
    }

    private static func trim(_ image: PlatformImage) -> PlatformImage? {
        #if canImport(UIKit)
        guard image.imageOrientation == .up, let cgImage = image.cgImage else { return nil }
        #else
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        #endif
        guard let inside = content(of: cgImage),
              let cropped = cgImage.cropping(to: inside) else { return nil }
        #if canImport(UIKit)
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
        #else
        return NSImage(cgImage: cropped, size: .zero)
        #endif
    }

    /// The picture inside any bars, in the image's own pixels, or nil if there
    /// are none worth taking off.
    static func content(of image: CGImage) -> CGRect? {
        // Measured on a copy under two hundred pixels wide. A band worth
        // trimming is dozens of pixels deep on any cover, so this finds it to
        // within a pixel or two of the original while reading a small fraction
        // of the pixels.
        let width = min(image.width, 192)
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        guard width >= 16, height >= 16,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        let stride = context.bytesPerRow

        func luma(_ x: Int, _ y: Int) -> Int {
            let i = y * stride + x * 4
            return (Int(pixels[i]) * 54 + Int(pixels[i + 1]) * 183 + Int(pixels[i + 2]) * 19) >> 8
        }
        // Dark on average and nowhere bright. JPEG leaves a little noise in a
        // black bar, so not zero; one lit pixel is a star, so not the mean alone.
        func dark(_ values: some Sequence<Int>) -> Bool {
            var total = 0, count = 0
            for value in values {
                if value > 48 { return false }
                total += value
                count += 1
            }
            return count > 0 && total <= 24 * count
        }
        func band(_ count: Int, _ isDark: (Int) -> Bool) -> Int {
            var depth = 0
            while depth < count / 2, isDark(depth) { depth += 1 }
            return depth
        }

        let top = band(height) { y in dark((0..<width).lazy.map { luma($0, y) }) }
        let bottom = band(height) { y in dark((0..<width).lazy.map { luma($0, height - 1 - y) }) }
        let left = band(width) { x in dark((0..<height).lazy.map { luma(x, $0) }) }
        let right = band(width) { x in dark((0..<height).lazy.map { luma(width - 1 - x, $0) }) }

        // A pair, of about the same depth, deep enough to be a band, and with a
        // real picture left between them. A fifth, not a third: a portrait
        // phone video pillarboxed into a landscape frame is under a third of
        // its width, and it is the commonest case there is.
        func pair(_ a: Int, _ b: Int, of length: Int) -> Bool {
            a >= max(2, length / 25) && b >= max(2, length / 25)
                && abs(a - b) <= max(2, length / 25)
                && length - a - b >= length / 5
        }

        var rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let scaleY = Double(image.height) / Double(height)
        let scaleX = Double(image.width) / Double(width)
        // One pixel further in than measured, so no dark seam survives the
        // rounding at the edge of the picture.
        if pair(top, bottom, of: height) {
            let cutTop = Int((Double(top) * scaleY).rounded(.up)) + 1
            let cutBottom = Int((Double(bottom) * scaleY).rounded(.up)) + 1
            rect.origin.y = CGFloat(cutTop)
            rect.size.height -= CGFloat(cutTop + cutBottom)
        }
        if pair(left, right, of: width) {
            let cutLeft = Int((Double(left) * scaleX).rounded(.up)) + 1
            let cutRight = Int((Double(right) * scaleX).rounded(.up)) + 1
            rect.origin.x = CGFloat(cutLeft)
            rect.size.width -= CGFloat(cutLeft + cutRight)
        }
        guard rect.size != CGSize(width: image.width, height: image.height),
              rect.width > 0, rect.height > 0 else { return nil }
        return rect
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
                    CollectionCover(assetIDs: collection.coverAssetIDs, loader: loader)

                    // Three stops rather than two. A straight black-to-clear ramp
                    // grays the middle of the photograph to hold text that only
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
    /// daily never leaves you guessing why this card is the one. The server's
    /// own line wins where it has one — "CHRISTMAS IS COMING UP" says more
    /// than the kind can.
    private var kicker: String {
        if let kicker = collection.kicker { return kicker }
        switch collection.kind {
        case .onThisDay: return "ON THIS DAY"
        case .anniversary: return "THIS WEEK, BACK THEN"
        case .trip: return "A TRIP"
        // Holidays and the days somebody named, now that busy days alone no
        // longer earn a card.
        case .day: return "A DAY TO REMEMBER"
        case .revisit: return "YOU HAVEN'T BEEN IN A WHILE"
        case .mediaType: return "EVERYTHING OF ONE KIND"
        case .season: return "LOOKING BACK"
        case .recentlyDeleted: return "REMOVED"
        case .recentlyAdded: return "JUST ARRIVED"
        case .favorites: return "YOUR FAVORITES"
        }
    }
}

/// Everything one section of the Albums page chose its few rows from — every
/// trip, or every holiday and occasion.
///
/// Read live from the page's store rather than handed a copy, so naming a day
/// from here renames it here as well as on the page underneath.
struct CollectionListView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO
    let title: String
    let store: CollectionsStore
    let list: KeyPath<CollectionsResponse, [CollectionSummary]?>

    @State private var naming: CollectionSummary?

    private var rows: [CollectionSummary] { store.page?[keyPath: list] ?? [] }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    NavigationLink {
                        CollectionDetailView(session: session, space: space, collection: row)
                    } label: {
                        CollectionRowCard(collection: row, loader: session.loader)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .nameable(row) { naming = $0 }
                }
            }
            .padding(.vertical, 8)
        }
        .navigationTitle(title)
        // The floating tab bar is drawn over this — see `FloatingTabBar`.
        .floatingTabBarClearance()
        #if !os(tvOS)
        .sheet(item: $naming) { collection in
            NameOccasionSheet(
                session: session, spaceID: space.id, collection: collection
            ) { changed in
                naming = nil
                if changed { Task { await store.refresh() } }
            }
        }
        #endif
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
            // it started out, every cover read as a colored square and the row
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
        // The floating tab bar is drawn over this — see `FloatingTabBar`.
        .floatingTabBarClearance()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Keyed to the collection, not a bare `.task`. On iOS every media type
        // is a fresh push, so an unkeyed task ran once per screen and was fine.
        // The Mac sidebar reuses this one view across every media-type row,
        // handing it a new `collection` in place — and a bare `.task` never
        // re-fires on an input change, only on appear. So the grid kept the
        // previous type's photos until you left for Library and came back, which
        // rebuilt the view. Keying the load to the collection restarts it the
        // moment the row changes.
        .task(id: collection.key) { await load() }
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
        // Drop the outgoing collection's photos before fetching, so switching
        // sidebar rows shows *this* collection loading rather than the last
        // one's grid sitting under the new title for a beat. On first appearance
        // `items` is already empty, so this is a no-op there.
        items = []
        failure = nil
        defer { isLoading = false }
        do {
            items = try await client.collectionItems(
                spaceID: space.id, kind: collection.kind, key: collection.key
            ).items
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
/// How long this photograph has left, on the photograph.
///
/// On every tile rather than only the urgent ones. A badge that appears at some
/// threshold is a badge whose absence means two different things — plenty of
/// time, or nobody computed it — and the day count is the entire reason this
/// screen is a waiting room rather than a bin.
///
/// The last week turns amber. Not red: nothing has gone wrong, and the photo is
/// still one tap from coming back. Red is for damage, and this is a deadline.
private struct DaysRemainingBadge: View {
    let days: Int

    private var isUrgent: Bool { days <= 7 }

    var body: some View {
        Text(days == 1 ? "1 day" : "\(days) days")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(isUrgent ? AnyShapeStyle(.orange) : AnyShapeStyle(.white))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .accessibilityLabel(
                days == 1
                    ? "Deleted forever in 1 day"
                    : "Deleted forever in \(days) days"
            )
    }
}

struct RecentlyDeletedView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO

    @State private var items: [TimelineItem] = []
    @State private var isLoading = true
    @State private var selection: Set<UUID> = []
    @State private var isRestoring = false
    @State private var isPurging = false
    @State private var confirmPurge = false
    @State private var notice: String?

    private var isWorking: Bool { isRestoring || isPurging }

    private let spacing: CGFloat = PhotoGridMetrics.spacing

    var body: some View {
        Group {
            if isLoading, items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Removed", systemImage: "trash")
                } description: {
                    Text(
                        "Photos you remove from \(space.name) wait here for "
                        + "\(Retention.days) days before they go for good."
                    )
                }
            } else {
                grid
            }
        }
        .navigationTitle("Recently Deleted")
        // The floating tab bar is drawn over this — see `FloatingTabBar`.
        .floatingTabBarClearance()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !selection.isEmpty {
                // Recover on the right, the primary way out of this room; Delete
                // to its left, destructive, the same arrangement Photos uses.
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete \(selection.count)", role: .destructive) {
                        confirmPurge = true
                    }
                    .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isRestoring ? "Recovering…" : "Recover \(selection.count)") {
                        restore()
                    }
                    .disabled(isWorking)
                    .fontWeight(.semibold)
                }
            }
        }
        // Permanent delete skips the 29-day net, so it asks first. Recover
        // doesn't — putting a photo back is safe and undoable by deleting again.
        .confirmationDialog(
            selection.count == 1
                ? "Delete this photo permanently?"
                : "Delete \(selection.count) photos permanently?",
            isPresented: $confirmPurge,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) { purge() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This can't be undone. "
                + (selection.count == 1 ? "It's removed" : "They're removed")
                + " from your NAS right away, without waiting out the \(Retention.days)-day window."
            )
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
                    // A countdown, now that there is one to state.
                    //
                    // This deliberately said nothing about time while the bin
                    // was DSM's and emptied on DSM's schedule — a number the
                    // app could not enforce would have been a promise it had no
                    // way to keep. FrameStation owns the window now and the
                    // sweeper holds it, so the days on these tiles are real.
                    Text("Photos are kept for \(Retention.days) days. Select to recover, or delete for good.")
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
                                // Both badges sit outside the dimming, so the
                                // number stays readable on a tile that is
                                // deliberately faded for not being selected.
                                .overlay(alignment: .bottomLeading) {
                                    if let days = item.daysUntilPurge {
                                        DaysRemainingBadge(days: days)
                                            .padding(5)
                                    }
                                }
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

    private func purge() {
        guard let client = session.client, !selection.isEmpty else { return }
        isPurging = true
        let chosen = Array(selection)
        Task {
            defer { isPurging = false }
            let result = try? await client.purge(spaceID: space.id, assetIDs: chosen)
            let n = result?.updated ?? 0
            notice = n == 1 ? "1 photo deleted permanently." : "\(n) photos deleted permanently."
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
        // The floating tab bar is drawn over this — see `FloatingTabBar`.
        .floatingTabBarClearance()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
