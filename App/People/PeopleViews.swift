import FrameStationAPI
import FrameStationKit
import SwiftUI

// MARK: - People
//
// The people the NAS found in this person's own library, on the Albums page
// and on pages of their own. Every device shows the same people and the same
// names, because both live on the NAS. Naming and correcting happen on the
// iPhone, the iPad and the Mac; a television shows them. See NAS-ANALYSIS.md
// §6 and §7.

/// How the People row is drawn on each kind of screen.
enum PeopleMetrics {
    /// A face on the People row.
    static var rowFace: CGFloat {
        #if os(tvOS)
        return 150
        #elseif os(macOS)
        return 112
        #else
        return 78
        #endif
    }
}

// MARK: - A face

/// A face in a circle: the one that stands for someone, or one the NAS is
/// asking about.
///
/// Cropped on the NAS from the person's own photo, and fetched through the
/// thumbnail loader so faces wait in the same line as thumbnails do and are
/// there at once on the next visit.
struct FaceCircle: View {
    enum Source: Hashable {
        /// Whoever stands for this person. Kept on this device: the key
        /// changes when the face does.
        case person(PersonSummary)
        /// One face in one photo, asked about once and not kept.
        case suggestion(PersonSuggestion)
    }

    let session: AppSession
    let spaceID: UUID
    let source: Source
    let diameter: CGFloat

    @State private var image: PlatformImage?
    /// Whose face `image` is, by `key(_:)`.
    @State private var imageKey: String?

    /// The NAS's two sizes of a face (see `FaceCrop` there). The small one
    /// fills a circle up to 256 pixels across. Past that it was enlarged:
    /// the 224-point "Is this Emma?" circle drew it 2.6 times over on a
    /// phone, and his rule is that faces show up clear (2026-11-16).
    static let smallPixels = 256
    static let largePixels = 768

    /// Pixels to a point, as many as any screen of the kind has: an iPhone
    /// has 3 and an iPad 2, so iOS counts 3.
    private static var screenScale: CGFloat {
        #if os(iOS)
        return 3
        #else
        return 2
        #endif
    }

    /// The face size a circle this big needs: the large one only where the
    /// small one would be enlarged, and only from a NAS that makes it. One
    /// that doesn't sends its small one to any request, and that would be
    /// kept here as the large one for good.
    static func pixels(for diameter: CGFloat, session: AppSession) -> Int {
        guard diameter * screenScale > CGFloat(smallPixels),
              session.supports(ServerCapability.largeFaces)
        else { return smallPixels }
        return largePixels
    }

    init(session: AppSession, spaceID: UUID, source: Source, diameter: CGFloat) {
        self.session = session
        self.spaceID = spaceID
        self.source = source
        self.diameter = diameter
        // Already decoded: drawn on the first frame, not one after. A big
        // circle whose large face isn't here yet starts from the small one
        // when that is.
        let pixels = Self.pixels(for: diameter, session: session)
        let held = Self.held(source, pixels: pixels, session: session)
        _image = State(initialValue: held)
        _imageKey = State(initialValue: held == nil ? nil : Self.key(source))
    }

    /// A face already decoded, large or small, without asking for it.
    private static func held(_ source: Source, pixels: Int, session: AppSession) -> PlatformImage? {
        let loader = session.loader
        return loader?.cachedFace(key: key(source, pixels: pixels))
            ?? (pixels == smallPixels ? nil : loader?.cachedFace(key: key(source)))
    }

    /// What to draw: the face this circle fetched, unless it has been handed
    /// another since. The Albums page's row is, when the page takes the NAS's
    /// new answer while it's out of sight; that face is usually in memory by
    /// the time you're back. See `CollectionCover.image`.
    private func shown(pixels: Int) -> PlatformImage? {
        if imageKey == Self.key(source) { return image }
        return Self.held(source, pixels: pixels, session: session) ?? image
    }

    /// The small face keeps the key it always had, so faces already on a
    /// device stay good.
    static func key(_ source: Source, pixels: Int = smallPixels) -> String {
        let base: String
        switch source {
        case .person(let person): base = "\(person.id)-\(person.face)"
        case .suggestion(let face): base = "\(face.assetID)-\(face.ordinal)"
        }
        return pixels == smallPixels ? base : "\(base)-\(pixels)"
    }

    var body: some View {
        // Read here, so the circle asks again in the large size once the NAS
        // has said it makes one.
        let pixels = Self.pixels(for: diameter, session: session)
        let face = shown(pixels: pixels)
        Circle()
            .fill(.quaternary)
            .overlay {
                if let face {
                    Image(platformImage: face)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: diameter * 0.42))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .task(id: Self.key(source, pixels: pixels)) { await load(pixels: pixels) }
    }

    private func load(pixels: Int) async {
        // Until its large face comes, a big circle shows the small one, which
        // is usually quicker to hand: on this device already, or made on the
        // NAS for the People rows. Not a face being asked about: nobody made
        // its small one, and making it would hold up the large one.
        var stopgap: Task<Void, Never>?
        if pixels != Self.smallPixels, image == nil, case .person = source {
            stopgap = Task {
                guard let small = await Self.fetch(session: session, spaceID: spaceID, source: source),
                      image == nil
                else { return }
                show(small)
            }
        }
        defer { stopgap?.cancel() }

        // A nil answer is a setback, not a verdict, as for the grid's tiles
        // (see PhotoCell): a face the NAS was still cutting when the request
        // gave up, or a connection dropped on the way, is asked for again
        // while its circle is on screen, with a widening gap. It used to be
        // asked for once, and a circle that missed stayed gray until the
        // screen was left and opened again (his screenshot, 2026-11-10).
        var gap: Duration = .seconds(1)
        while true {
            if let face = await Self.fetch(session: session, spaceID: spaceID, source: source, pixels: pixels) {
                stopgap?.cancel()
                show(face)
                return
            }
            guard !Task.isCancelled, gap <= .seconds(16) else { return }
            try? await Task.sleep(for: gap)
            gap *= 2
        }
    }

