import FrameStationAPI
import FrameStationKit
import SwiftUI

/// Someone as a card: their face filling a rounded square, with their name on
/// it once they have one, the way Photos draws People.
///
/// The face is the NAS's crop, the one `FaceCircle` draws, fetched the same
/// way and kept in the same place. A square shows the whole crop where a
/// circle cut its corners off, and at these sizes it's the NAS's large crop on
/// every screen that has one, so a face is as sharp as the photos around it.
/// Square rather than Photos' taller cards: the crop is square, and a tall
/// card cut from it showed a face filling the card from ear to ear.
struct PersonTile: View {
    let session: AppSession
    let spaceID: UUID
    let person: PersonSummary
    let side: CGFloat
    /// False for the big face at the top of someone's own page, where the
    /// name sits under it instead.
    var showsName = true

    /// The smallest a card is ever drawn: three across the narrowest phone,
    /// two across a narrow Mac window, a television's row. Every card is the
    /// NAS's large crop at this size, so the Albums page gets faces ready at
    /// it before it shows them (`CollectionsStore`).
    static var smallestSide: CGFloat {
        #if os(macOS)
        return 150
        #elseif os(tvOS)
        return 240
        #else
        return 100
        #endif
    }

    @State private var image: PlatformImage?
    /// Whose face `image` is, by `FaceCircle.key(_:pixels:)`.
    @State private var imageKey: String?
    @State private var isHovering = false

    init(session: AppSession, spaceID: UUID, person: PersonSummary, side: CGFloat, showsName: Bool = true) {
        self.showsName = showsName
        self.session = session
        self.spaceID = spaceID
        self.person = person
        self.side = side
        // Already decoded: drawn on the first frame, not one after. A card
        // whose large face isn't here yet starts from the small one when that
        // is.
        let pixels = FaceCircle.pixels(for: side, session: session)
        let held = Self.held(.person(person), pixels: pixels, session: session)
        _image = State(initialValue: held)
        _imageKey = State(initialValue: held == nil ? nil : FaceCircle.key(.person(person)))
    }

    private var source: FaceCircle.Source { .person(person) }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CollectionsLayout.cornerRadius, style: .continuous)
    }

    var body: some View {
        // Read here, so the card asks again in the large size once the NAS
        // has said it makes one.
        let pixels = FaceCircle.pixels(for: side, session: session)
        let face = shown(pixels: pixels)
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let face {
                    Image(platformImage: face)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: side * 0.36))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: side, height: side)
            .overlay(alignment: .bottomLeading) { caption }
            .clipShape(shape)
            // A hairline, as every card on the page has, and a lift under the
            // pointer.
            .overlay {
                shape.strokeBorder(.white.opacity(isHovering ? 0.22 : 0.08), lineWidth: 0.5)
            }
            #if !os(tvOS)
            .brightness(isHovering ? 0.04 : 0)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .onHover { isHovering = $0 }
            #endif
            .contentShape(shape)
            .task(id: FaceCircle.key(source, pixels: pixels)) { await load(pixels: pixels) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(PersonView.countLine(person.photoCount))
    }

    // MARK: The name

    /// The name over a low dark ramp, or nothing at all for someone with no
    /// name and no guess: a face with a blank band under it read as a
    /// missing word.
    @ViewBuilder
    private var caption: some View {
        if showsName, let text = captionText {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.62), location: 0),
                        .init(color: .black.opacity(0.2), location: 0.3),
                        .init(color: .clear, location: 0.5),
                    ],
                    startPoint: .bottom, endPoint: .top
                )
                // The whole name, never cut off: two lines where it needs
                // them, and a little smaller only for a name too long for two.
                // A cut-off "Michael Ro…" looked unfinished (his word,
                // 2026-11-10).
                Text(text)
                    .font(nameFont)
                    .foregroundStyle(.white.opacity(maybeFirstName == nil ? 1 : 0.75))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .padding(inset)
                    #if os(iOS)
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                    #endif
            }
        }
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

    private var captionText: String? {
        if let name = person.name { return name }
        if let first = maybeFirstName { return "\(first)?" }
        return nil
    }

    private var label: String {
        #if !os(tvOS)
        if person.name == nil, let maybe = person.maybe {
            return "Someone without a name, maybe \(maybe.name)"
        }
        #endif
        return person.name ?? "Someone without a name"
    }

    /// A phone's three-across cards get the small type, anything bigger more.
    private var nameFont: Font {
        #if os(macOS)
        return .system(size: 13, weight: .semibold)
        #elseif os(tvOS)
        return .callout.weight(.semibold)
        #else
        return side >= 150 ? .subheadline.weight(.semibold) : .footnote.weight(.semibold)
        #endif
    }

    private var inset: CGFloat {
        #if os(macOS)
        return 11
        #elseif os(tvOS)
        return 18
        #else
        return side >= 150 ? 12 : 9
        #endif
    }

    // MARK: The face

    /// A face already decoded, large or small, without asking for it.
    private static func held(
        _ source: FaceCircle.Source, pixels: Int, session: AppSession
    ) -> PlatformImage? {
        let loader = session.loader
        return loader?.cachedFace(key: FaceCircle.key(source, pixels: pixels))
            ?? (pixels == FaceCircle.smallPixels ? nil : loader?.cachedFace(key: FaceCircle.key(source)))
    }

    /// What to draw: the face this card fetched, unless it has been handed
    /// another person since. The Albums page's row is, when the page takes
    /// the NAS's new answer while it's out of sight; that face is usually in
    /// memory by the time you're back, and drawn from there.
    private func shown(pixels: Int) -> PlatformImage? {
        if imageKey == FaceCircle.key(source) { return image }
        return Self.held(source, pixels: pixels, session: session) ?? image
    }

    private func load(pixels: Int) async {
        // Until its large face comes, the card shows the small one, which is
        // usually quicker to hand: on this device already, or made on the NAS
        // for the People rows.
        var stopgap: Task<Void, Never>?
        if pixels != FaceCircle.smallPixels, shown(pixels: pixels) == nil {
            stopgap = Task {
                guard let small = await FaceCircle.fetch(session: session, spaceID: spaceID, source: source),
                      shown(pixels: pixels) == nil
                else { return }
                show(small)
            }
        }
        defer { stopgap?.cancel() }

        // A nil answer is a setback, not a verdict, as for the circles: asked
        // again while the card is on screen, with a widening gap.
        var gap: Duration = .seconds(1)
        while true {
            if let face = await FaceCircle.fetch(
                session: session, spaceID: spaceID, source: source, pixels: pixels
            ) {
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
        let key = FaceCircle.key(source)
        withTransaction(instant) {
            image = face
            imageKey = key
        }
    }
}
