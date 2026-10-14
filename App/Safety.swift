import FrameStationAPI
import FrameStationKit
import SwiftUI

// MARK: - Deleting the account

/// Deleting this account, from More: what goes, what stays, and a last
/// confirmation.
///
/// The App Store requires it of any app where an account can be made, and an
/// invite code makes one. Spelled out item by item because "delete my account"
/// means different things to different people, and in a family library the
/// difference matters: what you put in a shared library stays with the family.
/// See the server's `AccountController`.
struct DeleteAccountSheet: View {
    @Bindable var session: AppSession
    let onDone: () -> Void

    @State private var confirming = false
    @State private var isDeleting = false
    @State private var failure: String?

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            Text("Delete Account")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 24)
                .padding(.top, 22)
            Form { sections }
                .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onDone)
                    .keyboardShortcut(.cancelAction)
                deleteButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 480, height: 560)
        .modifier(confirmation)
        #else
        NavigationStack {
            Form {
                sections
                Section {
                    deleteButton
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Delete Account")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDone)
                        .disabled(isDeleting)
                }
            }
        }
        .modifier(confirmation)
        .interactiveDismissDisabled(isDeleting)
        #endif
    }

    @ViewBuilder
    private var sections: some View {
        Section {
            Text(
                "This deletes your FrameStation account on \(server) and signs it out "
                    + "on every device, this one included. It can't be undone."
            )
        }

        Section("Deleted") {
            Bullet("Your Personal Space. Its photos and videos leave the app now, and "
                + "their files are erased from the NAS after \(Retention.days) days.")
            Bullet("Your albums, favorites, and what FrameStation learned about your "
                + "photos for curated albums.")
            Bullet("Shared libraries you own that no one else is in.")
        }

        Section("Kept") {
            Bullet("Photos and videos you added to shared libraries. They stay for "
                + "everyone else, shown as added by a former member.")
            Bullet("Shared libraries you own that others are in. Each passes to the "
                + "person who has been in it longest.")
            Bullet("Everything on \(Self.thisDevice). Nothing here is deleted.")
            if session.useDSMLogin {
                Bullet("Your Synology account. Only your NAS's administrator can "
                    + "remove that.")
            }
        }

        if let failure {
            Section {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            confirming = true
        } label: {
            if isDeleting {
                ProgressView()
            } else {
                Text("Delete Account")
            }
        }
        .disabled(isDeleting || session.client == nil)
    }

    private var confirmation: ConfirmDeletion {
        ConfirmDeletion(isPresented: $confirming, onConfirm: delete)
    }

    private var server: String { session.serverHost ?? "your NAS" }

    private static var thisDevice: String {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? "this iPad" : "this iPhone"
        #elseif os(tvOS)
        return "this Apple TV"
        #else
        return "this Mac"
        #endif
    }

    private func delete() {
        guard let client = session.client else { return }
        isDeleting = true
        failure = nil
        Task {
            defer { isDeleting = false }
            do {
                try await client.deleteAccount()
            } catch FrameStationClientError.http(let status, _) where status == 401 || status == 403 {
                // Already gone: this device's sign-in no longer works, which is
                // what deleting the account does. Most likely the delete went
                // through and its answer was lost on the way back.
            } catch {
                failure = "Your account wasn't deleted. \(error.localizedDescription)"
                return
            }
            onDone()
            session.accountDeleted()
        }
    }
}

/// The last question before deleting, as its own modifier so both layouts of
/// the sheet attach the same one.
private struct ConfirmDeletion: ViewModifier {
    @Binding var isPresented: Bool
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content.alert("Delete your account?", isPresented: $isPresented) {
            Button("Delete Account", role: .destructive, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your Personal Space and albums will be deleted. This can't be undone.")
        }
    }
}

/// A line in a list of what happens, hanging under its own bullet.
private struct Bullet: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Blocked people

/// What blocking does, said the same way wherever it's offered.
enum BlockWording {
    static var consequences: String {
        "You won't see what they add to shared libraries, or be notified when "
            + "they add something. They won't be told. You can unblock them in "
            + "\(whereToUnblock)."
    }

    private static var whereToUnblock: String {
        #if os(macOS)
        return "Settings"
        #else
        return "More"
        #endif
    }
}

/// Everyone this account has blocked, and the way back.
///
/// Blocking itself happens where you meet the person: the ••• menu on a photo
/// they added, or the menu beside their name in a shared library's people.
struct BlockedPeopleView: View {
    @Bindable var session: AppSession
    /// Whether the floating tab bar is over this. False in a sheet.
    var underTabBar = true

