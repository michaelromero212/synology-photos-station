import FrameStationAPI
import FrameStationKit
import Observation
import SwiftUI

@Observable
@MainActor
final class SpacesModel {
    var spaces: [SpaceDTO] = []
    var household: [UserDTO] = []
    var members: SpaceMembersResponse?
    var error: String?
    var isBusy = false

    private let client: FrameStationClient

    init(client: FrameStationClient) {
        self.client = client
    }

    func loadHousehold() async {
        do { household = try await client.household().users }
        catch let failure { error = failure.localizedDescription }
    }

    func loadMembers(spaceID: UUID) async {
        members = nil
        do { members = try await client.members(spaceID: spaceID) }
        catch let failure { error = failure.localizedDescription }
    }

    func create(name: String, memberIDs: [UUID]) async -> SpaceDTO? {
        isBusy = true
        defer { isBusy = false }
        do {
            return try await client.createSpace(
                CreateSpaceRequest(name: name, memberIDs: memberIDs)
            )
        } catch let failure {
            error = failure.localizedDescription
            return nil
        }
    }

    func add(_ userID: UUID, to spaceID: UUID, as role: SpaceRole = .contributor) async {
        do {
            try await client.addMember(spaceID: spaceID, userID: userID, role: role)
            await loadMembers(spaceID: spaceID)
        } catch let failure { error = failure.localizedDescription }
    }

    /// Changing a role and adding a member are the same call.
    ///
    /// The server's insert is an upsert — `ON CONFLICT … DO UPDATE SET role`,
    /// refusing to touch an owner — so there is one endpoint and no separate
    /// "promote" to keep in step with it.
    func setRole(_ role: SpaceRole, for userID: UUID, in spaceID: UUID) async {
        await add(userID, to: spaceID, as: role)
    }

    func remove(_ userID: UUID, from spaceID: UUID) async {
        do {
            try await client.removeMember(spaceID: spaceID, userID: userID)
            await loadMembers(spaceID: spaceID)
        } catch let failure { error = failure.localizedDescription }
    }

    /// Removing yourself. The server allows it without owner rights — see its
    /// `removeMember` — and refuses it for the owner, who has to delete the
    /// space instead.
    func leave(_ spaceID: UUID, as userID: UUID) async -> Bool {
        do {
            try await client.removeMember(spaceID: spaceID, userID: userID)
            return true
        } catch let failure {
            error = failure.localizedDescription
            return false
        }
    }

    func rename(_ spaceID: UUID, to name: String) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await client.renameSpace(spaceID, to: name)
            return true
        } catch let failure {
            error = failure.localizedDescription
            return false
        }
    }
}

/// Space management: create a shared space, see who's in it, add and remove.
struct SpacesView: View {
    @Bindable var session: AppSession
    /// Nil when this screen is pushed rather than presented.
    ///
    /// Three of the four places that show this were passing `{}` — an empty
    /// closure — and all three push it, where there is already a back chevron
    /// doing the job. So "Done" sat in the corner next to it doing nothing at
    /// all, which is worse than no button: it reads as broken rather than as
    /// absent. Only the sheet from the grid has somewhere for it to go.
    var onDone: (() -> Void)?

    @State private var model: SpacesModel?
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            List {
                Section("Your Library") {
                    ForEach(session.spaces.filter { $0.kind == .personal }) { space in
                        Label(space.name, systemImage: "person.crop.square")
                    }
                }

                Section("Shared") {
                    let shared = session.spaces.filter { $0.kind == .shared }
                    if shared.isEmpty {
                        Text("No shared albums yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(shared) { space in
                        if let model {
                            NavigationLink {
                                SpaceMembersView(
                                    space: space,
                                    model: model,
                                    currentUserID: session.user?.id
                                ) {
                                    Task { await session.refreshSpaces() }
                                }
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(space.name)
                                        Text("\(space.memberCount) member\(space.memberCount == 1 ? "" : "s")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "person.2")
                                }
                            }
                        }
                    }
                }

                if let error = model?.error {
                    Section { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Shared Albums")
            #if !os(tvOS)
            .toolbar {
                if let onDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showCreate = true } label: { Image(systemName: "plus") }
                }
            }
            #endif
            .sheet(isPresented: $showCreate) {
                if let model {
                    CreateSpaceView(model: model, currentUserID: session.user?.id) { created in
                        showCreate = false
                        Task { await session.refreshSpaces(selecting: created) }
                    }
                }
            }
            .task {
                guard let client = session.client else { return }
                let newModel = SpacesModel(client: client)
                model = newModel
                await newModel.loadHousehold()
            }
        }
    }
}