    /// No fade: the face is either there or it isn't.
    private func show(_ face: PlatformImage) {
        var instant = Transaction()
        instant.disablesAnimations = true
        let key = Self.key(source)
        withTransaction(instant) {
            image = face
            imageKey = key
        }
    }

    /// Fetches a face, or finds it already here. Also how "Is this Emma?"
    /// gets the next faces ready while the current one is being answered.
    /// `pixels` is `smallPixels` or `largePixels`; see `pixels(for:session:)`.
    @discardableResult
    static func fetch(
        session: AppSession, spaceID: UUID, source: Source, pixels: Int = smallPixels
    ) async -> PlatformImage? {
        guard let loader = session.loader, let client = session.client else { return nil }
        let key = key(source, pixels: pixels)
        if let held = loader.cachedFace(key: key) { return held }
        let size = pixels == smallPixels ? nil : pixels
        switch source {
        case .person(let person):
            guard let url = await client.personFaceURL(spaceID: spaceID, person: person, size: size)
            else { return nil }
            return await loader.face(at: url, key: key, pixels: pixels)
        case .suggestion(let face):
            guard let url = await client.assetFaceURL(
                spaceID: spaceID, assetID: face.assetID, ordinal: face.ordinal, size: size
            ) else { return nil }
            return await loader.face(at: url, key: key, persist: false, pixels: pixels)
        }
    }
}

/// Someone on the People row or in the grid of everyone: their face, and
/// their name under it once they have one.
struct PersonBubble: View {
    let session: AppSession
    let spaceID: UUID
    let person: PersonSummary
    var diameter: CGFloat = PeopleMetrics.rowFace

