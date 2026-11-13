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
    /// The library these collections are drawn from, so the Albums page can
    /// tell whether the store it already has is still the right one.
    let spaceID: UUID
    /// When the page was last answered, and for which calendar day.
    private var fetchedAt: Date?
    private var fetchedFor: String?
    /// How far into the library's changes it had got. See `isStale`.
    private var fetchedCursor: Int64?
    /// And how many of this device's own changes it had seen. See
    /// `AppSession.libraryRevision`.
    private var fetchedRevision: Int?
    /// Set while a request is out, so a second caller doesn't send another.
    /// The Albums page asks from two places as it appears, and both used to go
    /// to the NAS: two identical requests per visit.
    private var isRefreshing = false

    /// Starts from the page this device saw last, so the trips and occasions
    /// are there the moment the tab is, even with the NAS busy or out of reach.
    /// See `AlbumsSnapshotStore`. `isStale` still says yes, because nothing has
    /// been fetched, so the first visit asks for the current page and swaps it
    /// in when it arrives.
    init(session: AppSession, spaceID: UUID) {
        self.session = session
        self.spaceID = spaceID
        if let saved = AlbumsSnapshotStore.loadCollections(spaceID: spaceID) {
            page = saved
            hasLoaded = true
        }
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
    ///
    /// A change the grid has already seen doesn't wait out the minute. Favorite
    /// a photo, or trash one, and the Favorites count or the trip it belonged to
    /// should say so the moment you arrive here. Nor does one made from this
    /// device that the grid hasn't seen, like a photo restored from Recently
    /// Deleted (`AppSession.libraryRevision`).
    var isStale: Bool {
        guard let fetchedAt, fetchedFor == Self.dayStamp() else { return true }
        if session?.changeCursor(for: spaceID) != fetchedCursor { return true }
        if session?.libraryRevision != fetchedRevision { return true }
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
        guard isStale, !isRefreshing else { return }
        await refresh()
    }

    /// Asks again only if the library has moved since the last answer, however
    /// recent that was. For a page that's watching. See `LiveCounts`.
    func refreshIfChanged() async {
        guard !isRefreshing else { return }
        guard fetchedAt == nil || session?.changeCursor(for: spaceID) != fetchedCursor
                || session?.libraryRevision != fetchedRevision else { return }
        await refresh()
    }

    /// Asks again on the next visit. See `AppSession.hiddenContentChanged`.
    func expire() { fetchedAt = nil }

    func refresh() async {
        guard let client = session?.client else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if page == nil { isLoading = true }
        defer { isLoading = false }
        // Read before asking, not after: a change that lands while the request
        // is out may not be in the answer, and must still count as unseen.
        let cursor = session?.changeCursor(for: spaceID)
        let revision = session?.libraryRevision
        // Failure is quiet, but it must not be destructive. Assigning the
        // result straight through meant one failed pull-to-refresh replaced a
        // good page with nil — and the page above, seeing nothing, replaced
        // itself with the "no albums yet" empty state. A blip should cost you
        // the update, never the screen.
        if let fresh = try? await client.collections(spaceID: spaceID) {
            page = fresh
            hasLoaded = true
            let spaceID = spaceID
            Task.detached(priority: .utility) {
                AlbumsSnapshotStore.saveCollections(fresh, spaceID: spaceID)
            }
            fetchedAt = Date()
            fetchedFor = Self.dayStamp()
            fetchedCursor = cursor
            fetchedRevision = revision
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
        case .person: return "SOMEONE YOU KNOW"
        case .together: return "TOGETHER"
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
        #if os(macOS)
        // Photos' cards, as on the Albums page this opened from.
        GeometryReader { proxy in
            let layout = MacCardLayout(width: proxy.size.width)
            ScrollView {
                LazyVGrid(columns: layout.columns, alignment: .leading, spacing: MacCardLayout.gap) {
                    ForEach(rows) { row in
                        NavigationLink {
                            CollectionDetailView(session: session, space: space, collection: row)
                        } label: {
                            MacCollectionTile(
                                title: row.title, detail: row.subtitle ?? macItems(row.count),
                                side: layout.side
                            ) {
                                CollectionCover(
                                    assetIDs: row.coverAssetIDs, loader: session.loader, size: 512
                                )
                            }
                        }
                        .buttonStyle(.plain)
                        .nameable(row) { naming = $0 }
                    }
                }
                .padding(.horizontal, MacCardLayout.margin)
                .padding(.vertical, 22)
            }
        }
        .navigationTitle(title)
        .sheet(item: $naming) { collection in
            NameOccasionSheet(
                session: session, spaceID: space.id, collection: collection
            ) { changed in
                naming = nil
                if changed { Task { await store.refresh() } }
            }
        }
        #else
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
        #endif
    }
}

/// A day or a trip, as a row rather than a tile.
///
/// Rows rather than a second shelf: two horizontal scrollers stacked is a lot
/// of sideways in one screen, and a day has a date and a place worth reading
/// rather than cropping.
struct CollectionRowCard: View {
    let title: String
    let subtitle: String?
    let count: Int
    let coverAssetIDs: [UUID]
    let loader: ThumbnailLoader?

    init(collection: CollectionSummary, loader: ThumbnailLoader?) {
        self.init(
            title: collection.title, subtitle: collection.subtitle, count: collection.count,
            coverAssetIDs: collection.coverAssetIDs, loader: loader
        )
    }

    /// Anything drawn as a row: a tradition, say, which isn't one collection
    /// but all the years of one.
    init(title: String, subtitle: String?, count: Int, coverAssetIDs: [UUID], loader: ThumbnailLoader?) {
        self.title = title
        self.subtitle = subtitle
        self.count = count
        self.coverAssetIDs = coverAssetIDs
        self.loader = loader
    }

    var body: some View {
        HStack(spacing: 14) {
            // Large enough to be a photograph rather than an icon. At the 54pt
            // it started out, every cover read as a colored square and the row
            // looked like a settings screen.
            CollectionCover(
                assetIDs: coverAssetIDs, loader: loader, size: 256
            )
            .frame(width: 76, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.35), radius: 5, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.body, design: .default, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 10)

            Text("\(count)")
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
    /// Drawn above the photos, for a page with more to say than a subtitle:
    /// a person's face, name and questions.
    var header: AnyView? = nil
    /// What a long press on one photo offers, for a page with something to
    /// offer: "Not Emma" on hers.
    var photoActions: ((TimelineItem) -> AnyView)? = nil
    /// Moved by the page above to load again, for a change this device made
    /// that `FollowsOwnChanges` doesn't hear about.
    var revision = 0

    @State private var items: [TimelineItem] = []
    /// Where the next page starts, for a collection that comes a page at a
    /// time: a person's photos. Nil once everything is here.
    @State private var nextOffset: Int?
    @State private var isLoadingMore = false
    @State private var isLoading = true
    @State private var failure: String?
    /// Everything, rather than the highlights. Off whenever a collection
    /// opens: a week away is 400 photos, and the best 30 are the way in.
    @State private var showAll = false
    /// Whether the server could choose highlights for this collection, which
    /// it can only once enough of it has been analyzed. Until then, or from a
    /// server that predates them, there's no toggle and everything shows.
    @State private var highlightsAvailable = false
    @State private var total = 0
    /// The collection `items` belongs to, so switching between highlights and
    /// everything doesn't blank the grid the way switching collections must.
    @State private var loadedKey: String?
    #if os(iOS)
    /// The library's viewer, over the app. See `OverlayViewer`.
    @Environment(\.overlayViewer) private var overlay
    @State private var tiles = GridTiles()
    #endif

    private let spacing: CGFloat = PhotoGridMetrics.spacing
    private static let highlightCount = 30

    /// Things that happened, as opposed to filters. Favorites are already a
    /// person's own pick, and a media type is a filter rather than an event.
    private var offersHighlights: Bool {
        switch collection.kind {
        case .onThisDay, .trip, .day, .anniversary, .season, .revisit:
            return collection.count > Self.highlightCount
        default:
            return false
        }
    }

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
        // moment the row changes. The highlights switch is part of the key, so
        // flipping it loads the other set.
        .task(id: "\(collection.key)#\(showAll)#\(revision)") { await load() }
        // A photo deleted from the viewer drops out of the trip it was in, and
        // one restored comes back to it. See `FollowsOwnChanges`.
        .modifier(FollowsOwnChanges(session: session) { await load() })
        .onChange(of: collection.key) {
            showAll = false
            highlightsAvailable = false
        }
    }

    private var grid: some View {
        GeometryReader { proxy in
            #if os(iOS)
            StagedGridReader(tiles: tiles) {
                ScrollView {
                    stack(width: proxy.size.width)
                        .stagedGridContent(tiles)
                }
                .stagedGridScroller(tiles)
            }
            #else
            ScrollView {
                stack(width: proxy.size.width)
            }
            #endif
        }
    }

    private func stack(width: CGFloat) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if let header {
                header
            }
            if let subtitle = collection.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            if highlightsAvailable {
                Picker("Show", selection: $showAll) {
                    Text("Highlights").tag(false)
                    Text("All \(total)").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }

            PhotoGridSection(
                entries: items.map { GridEntry.item($0) },
                width: width,
                targetHeight: PhotoGridMetrics.targetRowHeight(for: .day),
                spacing: spacing,
                columns: TimelineZoom.day.columns
            ) { entry, size in
                if case .item(let item) = entry {
                    tile(item, size: size)
                        .modifier(PhotoActions(item: item, actions: photoActions))
                }
            }
            .padding(.horizontal, spacing)

            // The next page, asked for as the end comes into view.
            if nextOffset != nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .onAppear { Task { await loadMore() } }
            }
        }
    }

    /// Opens over the grid the way the library's tiles do. See
    /// `OverlayViewer`.
    @ViewBuilder
    private func tile(_ item: TimelineItem, size: CGSize) -> some View {
        #if os(iOS)
        if let overlay {
            PhotoCell(item: item, loader: session.loader, size: size)
                .stagedTile(item.id, in: tiles, stage: overlay.stage)
                .contentShape(Rectangle())
                .onTapGesture { open(item, on: overlay) }
        } else {
            pushed(item, size: size)
        }
        #else
        pushed(item, size: size)
        #endif
    }

    private func pushed(_ item: TimelineItem, size: CGSize) -> some View {
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

    #if os(iOS)
    private func open(_ item: TimelineItem, on overlay: OverlayViewer) {
        overlay.open(
            OpenedPhoto(item: item, dayItems: [], pageItems: items),
            from: tiles, session: session
        ) { [tiles, space, session] opened in
            AssetDetailView(
                item: opened.item, space: space, session: session,
                pageItems: opened.pageItems,
                onFocus: { overlay.follow($0, in: tiles) }
            )
            .staged(on: overlay.stage)
        }
    }
    #endif

    private func load() async {
        guard let client = session.client else { return }
        isLoading = true
        // Drop the outgoing collection's photos before fetching, so switching
        // sidebar rows shows *this* collection loading rather than the last
        // one's grid sitting under the new title for a beat. On first appearance
        // `items` is already empty, so this is a no-op there. Switching between
        // highlights and everything keeps the grid up until the other arrives.
        if loadedKey != collection.key {
            items = []
            nextOffset = nil
        }
        failure = nil
        defer { isLoading = false }
        let wantHighlights = offersHighlights && !showAll
        // Coming back to the same collection — a photo taken out of it, say —
        // brings back as many pages as were showing, so the grid doesn't
        // shrink to its first page under someone halfway down it.
        let showing = loadedKey == collection.key ? items.count : 0
        do {
            var page = try await client.collectionItems(
                spaceID: space.id, kind: collection.kind, key: collection.key,
                highlights: wantHighlights ? Self.highlightCount : nil
            )
            var fetched = page.items
            while fetched.count < showing, let offset = page.nextOffset {
                page = try await client.collectionItems(
                    spaceID: space.id, kind: collection.kind, key: collection.key, offset: offset
                )
                fetched += page.items
            }
            items = fetched
            total = page.total
            nextOffset = page.nextOffset
            loadedKey = collection.key
            if wantHighlights { highlightsAvailable = page.items.count < page.total }
        } catch {
            failure = ConnectionMonitor.mediaMessage(for: error, state: nil)
        }
    }

    private func loadMore() async {
        guard let client = session.client, let offset = nextOffset, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let key = collection.key
        guard let page = try? await client.collectionItems(
            spaceID: space.id, kind: collection.kind, key: key, offset: offset
        ), key == collection.key, offset == nextOffset else { return }
        // A photo can move between pages while they're read; never twice.
        let seen = Set(items.map(\.id))
        items += page.items.filter { !seen.contains($0.id) }
        nextOffset = page.nextOffset
    }
}

