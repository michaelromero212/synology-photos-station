#if !os(tvOS)
import FrameStationAPI
import FrameStationKit
import SwiftUI

/// Where selected photos go: Add to Album, and Add to Shared Album.
///
/// Three steps in one sheet, so nothing happens out of sight. **Pick**: a tap
/// checks a place and tints its row, as many as you like, and nothing is sent.
/// **Add**: one button, named for what it will do ("Add to OBX Beach Week
/// 2025", "Add to 3 Albums"), with who else will see the photos written above
/// it whenever anyone will. **Watch**: the sheet stays up and shows the work,
/// the photos and each place in turn, a spinner that becomes a checkmark. All
/// of it done and the sheet closes by itself a moment later. Anything that
/// failed stays on screen with why, and Try Again.
///
/// It used to add on the first tap and close, then put up an alert, and a
/// shared library's add ran after the sheet had gone with nothing on screen
/// until it was over. On a Mac that left people wondering whether anything had
/// happened at all.
///
/// Everything the Albums page lists under Albums and Shared Albums, in the same
/// order and under the same headings, with "New Album" at the top. Shared
/// libraries are here as well as the albums made in them: the Albums page
/// draws each library as an album, so a library is the "shared album" people
/// go looking for in this list.
struct AddToAlbumSheet: View {
    let session: AppSession
    /// What's being added. Placement ids go to an album (an album can only
    /// hold photos the owner can already see), asset ids to a shared library,
    /// and the first few are the stack of photos at the top.
    let items: [TimelineItem]
    /// The library the photos are in: not offered as somewhere to put them,
    /// and what a share into another library is from.
    var source: SpaceDTO?
    /// Whether shared libraries are offered. Only a library's own grid can
    /// share out of it.
    var offersLibraries = false
    /// The Shared Albums section and nothing else, for Add to Shared Album.
    var sharedOnly = false
    /// Told once the sheet should go: what was done, or nil when nothing was
    /// sent.
    let onFinished: (AlbumAddOutcome?) -> Void

    @State private var isLoading = true
    @State private var showNewAlbum = false
    /// The places checked, by id.
    @State private var picked: Set<UUID>
    /// New albums named here, made when Add is pressed, not before: Cancel
    /// after naming one leaves nothing behind on the NAS.
    @State private var drafts: [AlbumDraft] = []
    @State private var phase = Phase.picking
    /// What Add sent, as it was when pressed. The list behind it can change
    /// under a refresh; this can't.
    @State private var run: [Destination] = []
    @State private var sent: [TimelineItem] = []
    @State private var states: [UUID: StepState] = [:]
    /// Shares into shared libraries that went through, for the grid to follow
    /// (the iPhone walks you through what arrived).
    @State private var shares: [LibraryShare] = []
    /// Set once `onFinished` has been called, so the timed close and a tap on
    /// Done can't both report.
    @State private var hasReported = false

    init(
        session: AppSession, items: [TimelineItem], source: SpaceDTO?,
        offersLibraries: Bool = false, sharedOnly: Bool = false,
        preselected: Set<UUID> = [],
        onFinished: @escaping (AlbumAddOutcome?) -> Void
    ) {
        self.session = session
        self.items = items
        self.source = source
        self.offersLibraries = offersLibraries
        self.sharedOnly = sharedOnly
        self.onFinished = onFinished
        _picked = State(initialValue: preselected)
    }