    var body: some View {
        VStack(spacing: 7) {
            FaceCircle(session: session, spaceID: spaceID, source: .person(person), diameter: diameter)
            // The whole name, never cut off: two lines where it needs them,
            // broken between words ("Grandma / Deem"), and room for two kept
            // under every face, named or not, so the faces line up along the
            // row. A cut-off "Michael Ro…" looked unfinished (his word,
            // 2026-11-10).
            Text(caption)
                .font(.footnote.weight(.medium))
                .foregroundStyle(maybeFirstName == nil ? .primary : .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
                // Only a name too long for two lines shrinks, and only a
                // little: one long surname, such as "Featherstonehaugh".
                .minimumScaleFactor(0.75)
                .frame(width: diameter + 16)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(PersonView.countLine(person.photoCount))
    }

    /// For someone unnamed the NAS has a question about: the first name of
    /// who they may be. Never on a television, which only shows People.
    private var maybeFirstName: String? {
        #if os(tvOS)
        return nil
        #else
        guard person.name == nil, let maybe = person.maybe else { return nil }
        return maybe.name.split(separator: " ").first.map(String.init)
        #endif
    }

    private var caption: String {
        if let name = person.name { return name }
        if let first = maybeFirstName { return "\(first)?" }
        return " "
    }

    private var label: String {
        #if !os(tvOS)
        if person.name == nil, let maybe = person.maybe {
            return "Someone without a name, maybe \(maybe.name)"
        }
        #endif
        return person.name ?? "Someone without a name"
    }
}

// MARK: - Everyone

/// Everyone the NAS found, as a grid of faces: the named first, then the
/// unnamed the NAS thinks they know, and everyone else behind one More People
/// row. A page of every face at once was too much to go through (his word,
/// 2026-11-11); the NAS decides who goes where (`PersonSummary.place`).
struct PeopleListView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO
    /// The page behind More People: just those, with no further row.
    var onlyMore = false

    @State private var people: [PersonSummary]
    /// A "Yes" or "No" to the page's question is on its way.
    @State private var answering = false
    /// The NAS has no such question (404): left off for this visit.
    @State private var questionHidden = false
    @State private var failure: String?

    init(session: AppSession, space: SpaceDTO, initial: [PersonSummary], onlyMore: Bool = false) {
        self.session = session
        self.space = space
        self.onlyMore = onlyMore
        _people = State(initialValue: initial)
    }

    private var shown: [PersonSummary] {
        people.filter { onlyMore ? $0.place == .more : $0.place != .more }
    }

    private var more: [PersonSummary] {
        onlyMore ? [] : people.filter { $0.place == .more }
    }

    #if !os(tvOS)
    /// The first unnamed person the NAS has a guess about, asked at the top
    /// of the page as Photos asks "Is this photo of you?".
    private var questioned: PersonSummary? {
        guard !questionHidden else { return nil }
        return shown.first { $0.name == nil && $0.maybe != nil }
    }
    #endif

    var body: some View {
        GeometryReader { proxy in
            let layout = CollectionsLayout(width: proxy.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    #if !os(tvOS)
                    if let person = questioned, let maybe = person.maybe {
                        VStack(alignment: .leading, spacing: 6) {
                            PeopleQuestionBanner(
                                session: session, spaceID: space.id,
                                face: person, name: maybe.name,
                                answering: answering
                            ) { isPerson in
                                Task { await answer(person, maybe, isPerson: isPerson) }
                            }
                            if let failure {
                                Text(failure)
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 6)
                            }
                        }
                        .padding(.horizontal, layout.margin)
                    }
                    #endif

                    LazyVGrid(columns: layout.columns(.small), spacing: layout.gap) {
                        ForEach(shown) { person in
                            NavigationLink {
                                PersonView(session: session, space: space, person: person)
                            } label: {
                                PersonTile(
                                    session: session, spaceID: space.id, person: person,
                                    side: layout.side(.small)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, layout.margin)

                    if !more.isEmpty {
                        NavigationLink {
                            PeopleListView(session: session, space: space, initial: more, onlyMore: true)
                        } label: {
                            MorePeopleRow(session: session, spaceID: space.id, people: more)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, layout.margin)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle(onlyMore ? "More People" : "People")
        .floatingTabBarClearance()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        // Someone named or merged on their page is renamed or gone here.
        .modifier(FollowsOwnChanges(session: session) { await load() })
    }

    #if !os(tvOS)
    /// Answers the question for `person`'s whole group, the same call the
    /// person's own page makes, then reloads so the next question shows.
    private func answer(_ person: PersonSummary, _ maybe: PersonMaybe, isPerson: Bool) async {
        guard let client = session.client, !answering else { return }
        answering = true
        defer { answering = false }
        do {
            _ = try await client.answerMaybe(
                spaceID: space.id, groupID: person.id, maybe, isPerson: isPerson
            )
            failure = nil
            // The answer doesn't count as a library change (see
            // `AppSession.noteWrite`), so the Albums page is told.
            session.collectionsStore(for: space.id).expire()
            await load()
        } catch FrameStationClientError.http(status: 404, reason: _) {
            // A NAS from before these questions.
            questionHidden = true
        } catch FrameStationClientError.http(status: 409, reason: _) {
            // Named in the meantime: the list is whoever they are now.
            await load()
        } catch {
            failure = "Couldn't save: \(error.localizedDescription)"
        }
    }
    #endif

    private func load() async {
        guard let client = session.client,
              let everyone = try? await client.people(spaceID: space.id)
        else { return }
        people = onlyMore ? everyone.filter { $0.place == .more } : everyone
    }
}

#if !os(tvOS)
// MARK: - Questions

/// A question about someone, as a pill across the top of a page: a face, the
/// question, and a Yes and a No, drawn after Photos' "Is this photo of you?".
///
/// It only draws; the page that shows it makes the call, so the list and a
/// person's own page answer the same way.
struct PeopleQuestionBanner: View {
    let session: AppSession
    let spaceID: UUID
    /// Whose face to show.
    let face: PersonSummary
    /// Who the NAS thinks it may be.
    let name: String
    let answering: Bool
    /// Called with true for Yes and false for No.
    let onAnswer: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            FaceCircle(session: session, spaceID: spaceID, source: .person(face), diameter: 40)
                .accessibilityHidden(true)
            Text("Is this \(name)?")
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Yes") { onAnswer(true) }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .accessibilityLabel("Yes, this is \(name)")
            Button {
                onAnswer(false)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.1), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("No, not \(name)")
        }
        .disabled(answering)
        .peopleBannerStyle()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Is this \(name)?")
    }
}

/// "Found 12 more photos. Is this Morgan?" with a way into going through
/// them. Not a question to answer on the spot, so there is no No.
struct PeopleReviewBanner: View {
    let name: String
    let count: Int
    let session: AppSession
    let spaceID: UUID
    let person: PersonSummary
    let onReview: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            FaceCircle(session: session, spaceID: spaceID, source: .person(person), diameter: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(count == 1 ? "Found 1 more photo" : "Found \(count.formatted()) more photos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Is this \(name)?")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Review", action: onReview)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
        }
        .peopleBannerStyle()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            count == 1
                ? "Found 1 more photo. Is this \(name)?"
                : "Found \(count) more photos. Is this \(name)?"
        )
    }
}

private extension View {
    /// The pill both banners sit in. No wider than a phone's on a big
    /// screen, and placed by the page: from the margin on the list, centered
    /// under the face on someone's page.
    func peopleBannerStyle() -> some View {
        padding(10)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .frame(maxWidth: 560)
    }
}
#endif

/// The one row that stands for everyone behind More People: a few of their
/// faces, overlapping, and how many there are.
struct MorePeopleRow: View {
    let session: AppSession
    let spaceID: UUID
    let people: [PersonSummary]

    private static let face: CGFloat = 40

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: -Self.face * 0.3) {
                ForEach(people.prefix(4)) { person in
                    FaceCircle(session: session, spaceID: spaceID, source: .person(person), diameter: Self.face)
                        .overlay(Circle().stroke(.background, lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("More People")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(people.count == 1 ? "1 more person" : "\(people.count) more people")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: CollectionsLayout.cornerRadius, style: .continuous)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("More People, \(people.count)")
    }
}

/// The navigation stack's dismiss action, held so `PersonView` can go back
/// without reading `\.dismiss`. That page pushes the photo viewer, and on a
/// Mac a view that reads it is re-rendered by every new action the stack
/// hands out while the viewer is open, endlessly (see `DismissHandle`).
@MainActor
final class PageLeave {
    fileprivate var action: DismissAction?

    func dismiss() { action?() }
}

/// Keeps a `PageLeave` holding the current dismiss action; only this view
/// depends on it, and it draws nothing.
private struct PageLeaveCatcher: View {
    let handle: PageLeave
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // A property of a class nothing observes: no update follows from it.
        let _ = (handle.action = dismiss)
        Color.clear
    }
}

// MARK: - Someone's page

/// Everything someone is in, newest first, with their name and the person's
/// say over who they are.
///
/// The photos are a collection like any other (`CollectionKind.person`), so
/// the page is the same grid, viewer and paging as a trip's. What's added is
/// above the grid, in the toolbar, and on a long press.
struct PersonView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO

    /// Theirs as last answered: renaming, merging and each answer return it.
    @State private var person: PersonSummary
    @State private var naming = false
    @State private var reviewing = false
    @State private var merging = false
    @State private var failure: String?
    /// A "Yes" or "No" to the group's question is on its way.
    @State private var answering = false
    /// The NAS has no such question (404): left off for this visit.
    @State private var questionHidden = false
    /// Goes back to the list; see `PageLeave` for why it isn't read from the
    /// environment here.
    @State private var leave = PageLeave()
    /// Moves when "Is this Emma?" closes with answers, so the grid loads
    /// once rather than once an answer.
    @State private var reviewed = 0
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    init(session: AppSession, space: SpaceDTO, person: PersonSummary) {
        self.session = session
        self.space = space
        _person = State(initialValue: person)
    }

    static func countLine(_ count: Int) -> String {
        count == 1 ? "1 photo" : "\(count.formatted()) photos"
    }

    /// How they're called in the app's own words: their name, or "this
    /// person".
    private var called: String { person.name ?? "This Person" }

    /// "Daughter · 214 photos", "You · 214 photos", or just the count.
    private var headerLine: String {
        [person.isMe ? "You" : person.relationship?.word, Self.countLine(person.photoCount)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var collection: CollectionSummary {
        CollectionSummary(
            kind: .person, key: person.id.uuidString, title: person.name ?? "",
            subtitle: nil, count: person.photoCount, coverAssetIDs: []
        )
    }

    var body: some View {
        CollectionDetailView(
            session: session, space: space, collection: collection,
            header: AnyView(header),
            photoActions: Self.canEdit ? { item in AnyView(actions(for: item)) } : nil,
            revision: reviewed
        )
        #if !os(tvOS)
        .background { PageLeaveCatcher(handle: leave) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { menu }
        }
        .sheet(isPresented: $naming) {
            NamePersonSheet(session: session, spaceID: space.id, person: person) { changed in
                naming = false
                if let changed { person = changed }
            }
        }
        .sheet(isPresented: $reviewing) {
            PersonReviewView(session: session, spaceID: space.id, person: person) { changed in
                reviewing = false
                if let changed {
                    person = changed
                    reviewed += 1
                    // The answers don't count as library changes (see
                    // `AppSession.noteWrite`), so the Albums page is told.
                    session.collectionsStore(for: space.id).expire()
                }
            }
        }
        .sheet(isPresented: $merging) {
            MergePeopleSheet(session: session, spaceID: space.id, person: person) { changed in
                merging = false
                if let changed { person = changed }
            }
        }
        #endif
    }

    /// Correcting is for the screens with a keyboard and a pointer or a
    /// finger. A television shows the people and their names.
    static var canEdit: Bool {
        #if os(tvOS)
        return false
        #else
        return true
        #endif
    }

    /// The big face at the top of the page, by screen.
    private var headerFace: CGFloat {
        #if os(tvOS)
        return 240
        #elseif os(macOS)
        return 160
        #else
        return horizontalSizeClass == .compact ? 150 : 180
        #endif
    }

    private var nameFont: Font {
        #if os(macOS)
        return .system(size: 26, weight: .bold)
        #elseif os(tvOS)
        return .title2.weight(.bold)
        #else
        return .title.weight(.bold)
        #endif
    }

    /// The banners' distance from the edges: the Albums page's margins.
    private var bannerMargin: CGFloat {
        #if os(macOS)
        return 40
        #elseif os(tvOS)
        return 0
        #else
        return horizontalSizeClass == .compact ? 20 : 32
        #endif
    }

    private var header: some View {
        VStack(spacing: 10) {
            #if !os(tvOS)
            if person.name == nil, let maybe = person.maybe, !questionHidden {
                maybeCard(maybe)
            }
            #endif
            PersonTile(
                session: session, spaceID: space.id, person: person,
                side: headerFace, showsName: false
            )
            .padding(.top, 4)
            if let name = person.name {
                Text(name)
                    .font(nameFont)
                    .multilineTextAlignment(.center)
            }
            Text(headerLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            #if !os(tvOS)
            if person.name == nil {
                Button("Add Name") { naming = true }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .padding(.top, 4)
            } else if person.questions > 0 {
                PeopleReviewBanner(
                    name: called, count: person.questions,
                    session: session, spaceID: space.id, person: person
                ) { reviewing = true }
                .padding(.horizontal, bannerMargin)
                .padding(.top, 8)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            #endif
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 18)
    }

    #if !os(tvOS)
    /// "Is this Kathy Deem?" for the whole group, answered with one tap.
    private func maybeCard(_ maybe: PersonMaybe) -> some View {
        let stand = PersonSummary(id: maybe.id, name: maybe.name, photoCount: 0, face: maybe.face)
        return PeopleQuestionBanner(
            session: session, spaceID: space.id, face: stand,
            name: maybe.name, answering: answering
        ) { isPerson in
            Task { await answer(maybe, isPerson: isPerson) }
        }
        .padding(.horizontal, bannerMargin)
        .padding(.bottom, 6)
    }

    /// Yes folds the group into the named person and goes back to the list,
    /// which is told to load again; no keeps the page and drops the card.
    private func answer(_ maybe: PersonMaybe, isPerson: Bool) async {
        guard let client = session.client, !answering else { return }
        answering = true
        defer { answering = false }
        do {
            let answered = try await client.answerMaybe(
                spaceID: space.id, groupID: person.id, maybe, isPerson: isPerson
            )
            failure = nil
            // The answer doesn't count as a library change (see
            // `AppSession.noteWrite`), so the Albums page is told.
            session.collectionsStore(for: space.id).expire()
            if isPerson {
                leave.dismiss()
            } else {
                person = answered
            }
        } catch FrameStationClientError.http(status: 404, reason: _) {
            // A NAS from before these questions.
            questionHidden = true
        } catch FrameStationClientError.http(status: 409, reason: _) {
            // Named in the meantime: the page is whoever they are now.
            if let fresh = try? await client.people(spaceID: space.id).first(where: { $0.id == person.id }) {
                person = fresh
            } else {
                leave.dismiss()
            }
        } catch {
            failure = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private var menu: some View {
        Menu {
            Button {
                naming = true
            } label: {
                Label(person.name == nil ? "Add Name" : "Edit Name & Relationship", systemImage: "pencil")
            }
            if person.name != nil, person.questions > 0 {
                Button {
                    reviewing = true
                } label: {
                    Label("Review Photos", systemImage: "person.crop.circle.badge.questionmark")
                }
            }
            Button {
                merging = true
            } label: {
                Label("Merge With\u{2026}", systemImage: "person.2")
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }
    #endif

    @ViewBuilder
    private func actions(for item: TimelineItem) -> some View {
        Button(role: .destructive) {
            Task { await remove(item) }
        } label: {
            Label(
                person.name.map { "Not \($0)" } ?? "Not This Person",
                systemImage: "person.crop.circle.badge.xmark"
            )
        }
    }

    /// "Not Emma": the photo leaves her page and the NAS never puts it back.
    /// The grid follows by itself (`FollowsOwnChanges`).
    private func remove(_ item: TimelineItem) async {
        guard let client = session.client else { return }
        do {
            person = try await client.removeFromPerson(
                spaceID: space.id, personID: person.id, assetIDs: [item.assetID]
            )
            failure = nil
        } catch {
            failure = "Couldn't change that: \(error.localizedDescription)"
        }
    }
}

#if !os(tvOS)
// MARK: - Who's in a photo

/// Who's in one photo, in its Information panel: a face for each, named or
/// not, and the way to say who someone is where the NAS has it wrong.
struct PhotoPeopleSection: View {
    let session: AppSession
    let spaceID: UUID
    let assetID: UUID
    let faces: [PhotoFace]
    /// The photo's people as they are after a change.
    let onChanged: (PhotoPeopleResponse) -> Void

    @State private var editing: PhotoFace?

    static func label(_ face: PhotoFace) -> String {
        if face.isMe { return "You" }
        if let name = face.name { return name }
        return face.personID == nil ? "Unknown" : "Add Name"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("PEOPLE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .kerning(0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(faces) { face in
                        Button {
                            editing = face
                        } label: {
                            VStack(spacing: 6) {
                                FaceCircle(
                                    session: session, spaceID: spaceID,
                                    source: .suggestion(PersonSuggestion(assetID: assetID, ordinal: face.ordinal)),
                                    diameter: 52
                                )
                                // The whole name, on two lines where it needs
                                // them, as under every face in People.
                                Text(Self.label(face))
                                    .font(.caption)
                                    .foregroundStyle(face.name == nil && !face.isMe ? .secondary : .primary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2, reservesSpace: true)
                                    .minimumScaleFactor(0.85)
                                    .frame(width: 72)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Self.label(face))
                        .accessibilityHint("Says who this is")
                    }
                }
            }
            Text("Tap a face to say who it is.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { face in
            FaceIdentitySheet(session: session, spaceID: spaceID, assetID: assetID, face: face) { changed in
                editing = nil
                if let changed { onChanged(changed) }
            }
        }
    }
}

/// "Who is this?" for one face in a photo: someone already in People,
/// someone new, or nobody the NAS had it with.
///
/// Every answer is kept and learned from. The face becomes part of who the
/// person is to the NAS, which finds them in more photos for it, and it's
/// never put back with someone the owner said it isn't.
struct FaceIdentitySheet: View {
    let session: AppSession
    let spaceID: UUID
    let assetID: UUID
    let face: PhotoFace
    /// Who's in the photo after the change, or nil when nothing changed.
    let onFinished: (PhotoPeopleResponse?) -> Void

    @State private var name = ""
    @State private var everyone: [PersonSummary] = []
    @State private var isSaving = false
    @State private var failure: String?

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A group the NAS found that nobody has named yet: typing names them,
    /// rather than taking the face away from them.
    private var isUnnamedGroup: Bool { face.personID != nil && face.name == nil }

    /// The people with names, those matching what's typed; never who it is
    /// already.
    private var choices: [PersonSummary] {
        let named = everyone.filter { $0.name != nil && $0.id != face.personID }
        let typed = trimmed.lowercased()
        guard !typed.isEmpty else { return Array(named.prefix(40)) }
        return named.filter { ($0.name ?? "").lowercased().contains(typed) }
    }

    /// What's typed is someone's name already.
    private var typedIsSomeone: Bool {
        everyone.contains { $0.name?.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private var faceSource: FaceCircle.Source {
        .suggestion(PersonSuggestion(assetID: assetID, ordinal: face.ordinal))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        FaceCircle(session: session, spaceID: spaceID, source: faceSource, diameter: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(PhotoPeopleSection.label(face))
                                .font(.headline)
                            Text(
                                face.personID == nil ? "Not anyone in People yet"
                                    : face.isConfirmed ? "You said so" : "Your NAS thinks so"
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }
                    TextField(isUnnamedGroup ? "Their Name" : "Name", text: $name)
                        #if os(iOS)
                        .textContentType(.name)
                        #endif
                        .submitLabel(.done)
                        .onSubmit(saveTyped)
                } footer: {
                    Text(
                        "Your NAS learns from this. The face helps it find them in more of "
                        + "your photos, and it never puts a face back with someone you've "
                        + "said it isn't."
                    )
                }

                if !trimmed.isEmpty, !typedIsSomeone {
                    Section {
                        Button(action: saveTyped) {
                            Label(
                                isUnnamedGroup ? "Name Them \(trimmed)" : "New Person: \(trimmed)",
                                systemImage: isUnnamedGroup ? "pencil" : "person.badge.plus"
                            )
                        }
                    }
                }

                if !choices.isEmpty {
                    Section("People") {
                        ForEach(choices) { person in
                            Button {
                                Task { await assign(AssignFaceRequest(personID: person.id)) }
                            } label: {
                                HStack(spacing: 12) {
                                    FaceCircle(
                                        session: session, spaceID: spaceID,
                                        source: .person(person), diameter: 34
                                    )
                                    Text(person.isMe ? "\(person.name ?? "") (You)" : person.name ?? "")
                                }
                            }
                            // A name, not a link: the row is the button.
                            .foregroundStyle(.primary)
                        }
                    }
                }

                if face.personID != nil {
                    Section {
                        Button(role: .destructive) {
                            Task { await assign(AssignFaceRequest()) }
                        } label: {
                            Text(face.name.map { "Not \($0)" } ?? "Not This Person")
                        }
                    } footer: {
                        Text("The face leaves them, and your NAS won't put it with them again.")
                    }
                }

                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isSaving)
            .navigationTitle("Who Is This?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onFinished(nil) }
                }
            }
            .task {
                guard let client = session.client else { return }
                everyone = (try? await client.people(spaceID: spaceID)) ?? []
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    /// A typed name: the unnamed group's name, or someone new. A name that's
    /// someone's already is chosen from the list instead.
    private func saveTyped() {
        guard !trimmed.isEmpty, !typedIsSomeone else { return }
        if isUnnamedGroup, let personID = face.personID {
            Task { await nameGroup(personID) }
        } else {
            Task { await assign(AssignFaceRequest(newName: trimmed)) }
        }
    }

    private func assign(_ request: AssignFaceRequest) async {
        guard let client = session.client else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            onFinished(try await client.assignFace(
                spaceID: spaceID, assetID: assetID, ordinal: face.ordinal, request
            ))
        } catch {
            failure = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func nameGroup(_ personID: UUID) async {
        guard let client = session.client else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await client.namePerson(spaceID: spaceID, personID: personID, name: trimmed)
            onFinished(try await client.photoPeople(spaceID: spaceID, assetID: assetID))
        } catch {
            failure = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

// MARK: - Naming

/// Naming someone, or renaming them.
///
/// A name that's already someone else's asks whether they're the same
/// person: that's how two groups the NAS kept apart become one, which is the
/// most useful thing anyone can teach it.
struct NamePersonSheet: View {
    let session: AppSession
    let spaceID: UUID
    let person: PersonSummary
    /// The person as they are now, or nil when nothing changed.
    let onFinished: (PersonSummary?) -> Void

    @State private var name: String
    @State private var relationship: Relationship?
    @State private var isMe: Bool
    @State private var everyone: [PersonSummary] = []
    @State private var isSaving = false
    @State private var failure: String?
    /// Someone else already called what was typed, waiting on "same person?".
    @State private var namesake: PersonSummary?

    init(
        session: AppSession, spaceID: UUID, person: PersonSummary,
        onFinished: @escaping (PersonSummary?) -> Void
    ) {
        self.session = session
        self.spaceID = spaceID
        self.person = person
        self.onFinished = onFinished
        _name = State(initialValue: person.name ?? "")
        _relationship = State(initialValue: person.relationship)
        _isMe = State(initialValue: person.isMe)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Anything to save: a name, and something changed.
    private var canSave: Bool {
        !trimmed.isEmpty
            && (trimmed != person.name || relationship != person.relationship || isMe != person.isMe)
    }

    /// The named people whose names start with what's typed, as a way to say
    /// "it's them" with one tap.
    private var matches: [PersonSummary] {
        let typed = trimmed.lowercased()
        guard !typed.isEmpty else { return [] }
        return everyone.filter { other in
            guard other.id != person.id, let otherName = other.name?.lowercased() else { return false }
            return otherName.hasPrefix(typed)
        }
        .prefix(4)
        .map { $0 }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        FaceCircle(session: session, spaceID: spaceID, source: .person(person), diameter: 52)
                        TextField("Name", text: $name)
                            #if os(iOS)
                            .textContentType(.name)
                            #endif
                            .submitLabel(.done)
                            .onSubmit(save)
                    }
                } footer: {
                    Text(
                        "Only you see the names you give. Your NAS uses them to find "
                        + "this person in more of your photos, and asks when it isn't sure."
                    )
                }

                if !matches.isEmpty {
                    Section("Already in People") {
                        ForEach(matches) { other in
                            Button {
                                Task { await merge(into: other) }
                            } label: {
                                HStack(spacing: 12) {
                                    FaceCircle(
                                        session: session, spaceID: spaceID,
                                        source: .person(other), diameter: 34
                                    )
                                    Text(other.name ?? "")
                                    Spacer()
                                    Text("Same Person")
                                        .font(.footnote)
                                        .foregroundStyle(.tint)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }

                Section {
                    Toggle("This Is Me", isOn: $isMe)
                    if !isMe {
                        Picker("Relationship", selection: $relationship) {
                            Text("None").tag(Relationship?.none)
                            ForEach(Relationship.Kind.allCases, id: \.self) { kind in
                                Section {
                                    ForEach(kind.words) { word in
                                        Text(word.word).tag(Optional(word))
                                    }
                                }
                            }
                        }
                    }
                } footer: {
                    Text(
                        "Who they are to you, if you like. Only you see it, and it's how "
                        + "your albums know family from friends."
                    )
                }

                if person.name != nil {
                    Section {
                        Button("Remove Name", role: .destructive) {
                            Task { await rename(to: nil) }
                        }
                    } footer: {
                        Text("Their photos stay together, without a name.")
                    }
                }

                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isSaving)
            .navigationTitle(person.name == nil ? "Add Name" : "Edit")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onFinished(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog(
                "Is this the same person as \(namesake?.name ?? "")?",
                isPresented: Binding(get: { namesake != nil }, set: { if !$0 { namesake = nil } }),
                titleVisibility: .visible
            ) {
                if let namesake {
                    Button("Same Person") {
                        Task { await merge(into: namesake) }
                    }
                    Button("Someone Else") {
                        Task { await rename(to: trimmed) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Someone in People is already called \(namesake?.name ?? "that").")
            }
            .task { await loadEveryone() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 300)
        #endif
    }

    private func loadEveryone() async {
        guard let client = session.client else { return }
        everyone = (try? await client.people(spaceID: spaceID)) ?? []
    }

    private func save() {
        guard canSave else { return }
        if trimmed != person.name, let same = everyone.first(where: {
            $0.id != person.id && $0.name?.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            namesake = same
            return
        }
        Task { await rename(to: trimmed) }
    }

    /// The name, then who they are: each only if it changed. "This is me"
    /// takes the relationship's place; nobody is their own daughter.
    private func rename(to newName: String?) async {
        guard let client = session.client else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            var current = person
            if newName != person.name {
                current = try await client.namePerson(spaceID: spaceID, personID: person.id, name: newName)
            }
            if isMe != person.isMe {
                current = try await client.setIsMe(spaceID: spaceID, personID: person.id, isMe)
            }
            if !isMe, relationship != current.relationship {
                current = try await client.setRelationship(spaceID: spaceID, personID: person.id, relationship)
            }
            onFinished(current)
        } catch {
            failure = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// This person becomes `other`, who keeps their name.
    private func merge(into other: PersonSummary) async {
        guard let client = session.client else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let merged = try await client.mergePeople(
                spaceID: spaceID, personID: other.id, otherID: person.id
            )
            onFinished(merged)
        } catch {
            failure = "Couldn't merge: \(error.localizedDescription)"
        }
    }
}

// MARK: - Merging

/// "These two are the same person", picked from everyone else.
struct MergePeopleSheet: View {
    let session: AppSession
    let spaceID: UUID
    let person: PersonSummary
    let onFinished: (PersonSummary?) -> Void

    @State private var everyone: [PersonSummary]?
    @State private var picked: PersonSummary?
    @State private var isSaving = false
    @State private var failure: String?

    private var others: [PersonSummary] { (everyone ?? []).filter { $0.id != person.id } }

    var body: some View {
        NavigationStack {
            Group {
                if everyone == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if others.isEmpty {
                    ContentUnavailableView(
                        "No One Else Yet", systemImage: "person.2",
                        description: Text("Everyone your NAS finds in three or more photos appears here.")
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Choose who else this is. Their photos become one person's.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let failure {
                                Label(failure, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                            }
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: PeopleMetrics.rowFace + 14), spacing: 14)],
                                spacing: 22
                            ) {
                                ForEach(others) { other in
                                    Button {
                                        picked = other
                                    } label: {
                                        PersonBubble(session: session, spaceID: spaceID, person: other)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(16)
                    }
                    .disabled(isSaving)
                }
            }
            .navigationTitle("Merge With\u{2026}")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onFinished(nil) }
                }
            }
            .confirmationDialog(
                mergeTitle,
                isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } }),
                titleVisibility: .visible
            ) {
                if let picked {
                    Button("Merge") { Task { await merge(with: picked) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(mergeMessage)
            }
            .task {
                guard let client = session.client else { return }
                everyone = (try? await client.people(spaceID: spaceID)) ?? []
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }

    /// Who's left afterward: whoever has a name, this person when both or
    /// neither do.
    private func survivor(with other: PersonSummary) -> (keep: PersonSummary, absorb: PersonSummary) {
        person.name == nil && other.name != nil ? (other, person) : (person, other)
    }

    private var mergeTitle: String {
        guard let picked else { return "" }
        return "Merge with \(picked.name ?? "this person")?"
    }

    private var mergeMessage: String {
        guard let picked else { return "" }
        let (keep, absorb) = survivor(with: picked)
        if let kept = keep.name, let lost = absorb.name, kept != lost {
            return "Their photos become one person, called \(kept). The name \(lost) goes."
        }
        if let kept = keep.name {
            return "Their photos become one person, called \(kept)."
        }
        return "Their photos become one person."
    }

    private func merge(with other: PersonSummary) async {
        guard let client = session.client else { return }
        isSaving = true
        defer { isSaving = false }
        let (keep, absorb) = survivor(with: other)
        do {
            let merged = try await client.mergePeople(
                spaceID: spaceID, personID: keep.id, otherID: absorb.id
            )
            onFinished(merged)
        } catch {
            failure = "Couldn't merge: \(error.localizedDescription)"
        }
    }
}

// MARK: - Is this Emma?

/// The NAS's questions about someone, one face at a time.
///
/// Each answer is kept for good: a yes makes the face theirs and teaches the
/// NAS what they look like, a no means it never asks about that face for
/// them again.
struct PersonReviewView: View {
    let session: AppSession
    let spaceID: UUID
    let person: PersonSummary
    /// The person as the last answer left them, or nil with nothing answered.
    let onFinished: (PersonSummary?) -> Void

    @State private var queue: [PersonSuggestion] = []
    @State private var asked = 0
    @State private var answered = 0
    @State private var latest: PersonSummary?
    @State private var isLoading = true
    @State private var failure: String?
    @State private var finished = false

    private var called: String { person.name ?? "this person" }

    /// How many faces past the one on screen are fetched with it.
    ///
    /// These faces are cut on the NAS the first time they're asked for, a
    /// second or more each on its Celeron (see `FaceCropWarmer`, which cuts
    /// only the People row's circles ahead). Two ahead, one by one, fell
    /// behind anyone answering briskly, and the circle sat gray until its face
    /// filled it (his screenshot, 2026-11-16, at 28 of 50). The face on screen
    /// and the next four go at once: enough to keep the NAS's four cores
    /// ahead of a quick thumb, and inside the loader's six at a time (see
    /// `ThumbnailLoader.maxConcurrent`), so none of them waits in its line.
    private static let ahead = 4

    /// The face being asked about. Its picture is the NAS's large one where
    /// the NAS makes it (see `FaceCircle.pixels(for:session:)`), and the
    /// faces fetched ahead are fetched in that size.
    private static let faceDiameter: CGFloat = 224

    /// The longest the first question waits for its face before it shows
    /// without one. The circle goes on asking (see `FaceCircle.load`).
    private static let firstFaceWait: Duration = .seconds(6)

    /// Done, or a swipe down: either way out says what was answered, once.
    private func finish() {
        guard !finished else { return }
        finished = true
        onFinished(answered > 0 ? latest : nil)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                if isLoading {
                    ProgressView()
                } else if let current = queue.first {
                    Spacer(minLength: 0)
                    Text("Is this \(called)?")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    FaceCircle(
                        session: session, spaceID: spaceID,
                        source: .suggestion(current), diameter: Self.faceDiameter
                    )
                    .id(current.id)
                    Text("\(answered + 1) of \(asked)")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        Button {
                            Task { await answer(current, isPerson: false) }
                        } label: {
                            Text("No").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        Button {
                            Task { await answer(current, isPerson: true) }
                        } label: {
                            Text("Yes").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.large)
                    .frame(maxWidth: 360)
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                } else {
                    ContentUnavailableView(
                        "That's Everyone for Now", systemImage: "checkmark.circle",
                        description: Text(
                            "Your NAS will ask again when it finds more photos that "
                            + "might be \(called)."
                        )
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(person.name ?? "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish() }
                }
            }
            .task { await load() }
            // Moves with each answer. Leaving cancels whatever is still
            // waiting for a turn.
            .task(id: queue.first?.id) { await fetchAhead() }
        }
        .onDisappear { finish() }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
    }

    private func load() async {
        guard let client = session.client else { return }
        defer { isLoading = false }
        do {
            let found = try await client.personSuggestions(spaceID: spaceID, personID: person.id)
            // Setting the queue starts the first faces coming (see
            // `fetchAhead`); the spinner stays until the first is here, so
            // the first question opens with its face rather than gray.
            queue = found.suggestions
            asked = found.suggestions.count
            latest = found.person
            if let first = found.suggestions.first {
                await waitForFace(first)
            }
        } catch {
            failure = "Couldn't load: \(error.localizedDescription)"
        }
    }

    /// The face on screen and the next few, all at once, so each answer finds
    /// the next face already here. One already here or on its way costs
    /// nothing: the loader hands back the one it holds or the request it has
    /// out (see `ThumbnailLoader.image`).
    private func fetchAhead() async {
        let window = Array(queue.prefix(Self.ahead + 1))
        guard !window.isEmpty else { return }
        let session = session, spaceID = spaceID
        let pixels = FaceCircle.pixels(for: Self.faceDiameter, session: session)
        await withTaskGroup(of: Void.self) { group in
            for face in window {
                group.addTask {
                    _ = await FaceCircle.fetch(
                        session: session, spaceID: spaceID, source: .suggestion(face), pixels: pixels
                    )
                }
            }
        }
    }

    /// Returns when the face is here, or after `firstFaceWait`, whichever
    /// comes first.
    ///
    /// Not a task group: a group waits for every child before it returns,
    /// and a request already out doesn't stop for a cancel, so a slow face
    /// would have held the spinner past the limit. The fetch goes on after
    /// this returns and lands in the loader's cache for the circle.
    private func waitForFace(_ face: PersonSuggestion) async {
        let session = session, spaceID = spaceID
        let pixels = FaceCircle.pixels(for: Self.faceDiameter, session: session)
        let (done, signal) = AsyncStream<Void>.makeStream()
        Task {
            _ = await FaceCircle.fetch(
                session: session, spaceID: spaceID, source: .suggestion(face), pixels: pixels
            )
            signal.finish()
        }
        let timer = Task {
            try? await Task.sleep(for: Self.firstFaceWait)
            signal.finish()
        }
        // Ends at the first finish, and when the sheet closes first.
        for await _ in done {}
        timer.cancel()
    }

    private func answer(_ face: PersonSuggestion, isPerson: Bool) async {
        guard let client = session.client, queue.first == face else { return }
        // On to the next at once; the answer follows.
        queue.removeFirst()
        answered += 1
        do {
            latest = try await client.answerSuggestion(
                spaceID: spaceID, personID: person.id, face, isPerson: isPerson
            )
            failure = nil
        } catch {
            // Asked again, rather than lost.
            queue.insert(face, at: 0)
            answered -= 1
            failure = "Couldn't save that answer: \(error.localizedDescription)"
        }
    }
}
#endif