/// A page's long-press actions on one photo, where it has any.
private struct PhotoActions: ViewModifier {
    let item: TimelineItem
    let actions: ((TimelineItem) -> AnyView)?

    func body(content: Content) -> some View {
        if let actions {
            content.contextMenu { actions(item) }
        } else {
            content
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
/// and stay right every year afterward.
struct NameOccasionSheet: View {
    let session: AppSession
    let spaceID: UUID
    let collection: CollectionSummary
    let onFinished: (Bool) -> Void

    @State private var name: String
    @State private var everyYear: Bool
    @State private var isSaving = false
    @State private var failure: String?

    /// `everyYear` starts the switch where the caller knows it belongs: on,
    /// from Over the Years, where the thing being named is a date that comes
    /// round. Otherwise it's suggested from the card.
    init(
        session: AppSession, spaceID: UUID, collection: CollectionSummary,
        everyYear: Bool? = nil,
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
        _everyYear = State(initialValue: everyYear ?? (collection.recursAnnually && !collection.isNamed))
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

/// Everything removed from a library and still recoverable.
///
/// Laid out the way Photos lays out the same room, because it is the one
/// people already know: a count, every item with the days it has left, and
/// Select — which is where Recover All and Delete All live, the two things this
/// page exists for. It used to have no Select at all: tapping a tile quietly
/// toggled it, every unpicked tile was drawn at half opacity, and the only hint
/// was a footnote telling you to select with a button that wasn't there.
///
/// Tapping an item opens it, full size, with Delete and Recover under it, as in
/// Photos; Select starts a selection. A NAS from before deleted items could be
/// opened serves only their thumbnails, so there a tap starts a selection with
/// the item, as it always did. On a television this is a place to look, not to
/// act, like the rest of the app there: the countdowns without the controls.
struct RecentlyDeletedView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO

    @State private var items: [TimelineItem] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var notice: String?
    #if !os(tvOS)
    @State private var isSelecting = false
    /// `assets.id` — what restore and purge take.
    @State private var picked: Set<UUID> = []
    @State private var working: Action?
    @State private var confirming: Action?
    /// The item open full size. See `DeletedItemViewer`.
    @State private var opened: TimelineItem?
    /// What went wrong last, shown under the count. Successes say nothing,
    /// as in Photos: the tiles leaving the grid are the answer.
    @State private var failure: String?
    #endif
    #if os(macOS)
    /// For telling a double-click (open) from a click (select), and where a
    /// Shift-click range starts. See `macClick`.
    @State private var lastClickAt = Date.distantPast
    @State private var lastClickedID: UUID?
    @State private var anchorID: UUID?
    #endif
    #if os(iOS)
    /// The ⓘ beside the count: what the numbers on the tiles mean.
    @State private var showsAbout = false
    /// The library's viewer, over the app. See `OverlayViewer`.
    @Environment(\.overlayViewer) private var overlay
    @State private var tiles = GridTiles()
    #endif

    private let spacing: CGFloat = PhotoGridMetrics.spacing

    var body: some View {
        content
            .navigationTitle("Recently Deleted")
            #if os(iOS)
            // Large, as Photos titles this room, with the count under it.
            .navigationBarTitleDisplayMode(.large)
            .sensoryFeedback(.selection, trigger: picked)
            #endif
            #if os(tvOS)
            .floatingTabBarClearance()
            #elseif os(macOS)
            // Photos on the Mac: no Select mode. A click picks, the toolbar's
            // Recover and Delete act on what's picked — Delete All when nothing
            // is — and the subtitle says how many and when they're from.
            .navigationSubtitle(macSubtitle)
            .toolbar { macToolbar }
            .background { macShortcuts }
            .alert(
                macDeleteTitle,
                isPresented: Binding(
                    get: { confirming != nil },
                    set: { if !$0 { confirming = nil } }
                ),
                presenting: confirming
            ) { action in
                Button("Delete From NAS", role: .destructive) { perform(action) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This action can't be undone.")
            }
            .sheet(item: $opened) { item in
                viewer(opening: item).frame(minWidth: 760, minHeight: 560)
            }
            #else
            // Photos on the iPhone: Select turns on picking; the floating tab
            // bar steps aside for a pill that says what's picked, and Delete
            // and Recover live in the ••• menu, which asks before anything
            // goes for good. See `FloatingTabBar`.
            .floatingTabBarClearance(when: !isSelecting)
            .floatingTabBarHidden(while: isSelecting)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelecting { selectionPill }
            }
            .toolbar { toolbar }
            .fullScreenCover(item: $opened) { item in viewer(opening: item) }
            #endif
            .task {
                // Whether a tap can open an item. Asked once per sign-in.
                await session.loadCapabilities()
                await load()
            }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading, items.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, items.isEmpty {
            // Not "Nothing Removed": an unreachable NAS used to land here as an
            // empty bin, which is a false answer to the question on screen.
            ContentUnavailableView {
                Label("Couldn't Load Recently Deleted", systemImage: "exclamationmark.icloud")
            } description: {
                Text(loadError)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else if items.isEmpty {
            ContentUnavailableView {
                Label("No Recently Deleted Items", systemImage: "trash")
            } description: {
                Text(
                    "Items you delete from \(space.name) stay here for "
                    + "\(Retention.days) days before they're deleted for good."
                )
            }
        } else {
            #if os(macOS)
            macGrid
            #else
            grid
            #endif
        }
    }

    private var grid: some View {
        GeometryReader { proxy in
            #if os(iOS)
            StagedGridReader(tiles: tiles) {
                ScrollView {
                    stack(width: proxy.size.width)
                        .stagedGridContent(tiles)
                }
                .stagedGridScroller(tiles)
                .refreshable { await load() }
            }
            #else
            ScrollView {
                stack(width: proxy.size.width)
            }
            #endif
        }
    }

    private func stack(width: CGFloat) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            header
            PhotoGridSection(
                entries: items.map { GridEntry.item($0) },
                width: width,
                targetHeight: PhotoGridMetrics.targetRowHeight(for: .day),
                spacing: spacing,
                columns: TimelineZoom.day.columns
            ) { entry, size in
                if case .item(let item) = entry {
                    tile(item, size: size)
                }
            }
            .padding(.horizontal, spacing)
        }
    }

    /// The count under the title, as Photos has it — "🗑 4 Items ⓘ", the ⓘ
    /// saying what the numbers on the tiles mean — and anything that failed.
    /// Successes say nothing: the tiles leaving the grid are the answer.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(items.count == 1 ? "1 Item" : "\(items.count) Items", systemImage: "trash")
                    .font(.headline)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                #if os(iOS)
                Button {
                    showsAbout = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.body)
                }
                .accessibilityLabel("About Recently Deleted")
                .popover(isPresented: $showsAbout) {
                    Text(
                        "Items show the days left before they're deleted. After that, "
                        + "they're removed from your NAS for good."
                    )
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280)
                    .padding()
                    .presentationCompactAdaptation(.popover)
                }
                #endif
            }
            #if os(tvOS)
            Text("Each item shows the days left before it's deleted for good.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            #else
            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func daysBadge(_ item: TimelineItem) -> some View {
        if let days = item.daysUntilPurge {
            DaysRemainingBadge(days: days).padding(5)
        }
    }

    #if os(tvOS)
    private func tile(_ item: TimelineItem, size: CGSize) -> some View {
        PhotoCell(item: item, loader: session.loader, size: size)
            .overlay(alignment: .bottomLeading) { daysBadge(item) }
    }
    #else
    /// Photos' tile here: the days left written across the foot of the
    /// picture, and on a picked tile the check in that corner instead.
    private func tile(_ item: TimelineItem, size: CGSize) -> some View {
        let isPicked = picked.contains(item.assetID)
        return PhotoCell(item: item, loader: session.loader, size: size)
            .overlay {
                if isPicked { Rectangle().fill(.white.opacity(0.15)) }
            }
            .overlay(alignment: .bottom) {
                // A soft fade under the count, as Photos has, so white text
                // reads on a light picture too.
                if !isPicked, item.daysUntilPurge != nil {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.45)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: min(size.height * 0.35, 48))
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if !isPicked, let days = item.daysUntilPurge {
                    Text(days <= 0 ? "Today" : days == 1 ? "1 day" : "\(days) days")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 3)
                        .padding(.bottom, 6)
                        .accessibilityLabel(
                            days == 1 ? "Deleted forever in 1 day" : "Deleted forever in \(days) days"
                        )
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isPicked { SelectionMark(isPicked: true).padding(6) }
            }
            #if os(iOS)
            .stagedTile(item.id, in: tiles, stage: overlay?.stage)
            #endif
            .contentShape(Rectangle())
            .onTapGesture { tap(item) }
            .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    // MARK: - Selecting

    private enum Action: Equatable {
        case recover(all: Bool)
        case delete(all: Bool)
    }

    private var isWorking: Bool { working != nil }
    private var allPicked: Bool { !items.isEmpty && picked.count == items.count }
    /// A viewer can see what was removed but, like everywhere else in a
    /// library they only view, can't change it.
    private var canEdit: Bool { space.role != .viewer }

    private func tap(_ item: TimelineItem) {
        guard !isWorking else { return }
        if !isSelecting, session.supports(ServerCapability.deletedPreview) {
            #if os(iOS)
            // Over the grid, as the library opens a photo. See `OverlayViewer`.
            if let overlay {
                overlay.open(
                    OpenedPhoto(item: item, dayItems: [], pageItems: items),
                    from: tiles, session: session
                ) { opened in
                    viewer(opening: opened.item).staged(on: overlay.stage)
                }
                return
            }
            #endif
            opened = item
            return
        }
        guard canEdit else { return }
        notice = nil
        isSelecting = true
        if picked.contains(item.assetID) {
            picked.remove(item.assetID)
        } else {
            picked.insert(item.assetID)
        }
    }

    private func viewer(opening item: TimelineItem) -> DeletedItemViewer {
        DeletedItemViewer(
            session: session, items: items, opening: item, canEdit: canEdit,
            onRecover: { try await act(.recover(all: false), on: $0) },
            onDelete: { try await act(.delete(all: false), on: $0) },
            onDone: { opened = nil }
        )
    }

    /// One item recovered or deleted from the viewer. Said on this page too,
    /// for when the viewer closes.
    private func act(_ action: Action, on item: TimelineItem) async throws {
        guard let client = session.client else { return }
        switch action {
        case .recover:
            _ = try await client.restore(spaceID: space.id, assetIDs: [item.assetID])
            notice = "1 item recovered."
        case .delete:
            _ = try await client.purge(spaceID: space.id, assetIDs: [item.assetID])
            notice = "1 item deleted permanently."
        }
        await load()
    }

    private func endSelection() {
        isSelecting = false
        picked.removeAll()
    }

    #if os(iOS)
    /// Select, and while selecting the ••• menu and ×, as in Photos. The menu
    /// holds Delete and Recover — Delete All and Recover All with nothing
    /// picked — and the question before a permanent delete pops out of it.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .primaryAction) {
                actionsMenu
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    endSelection()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Done Selecting")
                .disabled(isWorking)
            }
        } else if canEdit {
            ToolbarItem(placement: .primaryAction) {
                Button("Select") {
                    failure = nil
                    isSelecting = true
                }
                .disabled(items.isEmpty)
            }
        }
    }

    private var actionsMenu: some View {
        Menu {
            if picked.isEmpty {
                Button(role: .destructive) {
                    confirming = .delete(all: true)
                } label: {
                    Label("Delete All", systemImage: "trash")
                }
                Button {
                    confirming = .recover(all: true)
                } label: {
                    Label("Recover All", systemImage: "arrow.up.bin")
                }
            } else {
                Button(role: .destructive) {
                    confirming = .delete(all: false)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                // Putting back what you picked doesn't ask: deleting it
                // again undoes it.
                Button {
                    perform(.recover(all: false))
                } label: {
                    Label("Recover", systemImage: "arrow.up.bin")
                }
            }
        } label: {
            if isWorking {
                ProgressView()
            } else {
                Image(systemName: "ellipsis")
            }
        }
        .accessibilityLabel("Actions")
        .disabled(isWorking || items.isEmpty)
        // Attached to the menu so it points from there, the way Photos'
        // "These photos will be permanently deleted" does.
        .confirmationDialog(
            "",
            isPresented: Binding(
                get: { confirming != nil },
                set: { if !$0 { confirming = nil } }
            ),
            titleVisibility: .hidden,
            presenting: confirming
        ) { action in
            switch action {
            case .delete:
                Button("Delete From NAS", role: .destructive) { perform(action) }
            case .recover:
                Button("Recover \(countText(targetItems, total: targetCount))") { perform(action) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(confirmationMessage(action))
        }
    }

    /// "Select Items", then "2 Photos Selected" — where the tab bar was.
    private var selectionPill: some View {
        Group {
            if isWorking {
                ProgressView()
            } else {
                Text(
                    picked.isEmpty
                        ? "Select Items"
                        : countText(pickedItems, total: picked.count) + " Selected"
                )
                .monospacedDigit()
                .contentTransition(.numericText())
            }
        }
        .font(.headline)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .glassBackground(in: Capsule(), interactive: false, fallback: .regularMaterial)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    /// What a confirmation is about: what is picked, or everything.
    private var targetItems: [TimelineItem] { picked.isEmpty ? items : pickedItems }
    private var targetCount: Int { picked.isEmpty ? items.count : picked.count }

    private func confirmationMessage(_ action: Action) -> String {
        let n = targetCount
        let noun = kindNoun(targetItems, plural: n != 1).lowercased()
        switch action {
        case .delete:
            return n == 1
                ? "This \(noun) will be permanently deleted. This action can't be undone."
                : "These \(noun) will be permanently deleted. This action can't be undone."
        case .recover:
            return n == 1
                ? "This \(noun) goes back to \(space.name)."
                : "These \(noun) go back to \(space.name)."
        }
    }
    #endif

    private var pickedItems: [TimelineItem] {
        items.filter { picked.contains($0.assetID) }
    }

    /// "29 Photos", "3 Videos", "5 Items" — Photos names the kind when
    /// they're all one kind.
    private func countText(_ subset: [TimelineItem], total: Int) -> String {
        "\(total.formatted()) \(kindNoun(subset, plural: total != 1))"
    }

    private func kindNoun(_ subset: [TimelineItem], plural: Bool) -> String {
        let noun: String
        if !subset.isEmpty, subset.allSatisfy({ $0.mediaType == .video }) {
            noun = "Video"
        } else if !subset.isEmpty, subset.allSatisfy({ $0.mediaType != .video }) {
            noun = "Photo"
        } else {
            noun = "Item"
        }
        return plural ? noun + "s" : noun
    }

    private func perform(_ action: Action) {
        guard let client = session.client, !isWorking else { return }
        let all = picked.isEmpty
        let first = all ? items.map(\.assetID) : Array(picked)
        guard !first.isEmpty else { return }
        working = action
        failure = nil
        Task {
            var batch = first
            var total = 0
            do {
                while !batch.isEmpty {
                    let result: MediaEditResponse
                    switch action {
                    case .recover:
                        result = try await client.restore(spaceID: space.id, assetIDs: batch)
                    case .delete:
                        result = try await client.purge(spaceID: space.id, assetIDs: batch)
                    }
                    total += result.updated
                    // "All" means all, not the first page: this list holds at
                    // most 500, and a fuller bin has more behind them.
                    guard all, result.updated > 0 else { break }
                    await load()
                    batch = items.map(\.assetID)
                }
                switch action {
                case .recover:
                    notice = total == 1 ? "1 item recovered." : "\(total) items recovered."
                case .delete:
                    notice = total == 1
                        ? "1 item deleted permanently." : "\(total) items deleted permanently."
                }
            } catch {
                notice = "That didn't finish: \(error.localizedDescription)"
                failure = notice
            }
            working = nil
            endSelection()
            await load()
        }
    }
    #endif

    #if os(macOS)
    // MARK: - Mac

    /// Square tiles with the days left written under each, and the count and
    /// what it means at the foot of the window — Photos' own layout for this
    /// room on the Mac.
    private var macGrid: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: 160, maximum: 240),
                                spacing: 2, alignment: .top
                            )
                        ],
                        spacing: 2
                    ) {
                        ForEach(items) { item in macTile(item) }
                    }
                    .padding(.horizontal, 2)
                    Spacer(minLength: 24)
                    macFooter
                }
                .frame(minHeight: proxy.size.height)
                // A click between tiles clears the selection, as in Photos.
                // The tiles' own clicks win over this one.
                .contentShape(Rectangle())
                .onTapGesture { picked.removeAll() }
            }
        }
    }

    /// Picked the way the library grid shows it: the check at the corner and
    /// the accent border.
    private func macTile(_ item: TimelineItem) -> some View {
        let isPicked = picked.contains(item.assetID)
        return VStack(spacing: 6) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    GeometryReader { proxy in
                        PhotoCell(item: item, loader: session.loader, size: proxy.size)
                    }
                }
                .clipped()
                .overlay(alignment: .topLeading) {
                    if isPicked { SelectionMark(isPicked: true).padding(5) }
                }
                .overlay {
                    if isPicked {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
            Text(macDaysLeft(item))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.bottom, 12)
        .contentShape(Rectangle())
        .onTapGesture { macClick(item) }
        .contextMenu { macMenu(for: item) }
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    private func macDaysLeft(_ item: TimelineItem) -> String {
        guard let days = item.daysUntilPurge else { return "" }
        switch days {
        case ...0: return "Deleting today"
        case 1: return "1 day left"
        default: return "\(days) days left"
        }
    }

    /// The count, what the captions mean, and anything that went wrong.
    private var macFooter: some View {
        VStack(spacing: 4) {
            Text(countText(items, total: items.count))
                .font(.headline)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(
                "Each item shows the days left before it's deleted. After that, "
                + "it's removed from your NAS for good."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 480)
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }

    /// A click picks, ⌘ adds or removes, ⇧ picks the run from the last click,
    /// and a second click soon after opens — the library grid's rules. A
    /// viewer of the library can open items but not pick them.
    private func macClick(_ item: TimelineItem) {
        guard !isWorking else { return }
        let now = Date()
        let isSecondClick = lastClickedID == item.id
            && now.timeIntervalSince(lastClickAt) <= NSEvent.doubleClickInterval
        lastClickAt = now
        lastClickedID = item.id

        if isSecondClick {
            lastClickedID = nil
            if session.supports(ServerCapability.deletedPreview) { opened = item }
            return
        }
        guard canEdit else { return }
        failure = nil
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if picked.contains(item.assetID) {
                picked.remove(item.assetID)
            } else {
                picked.insert(item.assetID)
            }
            anchorID = item.assetID
        } else if flags.contains(.shift),
                  let anchorID,
                  let from = items.firstIndex(where: { $0.assetID == anchorID }),
                  let to = items.firstIndex(where: { $0.assetID == item.assetID }) {
            picked.formUnion(items[min(from, to)...max(from, to)].map(\.assetID))
        } else {
            picked = [item.assetID]
            anchorID = item.assetID
        }
    }

    /// Right-click on a picked tile acts on everything picked; on any other
    /// tile, on that one alone — the Finder's rule. The selection is set when
    /// an item is chosen, never while the menu is drawn.
    @ViewBuilder
    private func macMenu(for item: TimelineItem) -> some View {
        if canEdit {
            let targets: Set<UUID> = picked.contains(item.assetID) ? picked : [item.assetID]
            let chosen = items.filter { targets.contains($0.assetID) }
            Button {
                picked = targets
                perform(.recover(all: false))
            } label: {
                Label("Recover", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                picked = targets
                confirming = .delete(all: false)
            } label: {
                Label("Delete \(countText(chosen, total: chosen.count))…", systemImage: "trash")
            }
        }
        if session.supports(ServerCapability.deletedPreview) {
            Divider()
            Button("Open") { opened = item }
        }
    }

    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        if canEdit {
            ToolbarItem(placement: .primaryAction) {
                Button("Recover") { perform(.recover(all: false)) }
                    .disabled(picked.isEmpty || isWorking)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    confirming = .delete(all: picked.isEmpty)
                } label: {
                    if working != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(
                            picked.isEmpty
                                ? "Delete All"
                                : "Delete \(countText(pickedItems, total: picked.count))"
                        )
                    }
                }
                .disabled(items.isEmpty || isWorking)
            }
        }
    }

    /// Keys with no button of their own: ⌘A, Delete (with or without ⌘) and
    /// Escape to let go of the selection.
    private var macShortcuts: some View {
        ZStack {
            Button("Select All") { picked = Set(items.map(\.assetID)) }
                .keyboardShortcut("a", modifiers: .command)
            Button("Delete") { if !picked.isEmpty { confirming = .delete(all: false) } }
                .keyboardShortcut(.delete, modifiers: [])
            Button("Delete") { if !picked.isEmpty { confirming = .delete(all: false) } }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Deselect") { picked.removeAll() }
                .keyboardShortcut(.cancelAction)
        }
        .disabled(!canEdit || isWorking || items.isEmpty)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// "29 Photos · September 2026", or "5 Photos Selected · …".
    private var macSubtitle: String {
        guard !items.isEmpty else { return "" }
        let count = picked.isEmpty
            ? countText(items, total: items.count)
            : countText(pickedItems, total: picked.count) + " Selected"
        let range = macDateRange
        return range.isEmpty ? count : "\(count) · \(range)"
    }

    /// When the items were taken: "September 2026", "June – September 2026",
    /// "June 2025 – September 2026".
    private var macDateRange: String {
        let dates = items.map(\.capturedAt)
        guard let first = dates.min(), let last = dates.max() else { return "" }
        let calendar = Calendar.current
        let monthYear = Date.FormatStyle().month(.wide).year()
        let sameYear = calendar.isDate(first, equalTo: last, toGranularity: .year)
        if sameYear, calendar.isDate(first, equalTo: last, toGranularity: .month) {
            return first.formatted(monthYear)
        }
        let start = sameYear
            ? first.formatted(Date.FormatStyle().month(.wide))
            : first.formatted(monthYear)
        return "\(start) – \(last.formatted(monthYear))"
    }

    /// "Are you sure you want to delete 29 photos permanently?"
    private var macDeleteTitle: String {
        let subset = picked.isEmpty ? items : pickedItems
        let n = picked.isEmpty ? items.count : picked.count
        let what = n == 1
            ? "this \(kindNoun(subset, plural: false).lowercased())"
            : "\(n.formatted()) \(kindNoun(subset, plural: true).lowercased())"
        return "Are you sure you want to delete \(what) permanently?"
    }
    #endif

    private func load() async {
        guard let client = session.client else {
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await client.deletedItems(spaceID: space.id).items
            loadError = nil
            #if !os(tvOS)
            // Anything recovered or purged from another device is no longer
            // here to pick.
            let present = Set(items.map(\.assetID))
            picked = picked.filter { present.contains($0) }
            if items.isEmpty { isSelecting = false }
            #endif
        } catch {
            // Keeps what is on screen: a blip shouldn't empty a page of things
            // someone is in the middle of deciding about.
            loadError = error.localizedDescription
        }
    }
}

