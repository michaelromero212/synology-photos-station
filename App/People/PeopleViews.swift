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

    /// The face at the top of someone's page.
    static var headerFace: CGFloat {
        #if os(tvOS)
        return 180
        #else
        return 104
        #endif
    }

    /// How many people the Albums page carries; see
    /// `PeopleController.pageLimit`. A row this full may have more behind it.
    static let pageLimit = 20
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

    init(session: AppSession, spaceID: UUID, source: Source, diameter: CGFloat) {
        self.session = session
        self.spaceID = spaceID
        self.source = source
        self.diameter = diameter
        // Already decoded: drawn on the first frame, not one after.
        _image = State(initialValue: session.loader?.cachedFace(key: Self.key(source)))
    }

    static func key(_ source: Source) -> String {
        switch source {
        case .person(let person): return "\(person.id)-\(person.face)"
        case .suggestion(let face): return "\(face.assetID)-\(face.ordinal)"
        }
    }

    var body: some View {
        Circle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(platformImage: image)
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
            .task(id: Self.key(source)) { await load() }
    }

    private func load() async {
        if let face = await Self.fetch(session: session, spaceID: spaceID, source: source) {
            // No fade: the face is either there or it isn't.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { image = face }
        }
    }

    /// Fetches a face, or finds it already here. Also how "Is this Emma?"
    /// gets the next face ready while the current one is being answered.
    @discardableResult
    static func fetch(session: AppSession, spaceID: UUID, source: Source) async -> PlatformImage? {
        guard let loader = session.loader, let client = session.client else { return nil }
        let key = key(source)
        if let held = loader.cachedFace(key: key) { return held }
        switch source {
        case .person(let person):
            guard let url = await client.personFaceURL(spaceID: spaceID, person: person) else { return nil }
            return await loader.face(at: url, key: key)
        case .suggestion(let face):
            guard let url = await client.assetFaceURL(
                spaceID: spaceID, assetID: face.assetID, ordinal: face.ordinal
            ) else { return nil }
            return await loader.face(at: url, key: key, persist: false)
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
            // A blank line for someone unnamed, so every face sits at the same
            // height along the row.
            Text(person.name ?? " ")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: diameter + 10)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(person.name ?? "Someone without a name")
        .accessibilityValue(PersonView.countLine(person.photoCount))
    }
}

// MARK: - Everyone

/// Everyone the NAS found, as a grid of faces: the named first, then the
/// rest by how many photos they're in.
struct PeopleListView: View {
    @Bindable var session: AppSession
    let space: SpaceDTO

    @State private var people: [PersonSummary]

    init(session: AppSession, space: SpaceDTO, initial: [PersonSummary]) {
        self.session = session
        self.space = space
        _people = State(initialValue: initial)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: PeopleMetrics.rowFace + 14), spacing: 14)],
                spacing: 22
            ) {
                ForEach(people) { person in
                    NavigationLink {
                        PersonView(session: session, space: space, person: person)
                    } label: {
                        PersonBubble(session: session, spaceID: space.id, person: person)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .navigationTitle("People")
        .floatingTabBarClearance()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        // Someone named or merged on their page is renamed or gone here.
        .modifier(FollowsOwnChanges(session: session) { await load() })
    }

    private func load() async {
        guard let client = session.client,
              let everyone = try? await client.people(spaceID: space.id)
        else { return }
        people = everyone
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
    /// Moves when "Is this Emma?" closes with answers, so the grid loads
    /// once rather than once an answer.
    @State private var reviewed = 0

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

    private var header: some View {
        VStack(spacing: 10) {
            FaceCircle(
                session: session, spaceID: space.id, source: .person(person),
                diameter: PeopleMetrics.headerFace
            )
            Text(headerLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            #if !os(tvOS)
            if person.name == nil {
                Button("Add Name") { naming = true }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            } else if person.questions > 0 {
                Button {
                    reviewing = true
                } label: {
                    Label(
                        person.questions == 1
                            ? "Is This \(called)? 1 Photo"
                            : "Is This \(called)? \(person.questions) Photos",
                        systemImage: "person.crop.circle.badge.questionmark"
                    )
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
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
                                Text(Self.label(face))
                                    .font(.caption)
                                    .foregroundStyle(face.name == nil && !face.isMe ? .secondary : .primary)
                                    .lineLimit(1)
                                    .frame(width: 66)
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
                        source: .suggestion(current), diameter: 224
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
            queue = found.suggestions
            asked = found.suggestions.count
            latest = found.person
            prefetch()
        } catch {
            failure = "Couldn't load: \(error.localizedDescription)"
        }
    }

    /// The next two faces, so each answer shows the next face at once.
    private func prefetch() {
        for next in queue.dropFirst().prefix(2) {
            Task { await FaceCircle.fetch(session: session, spaceID: spaceID, source: .suggestion(next)) }
        }
    }

    private func answer(_ face: PersonSuggestion, isPerson: Bool) async {
        guard let client = session.client, queue.first == face else { return }
        // On to the next at once; the answer follows.
        queue.removeFirst()
        answered += 1
        prefetch()
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
