import FrameStationAPI
import FrameStationKit
import SwiftUI

#if !os(tvOS)

/// Correcting who a photo is credited to.
///
/// Not a rewrite of who uploaded it. The server keeps that as the fact it is —
/// which account's device sent the bytes — and this sets an override that
/// display prefers. So the sheet offers a way back: "whoever uploaded it" clears
/// the correction rather than guessing at another name.
///
/// Only members of the space are offered. Crediting someone who can't see the
/// photo would put a name on it that nobody viewing can resolve.
struct CreditEditorSheet: View {
    let session: AppSession
    let spaceID: UUID
    let assetIDs: [UUID]
    /// Shown so it's clear what the correction is departing *from*.
    let currentName: String
    let onFinished: (Bool) -> Void

    @State private var members: [SpaceMemberDTO] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if members.isEmpty {
                    ContentUnavailableView(
                        "No one to credit",
                        systemImage: "person.2",
                        description: Text("Only members of this album can be credited.")
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Added By")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onFinished(false) }
                }
            }
            .overlay(alignment: .bottom) {
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(8)
                }
            }
        }
        .task { await load() }
        .disabled(isSaving)
    }

    private var list: some View {
        List {
            Section {
                ForEach(members) { member in
                    Button {
                        Task { await apply(member.user.id) }
                    } label: {
                        HStack {
                            Text(member.user.displayName)
                            Spacer()
                            if member.user.displayName == currentName {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .tint(.primary)
                }
            } footer: {
                Text("Credit is a correction to what the photo says. Who actually uploaded it is kept either way.")
            }

            Section {
                Button("Use whoever uploaded it") {
                    Task { await apply(nil) }
                }
            }
        }
    }

    private func load() async {
        defer { isLoading = false }
        guard let client = session.client else { return }
        members = (try? await client.members(spaceID: spaceID).members) ?? []
    }

    private func apply(_ userID: UUID?) async {
        guard let client = session.client else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await client.setCredit(
                spaceID: spaceID, assetIDs: assetIDs, creditedTo: userID
            )
            onFinished(true)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#endif