private struct SpaceMembersView: View {
    let space: SpaceDTO
    let model: SpacesModel
    /// So the caller can find itself in the roster — "Leave" is the same call as
    /// "Remove", pointed at yourself, and the row has to know which one it is.
    let currentUserID: UUID?
    /// Leaving takes this screen's own space away, so the list behind it has to
    /// be told before this pops.
    let onMembershipChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// The name as it stands, which is not `space.name`.
    ///
    /// `space` is a value copied when the row was tapped and it never changes
    /// again, so renaming left the title showing the old name until you backed
    /// out — and, worse, `commitRename` compared the draft against it, so
    /// renaming A to B and back to A decided nothing had changed and silently
    /// dropped the second rename. The server's members response carries the
    /// current name, which is what this tracks.
    @State private var currentName = ""
    @State private var draftName = ""
    @State private var confirmingRemoval: SpaceMemberDTO?
    @State private var confirmingLeave = false

    var body: some View {
        List {
            if let members = model.members {
                if members.callerIsOwner { nameSection }
                membersSection(members)
                if members.callerIsOwner { addSection(members) }
                if !members.callerIsOwner { leaveSection }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(currentName)
        .task {
            currentName = space.name
            draftName = space.name
            await model.loadMembers(spaceID: space.id)
            // The response is authoritative and `space` may already be stale —
            // someone else can have renamed it since this list was drawn.
            if let fresh = model.members?.name, fresh != currentName {
                currentName = fresh
                draftName = fresh
            }
        }
        // One source of truth, not two. The presented flag is *derived* from the
        // member being confirmed rather than stored beside it, so there is no
        // second piece of state to fall out of step — which is the shape of race
        // that made the log export button do nothing at all.
        .confirmationDialog(
            "Remove \(confirmingRemoval?.user.displayName ?? "")?",
            isPresented: .init(
                get: { confirmingRemoval != nil },
                set: { if !$0 { confirmingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                guard let target = confirmingRemoval else { return }
                confirmingRemoval = nil
                Task {
                    await model.remove(target.user.id, from: space.id)
                    onMembershipChanged()
                }
            }
            Button("Cancel", role: .cancel) { confirmingRemoval = nil }
        } message: {
            Text(Self.removalWarning(for: confirmingRemoval))
        }
        .confirmationDialog(
            "Leave \(currentName)?", isPresented: $confirmingLeave, titleVisibility: .visible
        ) {
            Button("Leave", role: .destructive) {
                guard let me = currentUserID else { return }
                Task {
                    if await model.leave(space.id, as: me) {
                        // Pop first, refresh second. The refresh takes this
                        // space out of the list this screen was pushed from, and
                        // pulling a navigation destination's own row out from
                        // under it while it is still on screen is how SwiftUI is
                        // made to do something strange.
                        dismiss()
                        onMembershipChanged()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "You lose access to everything in it, including anything you added. "
                    + "Only the owner can let you back in."
            )
        }
    }

    // MARK: - Sections

    /// Renaming was reachable from the server and the SDK and from nowhere a
    /// person could touch, so a space was stuck with whatever it was called at
    /// creation — and the field is pre-filled "Family Shared", which makes a
    /// typo permanent.
    @ViewBuilder
    private var nameSection: some View {
        Section("Name") {
            #if os(tvOS)
            Text(draftName)
            #else
            TextField("Name", text: $draftName)
                .submitLabel(.done)
                .onSubmit { commitRename() }
            #endif
        }
    }

    @ViewBuilder
    private func membersSection(_ members: SpaceMembersResponse) -> some View {
        Section {
            ForEach(members.members) { member in
                MemberRow(
                    member: member,
                    isYou: member.user.id == currentUserID,
                    canManage: members.callerIsOwner && member.role != .owner,
                    onRole: { role in
                        Task { await model.setRole(role, for: member.user.id, in: space.id) }
                    },
                    onRemove: { confirmingRemoval = member }
                )
            }
        } header: {
            Text("Members")
        } footer: {
            if members.callerIsOwner {
                // Said out loud because the row above shows "240 added" right
                // beside Remove, and the obvious reading is that the 240 leave
                // with the person. They don't, and that is the right policy —
                // shared memories shouldn't evaporate when someone goes — but it
                // is not something to discover afterwards.
                Text("Viewers can see everything here but can't add, edit or delete.")
            }
        }
    }

    @ViewBuilder
    private func addSection(_ members: SpaceMembersResponse) -> some View {
        let current = Set(members.members.map(\.user.id))
        let candidates = model.household.filter { !current.contains($0.id) }
        if !candidates.isEmpty {
            Section("Add from household") {
                ForEach(candidates) { user in
                    Button {
                        Task {
                            await model.add(user.id, to: space.id)
                            onMembershipChanged()
                        }
                    } label: {
                        Label(user.displayName, systemImage: "plus.circle")
                    }
                }
            }
        }
    }

    /// The server has always allowed this — its `removeMember` requires owner
    /// rights only when the target isn't you — and nothing in the app ever
    /// offered it, so a contributor was in a space permanently and had to ask
    /// the owner to be let out.
    @ViewBuilder
    private var leaveSection: some View {
        Section {
            Button("Leave Album", role: .destructive) { confirmingLeave = true }
                .disabled(currentUserID == nil)
        }
    }

    /// What removing this person actually does.
    ///
    /// The sentence about their contributions is only worth saying when there
    /// are some — "the 0 items they added stay here" is both noise and slightly
    /// absurd. When there are, it needs saying: the row shows "240 added" an
    /// inch from the Remove button and the natural reading is that the 240 go
    /// with them.
    private static func removalWarning(for member: SpaceMemberDTO?) -> String {
        let base = "They lose access to this album."
        guard let count = member?.contributedCount, count > 0 else { return base }
        return base + " The \(count) item\(count == 1 ? "" : "s") they added stay here."
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != currentName else {
            draftName = currentName
            return
        }
        Task {
            if await model.rename(space.id, to: trimmed) {
                currentName = trimmed
                draftName = trimmed
                onMembershipChanged()
            } else {
                // Put the field back rather than leaving a name on screen that
                // the server rejected.
                draftName = currentName
            }
        }
    }
}

/// One person in the roster.
///
/// Lifted out of the list rather than inlined: the row carries a menu whose
/// contents depend on three booleans, and leaving that inside the `ForEach`
/// inside the `Section` inside the `List` is how this file starts failing to
/// type-check in reasonable time.
private struct MemberRow: View {
    let member: SpaceMemberDTO
    let isYou: Bool
    let canManage: Bool
    let onRole: (SpaceRole) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(member.user.displayName + (isYou ? " (You)" : ""))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if canManage { menu }
        }
    }

    private var subtitle: String {
        let count = member.contributedCount
        return "\(member.role.rawValue.capitalized) · \(count) added"
    }

    @ViewBuilder
    private var menu: some View {
        Menu {
            // Both offered, with the current one ticked, so the menu says where
            // this person stands as well as where they could be moved to.
            Button {
                onRole(.contributor)
            } label: {
                if member.role == .contributor {
                    Label("Contributor", systemImage: "checkmark")
                } else {
                    Text("Contributor")
                }
            }
            Button {
                onRole(.viewer)
            } label: {
                if member.role == .viewer {
                    Label("Viewer", systemImage: "checkmark")
                } else {
                    Text("Viewer")
                }
            }
            Divider()
            Button("Remove", role: .destructive, action: onRemove)
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(Color.secondary)
        }
        .accessibilityLabel("Manage \(member.user.displayName)")
    }
}

private struct CreateSpaceView: View {
    let model: SpacesModel
    /// Excluded from the picker — the creator is always the owner, so offering
    /// to invite yourself is nonsense even though the server ignores it.
    let currentUserID: UUID?
    let onCreated: (SpaceDTO) -> Void

    @State private var name = "Family Shared"
    @State private var picked: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    #if os(tvOS)
                    Text(name)
                    #else
                    TextField("Family Shared", text: $name)
                    #endif
                }
                Section("Invite from household") {
                    let others = model.household.filter { $0.id != currentUserID }
                    if others.isEmpty {
                        Text("No one else has an account yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(others) { user in
                        Button {
                            if picked.contains(user.id) { picked.remove(user.id) }
                            else { picked.insert(user.id) }
                        } label: {
                            HStack {
                                Text(user.displayName)
                                Spacer()
                                if picked.contains(user.id) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        #if !os(tvOS)
                        .foregroundStyle(.primary)
                        #endif
                    }
                }
            }
            .navigationTitle("New Shared Album")
            #if !os(tvOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            if let created = await model.create(
                                name: name, memberIDs: Array(picked)
                            ) {
                                onCreated(created)
                            }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || model.isBusy)
                }
            }
            #endif
        }
    }
}
