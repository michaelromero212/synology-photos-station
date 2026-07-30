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

    func add(_ userID: UUID, to spaceID: UUID) async {
        do {
            try await client.addMember(spaceID: spaceID, userID: userID)
            await loadMembers(spaceID: spaceID)
        } catch let failure { error = failure.localizedDescription }
    }

    func remove(_ userID: UUID, from spaceID: UUID) async {
        do {
            try await client.removeMember(spaceID: spaceID, userID: userID)
            await loadMembers(spaceID: spaceID)
        } catch let failure { error = failure.localizedDescription }
    }
}

/// Space management: create a shared space, see who's in it, add and remove.
struct SpacesView: View {
    @Bindable var session: AppSession
    let onDone: () -> Void

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
                        Text("No shared spaces yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(shared) { space in
                        if let model {
                            NavigationLink {
                                SpaceMembersView(space: space, model: model)
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
            .navigationTitle("Spaces")
            #if !os(tvOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
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

    var body: some View {
        List {
            if let members = model.members {
                Section("Members") {
                    ForEach(members.members) { member in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(member.user.displayName)
                                Text("\(member.role.rawValue.capitalized) · \(member.contributedCount) added")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if members.callerIsOwner, member.role != .owner {
                                Button("Remove", role: .destructive) {
                                    Task { await model.remove(member.user.id, from: space.id) }
                                }
                                .font(.caption)
                            }
                        }
                    }
                }

                if members.callerIsOwner {
                    let current = Set(members.members.map(\.user.id))
                    let candidates = model.household.filter { !current.contains($0.id) }
                    if !candidates.isEmpty {
                        Section("Add from household") {
                            ForEach(candidates) { user in
                                Button {
                                    Task { await model.add(user.id, to: space.id) }
                                } label: {
                                    Label(user.displayName, systemImage: "plus.circle")
                                }
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(space.name)
        .task { await model.loadMembers(spaceID: space.id) }
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
            .navigationTitle("New Shared Space")
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