/// Everything of one shape. Behind one door, not twelve.
struct MediaTypesView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO
    /// What the Albums page had when this was opened, until the store has
    /// newer. Read from the store after that, so a video deleted from Videos
    /// isn't still counted here on the way back.
    let types: [CollectionSummary]

    private var store: CollectionsStore { session.collectionsStore(for: space.id) }

    var body: some View {
        #if os(macOS)
        // Photos' cards, as on the Albums page this opened from.
        GeometryReader { proxy in
            let layout = MacCardLayout(width: proxy.size.width)
            ScrollView {
                LazyVGrid(columns: layout.columns, alignment: .leading, spacing: MacCardLayout.gap) {
                    ForEach(store.page?.mediaTypes ?? types) { type in
                        NavigationLink {
                            CollectionDetailView(session: session, space: space, collection: type)
                        } label: {
                            MacCollectionTile(
                                title: type.title, detail: macItems(type.count), side: layout.side
                            ) {
                                CollectionCover(
                                    assetIDs: type.coverAssetIDs, loader: session.loader, size: 512
                                )
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, MacCardLayout.margin)
                .padding(.vertical, 22)
            }
        }
        .navigationTitle("Media Types")
        .onAppear { Task { await store.refreshIfStale() } }
        .modifier(LiveCounts(session: session) { await store.refreshIfChanged() })
        #else
        List(store.page?.mediaTypes ?? types) { type in
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
        .onAppear { Task { await store.refreshIfStale() } }
        .modifier(LiveCounts(session: session) { await store.refreshIfChanged() })
        #endif
    }
}