    private var store: AlbumStore { session.albumStore() }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .picking:
                    if isLoading && store.albums.isEmpty && libraries.isEmpty {
                        ProgressView()
                    } else if sharedOnly && sharedRows.isEmpty {
                        noSharedAlbums
                    } else {
                        picker
                    }
                case .working, .finished:
                    progress
                }
            }
            .navigationTitle(phase == .picking ? title : "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            // The Albums page's New Album, with "Done" in place of "Create":
            // named here, the album joins the list checked and is made when
            // Add is pressed, along with everything else picked.
            .sheet(isPresented: $showNewAlbum) {
                NewAlbumSheet(session: session, store: store) { _ in
                    showNewAlbum = false
                } onDraft: { draft in
                    showNewAlbum = false
                    drafts.insert(draft, at: 0)
                    picked.insert(draft.id)
                }
            }
            .sensoryFeedback(.success, trigger: phase) { _, new in
                new == .finished && failures == 0
            }
            .task {
                await load()
            }
        }
        // Nothing to stop halfway: the NAS is already doing it.
        .interactiveDismissDisabled(phase == .working)
        .macSheetSize()
    }

    /// "it" for one photo, "them" for more, wherever a sentence points back
    /// at what's being added.
    private var them: String {
        (phase == .picking ? items.count : sent.count) == 1 ? "it" : "them"
    }

    private var title: String {
        sharedOnly ? "Add to Shared Album" : "Add to Album"
    }

    private static func counted(_ count: Int) -> String {
        "\(count.formatted()) item\(count == 1 ? "" : "s")"
    }

    /// "24 Items", for a heading.
    private static func countedTitle(_ count: Int) -> String {
        "\(count.formatted()) Item\(count == 1 ? "" : "s")"
    }

    // MARK: - Toolbar and the Add button

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch phase {
        case .picking:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onFinished(nil) }
            }
            #if os(macOS)
            // A Mac sheet's buttons are its bottom row, and Return presses
            // this one.
            ToolbarItem(placement: .confirmationAction) {
                Button(addTitle) { start() }
                    .disabled(picked.isEmpty)
            }
            #endif
        case .working:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {}.disabled(true)
            }
        case .finished:
            if failures > 0 {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { report() }
                }
                #if os(macOS)
                ToolbarItem(placement: .confirmationAction) {
                    Button("Try Again") { start(retrying: true) }
                }
                #endif
            } else {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { report() }
                }
            }
        }
    }

    /// Who else will see these, then on the phone the button itself, full
    /// width under the list where a thumb finds it.
    @ViewBuilder
    private var bottomBar: some View {
        let note = phase == .picking ? audienceNote : nil
        #if os(iOS)
        let button = phase == .picking || (phase == .finished && failures > 0)
        if note != nil || button {
            VStack(spacing: 10) {
                if let note {
                    noteLabel(note)
                }
                if phase == .picking {
                    Button { start() } label: {
                        Text(addTitle)
                            .font(.headline)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .disabled(picked.isEmpty)
                } else if button {
                    Button { start(retrying: true) } label: {
                        Text("Try Again")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(.bar)
        }
        #else
        if let note {
            noteLabel(note)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
        #endif
    }

    private func noteLabel(_ note: String) -> some View {
        Label(note, systemImage: "person.2.fill")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    /// Says what it will do: "Add to OBX Beach Week 2025", "Add to 3 Albums".
    private var addTitle: String {
        let chosen = pickedDestinations
        switch chosen.count {
        case 0: return "Add"
        case 1: return "Add to \(chosen[0].name)"
        default:
            return "Add to \(chosen.count) Albums"
        }
    }

    /// Who else will see the photos, when anyone will. Said before Add is
    /// pressed, where the old "Add to …?" question used to stop you, so the one
    /// button is the decision: everyone in a library sees what's added to it
    /// and is told, and an album's people see what's added to theirs.
    private var audienceNote: String? {
        var libraryNames: [String] = []
        var albumAudiences: [String] = []
        for destination in pickedDestinations {
            switch destination {
            case .library(let space):
                libraryNames.append(space.name)
            case .album(let album):
                if album.isSharedWithPeople {
                    albumAudiences.append(album.name)
                } else if album.isLibraryAlbum {
                    libraryNames.append(libraryName(album.spaceID) ?? album.name)
                }
            case .new(let draft):
                if let library = draft.libraryName {
                    libraryNames.append(library)
                } else if draft.isShared {
                    albumAudiences.append(draft.name)
                }
            }
        }
        var seen = Set<String>()
        libraryNames = libraryNames.filter { seen.insert($0).inserted }
        if !libraryNames.isEmpty && albumAudiences.isEmpty {
            return "Everyone in \(Self.joined(libraryNames)) will see \(them) and be notified."
        }
        if libraryNames.isEmpty && !albumAudiences.isEmpty {
            return "Everyone in \(Self.joined(albumAudiences)) will see \(them)."
        }
        if !libraryNames.isEmpty {
            return "Everyone in \(Self.joined(libraryNames + albumAudiences)) will see \(them)."
        }
        return nil
    }

    private static func joined(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names.dropLast().joined(separator: ", ")), and \(names.last!)"
        }
    }

    private func libraryName(_ spaceID: UUID?) -> String? {
        guard let spaceID else { return nil }
        return session.sharedSpaces.first { $0.id == spaceID }?.name
    }

    // MARK: - Picking

    private var picker: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    PickedStack(items: items, side: 40, loader: session.loader)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.countedTitle(items.count))
                            .font(.headline)
                            .foregroundStyle(Color.primary)
                        Text(sharedOnly
                             ? "Choose who to share \(them) with."
                             : "Choose one or more albums.")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }

            if sharedOnly {
                Section("Shared Albums") {
                    ForEach(sharedRows) { destination in
                        destinationRow(destination)
                    }
                }
            } else {
                Section {
                    Button {
                        showNewAlbum = true
                    } label: {
                        Label("New Album", systemImage: "plus.rectangle.on.rectangle")
                    }
                    ForEach(drafts) { draft in
                        destinationRow(.new(draft))
                    }
                }

                if !store.personal.isEmpty {
                    // The same two headings as the Albums page, so an album is
                    // found under the same name in both.
                    Section("Albums") {
                        ForEach(store.personal) { album in
                            destinationRow(.album(album))
                        }
                    }
                }

                if !sharedRows.isEmpty {
                    Section("Shared Albums") {
                        ForEach(sharedRows) { destination in
                            destinationRow(destination)
                        }
                    }
                }
            }
        }
    }

    private var noSharedAlbums: some View {
        ContentUnavailableView {
            Label("No Shared Albums", systemImage: "person.2")
        } description: {
            Text(
                "Make a shared album on the Albums page, and everyone in it "
                + "sees the same photos."
            )
        }
    }

    /// A place, checked or not. The check is the selection mark the grid's
    /// photos wear, so a picked album looks like a picked photo. One you may
    /// only look at is dimmed, says so, and can't be picked.
    private func destinationRow(_ destination: Destination) -> some View {
        let isPicked = picked.contains(destination.id)
        let mayAdd = destination.mayAdd
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                if isPicked { picked.remove(destination.id) } else { picked.insert(destination.id) }
            }
        } label: {
            HStack(spacing: 12) {
                cover(for: destination)
                // `Color`, not the hierarchical styles: inside a button those
                // resolve against the accent tint, and every name came out red.
                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.name)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(detail(for: destination))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if mayAdd {
                    CheckCircle(isOn: isPicked)
                } else {
                    Image(systemName: "eye")
                        .foregroundStyle(Color.secondary)
                        .frame(width: 24, height: 24)
                }
            }
            .opacity(mayAdd ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        #if os(macOS)
        // A row with a checkmark, not a push button.
        .buttonStyle(.plain)
        #endif
        .disabled(!mayAdd)
        .listRowBackground(isPicked ? Color.accentColor.opacity(0.13) : nil)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    private func cover(for destination: Destination, side: CGFloat = 44) -> some View {
        switch destination {
        case .album(let album):
            AlbumRowCover(
                assetID: album.coverAssetID,
                placeholder: album.isFamily ? "person.2" : "rectangle.stack",
                loader: session.loader, side: side
            )
        case .library(let space):
            AlbumRowCover(
                assetID: store.libraries.first { $0.id == space.id }?.coverAssetID,
                placeholder: "person.2", loader: session.loader, side: side
            )
        case .new:
            // What its cover will be: the first photo going into it.
            AlbumRowCover(
                assetID: items.first?.assetID, placeholder: "rectangle.stack.badge.plus",
                loader: session.loader, side: side
            )
        }
    }

    private func detail(for destination: Destination) -> String {
        let detail = plainDetail(for: destination)
        return destination.mayAdd ? detail : "View only · \(detail)"
    }

    private func plainDetail(for destination: Destination) -> String {
        switch destination {
        case .album(let album):
            let count = Self.counted(album.itemCount)
            // Who'll see them, for an album shared with people.
            return album.isSharedWithPeople
                ? "\(ShareWording.card(for: album, me: session.user?.id)) · \(count)" : count
        case .library(let space):
            let summary = store.libraries.first { $0.id == space.id }
            let people = ShareWording.people(count: summary?.memberCount ?? space.memberCount)
            return summary.map { "\(people) · \(Self.counted($0.itemCount))" } ?? people
        case .new(let draft):
            return "New album · \(draft.audience)"
        }
    }

    // MARK: - Shared

    /// The shared libraries photos can go into from here. Only a grid that can
    /// share out of its library offers them.
    private var libraries: [SpaceDTO] {
        guard offersLibraries || sharedOnly, source != nil else { return [] }
        return session.sharedSpaces
    }

    /// The Albums page's Shared Albums, row for row and in its order: the
    /// same `AlbumStore.sharedEntries` that page and the Mac's sidebar list.
    /// Built separately, this list had its own rules, and on a Mac the sidebar
    /// showed two shared albums where Add to Shared Library offered one.
    ///
    /// What the photos are already in is left out: the library they're in,
    /// and from an album's own grid, that album. Ones you may only look at
    /// stay, dimmed and saying "View only" (`destinationRow`): a shared album
    /// missing from the list looked like a bug, where one that says why it
    /// can't be picked doesn't.
    private var sharedRows: [Destination] {
        store.sharedEntries(libraries: libraries).compactMap { entry in
            switch entry {
            case .library(let space):
                return space.id == source?.id ? nil : .library(space)
            case .album(let album):
                if album.isSharedWithPeople, let spaceID = album.spaceID,
                   spaceID == source?.id { return nil }
                return .album(album)
            }
        }
    }

    /// Every place, in the order the list draws them.
    private var destinations: [Destination] {
        if sharedOnly { return sharedRows }
        return drafts.map(Destination.new) + store.personal.map(Destination.album) + sharedRows
    }

    private var pickedDestinations: [Destination] {
        destinations.filter { picked.contains($0.id) }
    }

    // MARK: - Working

    private var failures: Int {
        run.filter { states[$0.id]?.isFailed == true }.count
    }

    private var finishedCount: Int {
        run.filter { states[$0.id]?.isDone == true }.count
    }

    /// The photos, what's happening to them, and each place with how it went:
    /// a little above the middle of the sheet, and scrolling only when there
    /// are more places than fit.
    private var progress: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                progressContent
                Spacer(minLength: 0)
                Spacer(minLength: 0)
            }
            ScrollView {
                progressContent
            }
        }
        .animation(.smooth(duration: 0.3), value: states)
        .animation(.smooth(duration: 0.3), value: phase)
    }

    private var progressContent: some View {
        VStack(spacing: 22) {
            ZStack(alignment: .bottomTrailing) {
                PickedStack(items: sent, side: 92, loader: session.loader)
                statusBadge
                    .offset(x: 6, y: 6)
            }
            .padding(.top, 20)

            VStack(spacing: 6) {
                Text(headline)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                Text(subline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 24)

            VStack(spacing: 0) {
                ForEach(Array(run.enumerated()), id: \.element.id) { index, destination in
                    if index > 0 { Divider().padding(.leading, 64) }
                    stepRow(destination)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary.opacity(0.6))
            )
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private var statusBadge: some View {
        ZStack {
            Circle().fill(.background)
            if phase == .working {
                ProgressView()
                    .controlSize(.small)
            } else if failures == 0 {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white, .green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white, .orange)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 34, height: 34)
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
    }

    private var headline: String {
        let count = Self.countedTitle(sent.count)
        switch phase {
        case .picking, .working:
            return "Adding \(count)…"
        case .finished:
            if failures == 0 { return "Added \(count)" }
            if finishedCount > 0 { return "Some Didn't Go" }
            return sent.count == 1 ? "Couldn't Add This" : "Couldn't Add These"
        }
    }

    private var subline: String {
        let places = run.count == 1 ? run[0].name
            : "\(run.count) albums"
        switch phase {
        case .picking, .working:
            if run.count > 1, finishedCount > 0 {
                return "To \(places): \(finishedCount) of \(run.count) done"
            }
            return "To \(places)"
        case .finished:
            if failures == 0 { return "\(sent.count == 1 ? "It's" : "They're") in \(places)." }
            if finishedCount == 0 { return "Nothing was added. Try again, or come back later." }
            return "Added to \(finishedCount) of \(run.count). The rest can be tried again."
        }
    }

    private func stepRow(_ destination: Destination) -> some View {
        let state = states[destination.id] ?? .waiting
        return HStack(spacing: 12) {
            cover(for: destination, side: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.name)
                    .lineLimit(1)
                Text(state.caption)
                    .font(.caption)
                    .foregroundStyle(state.isFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Group {
                switch state {
                case .waiting:
                    Image(systemName: "circle.dotted")
                        .foregroundStyle(.tertiary)
                case .working:
                    ProgressView().controlSize(.small)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .font(.title3)
            .frame(width: 26, height: 26)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Loading and adding

    /// The Albums page's own list, asked again, so this sheet and that page
    /// never disagree about what albums there are.
    private func load() async {
        defer { isLoading = false }
        await store.refresh()
    }

    /// Adds to every place picked, one after another, so each row's spinner
    /// turns into its checkmark in turn and the NAS isn't handed them all at
    /// once. Again, only what didn't go the first time.
    private func start(retrying: Bool = false) {
        if !retrying {
            run = pickedDestinations
            sent = items
            states = Dictionary(uniqueKeysWithValues: run.map { ($0.id, StepState.waiting) })
        } else {
            for destination in run where states[destination.id]?.isFailed == true {
                states[destination.id] = .waiting
            }
        }
        guard !run.isEmpty else { return }
        withAnimation(.smooth(duration: 0.3)) { phase = .working }
        Task {
            // Each row's spinner stays long enough to see. An add can be back
            // in a hundredth of a second at home, and rows that all tick over
            // at once look like nothing was done. 0.7 s shared out across the
            // rows, never under 0.15 s a row, and nothing added to a slow one.
            let least = Duration.milliseconds(max(150, 700 / max(run.count, 1)))
            for destination in run where states[destination.id] == .waiting {
                let began = ContinuousClock.now
                states[destination.id] = .working
                let state = await add(to: destination)
                let took = ContinuousClock.now - began
                if took < least { try? await Task.sleep(for: least - took) }
                states[destination.id] = state
            }
            if run.contains(where: \.isAlbum) { albumsChanged() }
            withAnimation(.smooth(duration: 0.3)) { phase = .finished }
            guard failures == 0 else { return }
            // Seen, then gone: the checkmarks are the confirmation, and an
            // alert after them would be one more thing to dismiss.
            try? await Task.sleep(for: .milliseconds(1300))
            report()
        }
    }

    private func add(to destination: Destination) async -> StepState {
        guard let client = session.client else {
            return .failed("Not connected to your NAS.")
        }
        let count = sent.count
        do {
            switch destination {
            case .album(let album):
                let after = try await client.addToAlbum(
                    album.id, AlbumAssetsRequest(spaceAssetIDs: sent.map(\.id))
                )
                // Only when the counts add up: a number that might be wrong is
                // worse than none.
                let added = after.itemCount - album.itemCount
                if added >= 0, added < count {
                    return .done(note: added == 0
                        ? "Already there"
                        : "\(added) added, \(count - added) already there")
                }
                return .done(note: nil)
            case .new(let draft):
                _ = try await client.createAlbum(CreateAlbumRequest(
                    name: draft.name, spaceAssetIDs: sent.map(\.id),
                    spaceID: draft.spaceID,
                    memberIDs: draft.memberIDs.isEmpty ? nil : draft.memberIDs
                ))
                return .done(note: "Created")
            case .library(let space):
                guard let source else { return .failed("These can't be shared from here.") }
                let result = try await client.share(
                    spaceID: source.id, assetIDs: sent.map(\.assetID), to: space.id
                )
                // A server that predates `alreadySharedAssetIDs` says only how
                // many arrived; anything sent that didn't was there already.
                let already = result.alreadySharedAssetIDs?.count
                    ?? max(count - result.shared, 0)
                guard result.shared + already > 0 else {
                    return .failed(count == 1
                        ? "That item is no longer in \(source.name)."
                        : "Those items are no longer in \(source.name).")
                }
                shares.append(LibraryShare(
                    destination: space, result: result, alreadyCount: already
                ))
                if result.shared == 0 { return .done(note: "Already there") }
                return .done(note: already > 0
                    ? "\(result.shared) added, \(already) already there" : nil)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func report() {
        guard !hasReported else { return }
        hasReported = true
        let done = run.filter { states[$0.id]?.isDone == true }
        guard !done.isEmpty else {
            onFinished(nil)
            return
        }
        onFinished(AlbumAddOutcome(
            everything: failures == 0, shares: shares, places: done.map(\.name)
        ))
    }

    /// The Albums page keeps its list between visits, and an album isn't part
    /// of any library's change log, so nothing else would tell it. Not awaited:
    /// the sheet has nothing to wait for.
    private func albumsChanged() {
        let store = session.albumStore()
        Task { await store.refresh() }
    }
}

// MARK: - Pieces

extension AddToAlbumSheet {
    fileprivate enum Phase { case picking, working, finished }

    fileprivate enum StepState: Equatable {
        case waiting, working
        case done(note: String?)
        case failed(String)

        var isDone: Bool { if case .done = self { true } else { false } }
        var isFailed: Bool { if case .failed = self { true } else { false } }

        var caption: String {
            switch self {
            case .waiting: "Waiting"
            case .working: "Adding…"
            case .done(let note): note ?? "Added"
            case .failed(let reason): reason
            }
        }
    }

    /// Somewhere the photos can go.
    fileprivate enum Destination: Identifiable {
        case album(AlbumDTO)
        case library(SpaceDTO)
        case new(AlbumDraft)

        var id: UUID {
            switch self {
            case .album(let album): album.id
            case .library(let space): space.id
            case .new(let draft): draft.id
            }
        }

        var name: String {
            switch self {
            case .album(let album): album.name
            case .library(let space): space.name
            case .new(let draft): draft.name
            }
        }

        /// An album, made or not, rather than a whole library.
        var isAlbum: Bool {
            if case .library = self { false } else { true }
        }

        /// Whether this person may put photos in it. False in a library or an
        /// album they may only look at.
        var mayAdd: Bool {
            switch self {
            case .album(let album): album.mayAdd
            case .library(let space): space.role != .viewer
            case .new: true
            }
        }
    }
}

/// What Add to Album did, for the grid behind it.
struct AlbumAddOutcome {
    /// Every place picked got them. Only then is the selection cleared:
    /// after a failure the photos stay picked, ready to try again.
    let everything: Bool
    /// Shares into shared libraries that went through.
    let shares: [LibraryShare]
    /// Every place that got them, by name, in the order they were added.
    let places: [String]
}

extension AppSession {
    /// Whether there's anywhere for Add to Shared Album to offer: a shared
    /// library, or an album shared with people. What decides whether the
    /// grid's right-click menu and the viewer show it at all.
    var hasSharedAlbums: Bool {
        !sharedSpaces.isEmpty || !albumStore().sharedWithPeople.isEmpty
    }
}

struct LibraryShare {
    let destination: SpaceDTO
    let result: ShareAssetsResponse
    /// How many were in the library before. See `MoveReview.alreadyCount`.
    let alreadyCount: Int
}

/// The grid's selection mark, for a row: a red check in a filled circle when
/// picked, an empty ring when not.
private struct CheckCircle: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1.5)
                .opacity(isOn ? 0 : 1)
            Circle()
                .fill(Color.accentColor)
                .opacity(isOn ? 1 : 0)
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .scaleEffect(isOn ? 1 : 0.4)
                .opacity(isOn ? 1 : 0)
        }
        .frame(width: 24, height: 24)
        .animation(.snappy(duration: 0.2), value: isOn)
    }
}

/// The photos being added, as a small fanned stack: the first three, the top
/// one straight and the two behind it turned out to either side.
private struct PickedStack: View {
    let items: [TimelineItem]
    let side: CGFloat
    let loader: ThumbnailLoader?

    var body: some View {
        let shown = Array(items.prefix(3))
        ZStack {
            ForEach(Array(shown.enumerated()).reversed(), id: \.element.id) { index, item in
                StackTile(item: item, loader: loader, side: side)
                    .rotationEffect(.degrees(angle(index, of: shown.count)))
                    .offset(x: offset(index, of: shown.count))
            }
        }
        .frame(width: side * (shown.count > 1 ? 1.45 : 1), height: side * 1.1)
        .accessibilityHidden(true)
    }

    private func angle(_ index: Int, of count: Int) -> Double {
        switch (index, count) {
        case (1, 2): 8
        case (1, 3): -9
        case (2, 3): 9
        default: 0
        }
    }

    private func offset(_ index: Int, of count: Int) -> CGFloat {
        switch (index, count) {
        case (1, 2): side * 0.16
        case (1, 3): -side * 0.2
        case (2, 3): side * 0.2
        default: 0
        }
    }
}

private struct StackTile: View {
    let item: TimelineItem
    let loader: ThumbnailLoader?
    let side: CGFloat

    @State private var image: PlatformImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.14, style: .continuous)
        ZStack {
            shape.fill(.quaternary)
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white, lineWidth: side > 60 ? 3 : 1.5))
        .shadow(color: .black.opacity(0.2), radius: side > 60 ? 6 : 2, y: side > 60 ? 3 : 1)
        .task(id: item.assetID) {
            // The grid's own thumbnail, from memory where the grid has just
            // drawn it; asked for at the same size otherwise, so it's the same
            // cache entry.
            let size = PhotoGridMetrics.thumbnailPixels
            if image == nil {
                image = loader?.cachedThumbnail(
                    assetID: item.assetID, size: size, version: item.thumbnailVersion
                ) ?? loader?.cachedPlaceholder(assetID: item.assetID)
            }
            if let full = await loader?.thumbnail(
                assetID: item.assetID, size: size, version: item.thumbnailVersion
            ) {
                image = full
            }
        }
    }
}

/// An album's cover at the size of a list row, or its symbol until there is one.
private struct AlbumRowCover: View {
    let assetID: UUID?
    let placeholder: String
    let loader: ThumbnailLoader?
    var side: CGFloat = 44

    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            // `Color`, not `.quaternary`: inside a row's button the
            // hierarchical styles take the accent tint, and an album without
            // a cover yet came out as a red square.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.2))
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: placeholder)
                    .font(.body)
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: assetID) {
            guard let assetID, let loader else { return }
            image = await loader.thumbnail(assetID: assetID)
        }
    }
}