    @State private var people: [BlockedUserDTO]?
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                if let people {
                    if people.isEmpty {
                        Text("You haven't blocked anyone.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(people) { person in
                        HStack {
                            Text(person.displayName)
                            Spacer()
                            Button("Unblock") { unblock(person) }
                                #if !os(tvOS)
                                .buttonStyle(.borderless)
                                #endif
                        }
                    }
                } else if failure == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
                if let failure {
                    Text(failure).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text(
                    "You don't see what blocked people add to shared libraries, and "
                        + "you aren't notified when they add something. They aren't "
                        + "told you blocked them. To block someone, open a photo they "
                        + "added and choose Block from the ••• menu."
                )
            }
        }
        .navigationTitle("Blocked People")
        .floatingTabBarClearance(when: underTabBar)
        .task { await load() }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            people = try await client.blockedUsers()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func unblock(_ person: BlockedUserDTO) {
        guard let client = session.client else { return }
        Task {
            do {
                try await client.unblock(userID: person.id)
                people?.removeAll { $0.id == person.id }
                session.hiddenContentChanged()
            } catch {
                failure = "Couldn't unblock \(person.displayName). \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Reported photos, for a library's owner

/// One reported photo in a library's settings: what it is, who added it, why
/// it was reported, and the owner's two answers.
///
/// Not who reported it — see `ContentReportDTO`.
struct ReportedPhotoRow: View {
    let report: ContentReportDTO
    let loader: ThumbnailLoader?
    let onRemove: () -> Void
    let onKeep: () -> Void

    @State private var showLarger = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                showLarger = true
            } label: {
                ReportThumbnail(assetID: report.assetID, loader: loader, side: 64)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show the reported \(noun) larger")

            VStack(alignment: .leading, spacing: 4) {
                Text("Added by \(report.addedByName)")
                    .font(.subheadline.weight(.semibold))
                Text(reasons)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(when)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Button("Remove", role: .destructive, action: onRemove)
                    Button("Keep", action: onKeep)
                }
                #if !os(tvOS)
                .buttonStyle(.borderless)
                #endif
                .font(.subheadline.weight(.semibold))
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showLarger) {
            ReportedPhotoPreview(report: report, loader: loader) { showLarger = false }
        }
    }

    private var noun: String { report.mediaType == .video ? "video" : "photo" }

    private var reasons: String {
        report.reasons
            .map { ReportReason(rawValue: $0)?.label ?? $0 }
            .joined(separator: " · ")
    }

    private var when: String {
        let date = report.reportedAt.formatted(.dateTime.month(.abbreviated).day().year())
        return report.reportCount == 1
            ? "Reported \(date)"
            : "Reported by \(report.reportCount) people, last on \(date)"
    }
}

/// The reported photo at a size it can be judged at, before deciding.
private struct ReportedPhotoPreview: View {
    let report: ContentReportDTO
    let loader: ThumbnailLoader?
    let onDone: () -> Void

    @State private var image: PlatformImage?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle("Added by \(report.addedByName)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
        .task {
            // The still for a video: enough to decide on, without a player.
            image = await loader?.preview(assetID: report.assetID)
        }
    }
}

private struct ReportThumbnail: View {
    let assetID: UUID
    let loader: ThumbnailLoader?
    let side: CGFloat

    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary)
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: assetID) {
            image = await loader?.thumbnail(assetID: assetID)
        }
    }
}

// MARK: - From the viewer

/// The person a photo is credited to, while blocking them is confirmed. The
/// name is nil until the photo's details have loaded.
struct BlockTarget: Identifiable, Equatable {
    let id: UUID
    let name: String?
}

/// Report's reasons and Block's confirmation, for the viewer's ••• menu.
///
/// A modifier of its own because the viewer's chain is already as long as the
/// type checker will solve in reasonable time.
struct ViewerSafetyDialogs: ViewModifier {
    @Binding var reporting: TimelineItem?
    @Binding var blocking: BlockTarget?
    let libraryName: String
    let onReport: (TimelineItem, ReportReason) -> Void
    let onBlock: (BlockTarget) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                reporting?.mediaType == .video ? "Report this video?" : "Report this photo?",
                isPresented: .init(
                    get: { reporting != nil },
                    set: { if !$0 { reporting = nil } }
                ),
                titleVisibility: .visible,
                presenting: reporting
            ) { item in
                ForEach(ReportReason.allCases, id: \.self) { reason in
                    Button(reason.label) { onReport(item, reason) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(
                    "It's hidden from you right away, and \(libraryName)'s owner is "
                        + "asked to review it. They aren't told who reported it."
                )
            }
            .confirmationDialog(
                "Block \(blocking?.name ?? "this person")?",
                isPresented: .init(
                    get: { blocking != nil },
                    set: { if !$0 { blocking = nil } }
                ),
                titleVisibility: .visible,
                presenting: blocking
            ) { target in
                Button("Block", role: .destructive) { onBlock(target) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(BlockWording.consequences)
            }
    }
}