/// Which Add to Album to open: every album, or only the shared ones.
struct AddToAlbumRequest: Identifiable {
    let id = UUID()
    var sharedOnly = false
}

/// Presenting the sheet and the selection-wide "Done" alert as one modifier.
///
/// Not tidiness: attached inline, these pushed the timeline's modifier chain
/// past what the type checker will solve, and it gave up with an "unable to
/// type-check in reasonable time" pointed at an unrelated line.
struct AddToAlbumPresentation: ViewModifier {
    let session: AppSession
    let selection: GridSelection
    /// The library the selection is in. See `AddToAlbumSheet.source`.
    var source: SpaceDTO?
    /// See `AddToAlbumSheet.offersLibraries`.
    var offersLibraries = false
    @Binding var request: AddToAlbumRequest?
    @Binding var result: String?
    /// What the grid does once the sheet has gone: refresh after a share,
    /// and on the phone walk through what arrived.
    var onDone: (AlbumAddOutcome) -> Void = { _ in }

    /// What the sheet did, acted on once it has finished closing.
    @State private var outcome: AlbumAddOutcome?

    func body(content: Content) -> some View {
        content
            // Acted on once the sheet has *finished* going: followed as it
            // began to close, a share's walk-through started mid-animation,
            // and on a Mac what came after opened as an empty box.
            .sheet(item: $request, onDismiss: {
                guard let done = outcome else { return }
                outcome = nil
                if done.everything { selection.clear() }
                onDone(done)
            }) { request in
                AddToAlbumSheet(
                    session: session,
                    items: selection.picked,
                    source: source,
                    offersLibraries: offersLibraries,
                    sharedOnly: request.sharedOnly
                ) { done in
                    outcome = done
                    self.request = nil
                }
            }
            // "Done" rather than "Added": every selection action that reports a
            // count comes through this one alert, and most of them aren't adds.
            .alert("Done", isPresented: Binding(
                get: { result != nil }, set: { if !$0 { result = nil } }
            )) {
                Button("OK") { result = nil }
            } message: {
                Text(result ?? "")
            }
    }
}
#endif
