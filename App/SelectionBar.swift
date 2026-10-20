// Selection is not iOS-only. Only the share sheet underneath it ever was.
#if !os(tvOS)
import FrameStationAPI
import FrameStationKit
import Foundation
import Observation
import SwiftUI

/// What the user has picked in the grid, and the things they can do with it.
///
/// Kept out of the view so the grid doesn't have to own the work — the actions
/// outlive the sheet that starts them, and a delete that is halfway through a
/// list must not stop because a row scrolled away.
@Observable
@MainActor
final class GridSelection {
    var isActive = false
    /// `space_assets.id` — the placement, which is what a removal acts on.
    private(set) var picked: [TimelineItem] = []

    private(set) var isWorking = false
    private(set) var progress = ""
    private(set) var lastError: String?

    var count: Int { picked.count }

    func contains(_ item: TimelineItem) -> Bool {
        picked.contains { $0.id == item.id }
    }

    func toggle(_ item: TimelineItem) {
        if let index = picked.firstIndex(where: { $0.id == item.id }) {
            picked.remove(at: index)
        } else {
            picked.append(item)
        }
    }

    func begin(with item: TimelineItem) {
        isActive = true
        if !contains(item) { picked.append(item) }
    }

    /// Re-times everything picked, in one call.
    ///
    /// One request rather than one per photo: each of these moves a file on the
    /// NAS, and a batch half-applied across fifty requests is a much worse thing
    /// to be left holding than one that either largely worked or largely didn't.
    func setCaptureTimes(
        _ plan: [EditCaptureTimeRequest.Item], in space: SpaceDTO,
        client: FrameStationClient?
    ) async -> MediaEditResponse? {
        guard let client, !plan.isEmpty else { return nil }
        isWorking = true
        defer { isWorking = false; progress = "" }
        progress = "Re-dating \(plan.count) item\(plan.count == 1 ? "" : "s")…"
        do {
            return try await client.setCaptureTimes(spaceID: space.id, items: plan)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Turns everything picked. Returns as soon as the record is written —
    /// thumbnails are regenerated on the NAS and arrive over delta sync.
    func rotate(
        _ rotation: MediaRotation, in space: SpaceDTO, client: FrameStationClient?
    ) async -> MediaEditResponse? {
        guard let client, !picked.isEmpty else { return nil }
        isWorking = true
        defer { isWorking = false; progress = "" }
        progress = "Rotating \(picked.count) item\(picked.count == 1 ? "" : "s")…"
        do {
            return try await client.rotate(
                spaceID: space.id, assetIDs: picked.map(\.assetID), rotation
            )
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func editTags(
        add: [String], remove: [String],
        in space: SpaceDTO, client: FrameStationClient?
    ) async -> Int {
        guard let client, !picked.isEmpty, !(add.isEmpty && remove.isEmpty) else { return 0 }
        isWorking = true
        defer { isWorking = false; progress = "" }

        var changed = 0
        for (index, item) in picked.enumerated() {
            progress = "Tagging \(index + 1) of \(picked.count)…"
            do {
                try await client.editTags(
                    spaceID: space.id, assetID: item.assetID, add: add, remove: remove
                )
                changed += 1
            } catch {
                lastError = error.localizedDescription
            }
        }
        return changed
    }

    func clear() {
        picked.removeAll()
        isActive = false
        lastError = nil
    }

    // MARK: - Actions

    /// The selected photos this person may remove from `space`: in a shared
    /// one, what they added, or everything if they made it. See
    /// `SpacePermissions.mayRemove`.
    func removable(from space: SpaceDTO, by user: UUID?) -> [TimelineItem] {
        picked.filter { space.allowsRemoving(addedBy: $0.uploadedBy, by: user) }
    }

    /// Removes the selected photos this person may remove from this library.
    /// The rest stay; the confirmation has already said so.
    func remove(from space: SpaceDTO, client: FrameStationClient?, user: UUID?) async -> Bool {
        let targets = removable(from: space, by: user)
        guard let client, !targets.isEmpty else { return false }
        isWorking = true
        defer { isWorking = false; progress = "" }

        var failed = 0
        for (index, item) in targets.enumerated() {
            progress = "Removing \(index + 1) of \(targets.count)…"
            do {
                try await client.removeAsset(spaceID: space.id, assetID: item.assetID)
            } catch {
                failed += 1
                lastError = error.localizedDescription
            }
        }
        // Keep the selection when something failed, so the user can see what is
        // still there and try again rather than guessing.
        if failed == 0 { clear() }
        return failed == 0
    }

    /// Downloads the originals so they can be handed to the share sheet —
    /// which is how a photo gets back into the iPhone's own library, via its
    /// Save. See `PhotoLibrarySaver`.
    ///
    /// Straight to disk, each as its own type. These were read whole into
    /// memory, which a long video can be too big for, and every photo was
    /// named `.jpg`, HEIC or not.
    func downloadOriginals(
        from space: SpaceDTO, client: FrameStationClient?
    ) async -> [DownloadedOriginal] {
        guard let client, !picked.isEmpty else { return [] }
        isWorking = true
        defer { isWorking = false; progress = "" }

        var originals: [DownloadedOriginal] = []
        let folder = DownloadedOriginal.freshFolder()
        for (index, item) in picked.enumerated() {
            progress = "Preparing \(index + 1) of \(picked.count)…"
            do {
                originals.append(try await DownloadedOriginal.fetch(item, into: folder, client: client))
            } catch {
                lastError = error.localizedDescription
            }
        }
        return originals
    }
}

/// The contextual bar that replaces the tab bar while selecting.
struct SelectionBar<MoreContent: View>: View {
    let selection: GridSelection
    let onShare: () -> Void
    let onAddToAlbum: () -> Void
    let onDelete: () -> Void
    /// Menu content, so More opens in place rather than routing back out to
    /// the timeline for a sheet.
    @ViewBuilder let moreMenu: () -> MoreContent

    var body: some View {
        VStack(spacing: 6) {
            if selection.isWorking, !selection.progress.isEmpty {
                Text(selection.progress)
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                action("Share", "square.and.arrow.up", onShare)
                action("Add to album", "rectangle.stack.badge.plus", onAddToAlbum)
                action("Delete", "trash", onDelete)
                Menu {
                    moreMenu()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "ellipsis").font(.system(size: 20))
                        Text("More").font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        // Floating rather than edge-to-edge, because on iOS 26 the tab bar
        // this stands in for floats too — a hard-edged bar in its place reads
        // as a different piece of furniture appearing, not as the same slot
        // changing what it offers.
        .glassBackground(
            in: RoundedRectangle(cornerRadius: 26, style: .continuous),
            interactive: false,
            fallback: .regularMaterial
        )
        .padding(.horizontal, 12)
        .disabled(selection.count == 0 || selection.isWorking)
    }

    private func action(
        _ title: String, _ symbol: String, _ perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 20))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

/// Wraps `UIActivityViewController` so "Save Image" puts a photo back in the
/// iPhone's own library — the round trip the user asked for.
#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    /// What `items` are on the NAS, when they're its originals. Save then goes
    /// through `SaveToPhotosActivity`, which saves them so backup knows them,
    /// and the system's own Save — which made every one a duplicate — is taken
    /// out of the sheet.
    var originals: [DownloadedOriginal] = []
    /// Told what to say once the sheet is done: that something was saved to
    /// this iPhone, or why it couldn't be. Not called for anything else.
    var onResult: ((ToastMessage) -> Void)?

    init(items: [URL], onResult: ((ToastMessage) -> Void)? = nil) {
        self.items = items
        self.onResult = onResult
    }

    init(originals: [DownloadedOriginal], onResult: ((ToastMessage) -> Void)? = nil) {
        self.items = originals.map(\.url)
        self.originals = originals
        self.onResult = onResult
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let onResult = onResult
        let save: [UIActivity] = originals.isEmpty ? [] : [
            SaveToPhotosActivity(originals: originals) { reason in
                onResult?(ToastMessage(text: reason, isFailure: true))
            },
        ]
        let controller = UIActivityViewController(activityItems: items, applicationActivities: save)
        if !save.isEmpty { controller.excludedActivityTypes = [.saveToCameraRoll] }
        let count = items.count
        controller.completionWithItemsHandler = { type, completed, _, _ in
            guard completed, let saved = Self.savedMessage(for: type, count: count) else { return }
            onResult?(ToastMessage(text: saved))
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

    /// What to confirm after a share, if anything: only for the destinations
    /// that put the files on this iPhone.
    ///
    /// Saving from a share sheet says nothing at all — the sheet closes and
    /// that's that — so after a wait for the originals to come down there was
    /// no telling whether they had landed. Sending them to someone else needs
    /// no word from us: that app has its own.
    private static func savedMessage(for type: UIActivity.ActivityType?, count: Int) -> String? {
        let items = count == 1 ? "" : " \(count) items"
        if type == SaveToPhotosActivity.type || type == .saveToCameraRoll {
            return "Saved\(items) to Photos"
        }
        // Files has no public constant; this is the identifier it reports.
        if type?.rawValue == "com.apple.DocumentManagerUICore.SaveToFiles" {
            return "Saved\(items) to Files"
        }
        return nil
    }
}

/// A line for `GridToast` or the viewer's own: what happened, and whether it
/// was something going wrong.
struct ToastMessage: Equatable {
    let text: String
    var isFailure = false
}

/// A line of confirmation along the bottom of a grid that goes away by itself —
/// for what leaves no trace on screen, like a photo saved back to this iPhone.
struct GridToast: ViewModifier {
    @Binding var message: ToastMessage?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Label(
                        message.text,
                        systemImage: message.isFailure
                            ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    )
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassCapsule(interactive: false, fallback: .regularMaterial)
                    // Above the floating tab bar, as the connection banner is.
                    .padding(.bottom, FloatingTabBarMetrics.contentInset)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(2.5))
                        guard !Task.isCancelled else { return }
                        self.message = nil
                    }
                }
            }
            .animation(.spring(duration: 0.35), value: message)
    }
}
#else
/// The same idea where there is no activity view controller.
///
/// `ShareLink` reaches the system share menu on macOS, which is the round trip
/// that matters there — AirDrop, Mail, Photos — and it needs the files to exist
/// already, which they do: the originals were downloaded before this appeared.
struct ShareSheet: View {
    let items: [URL]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.and.arrow.up").font(.largeTitle)
            Text("\(items.count) item\(items.count == 1 ? "" : "s") ready")
                .font(.headline)
            ShareLink(items: items) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            Button("Done") { dismiss() }
        }
        .padding(28)
        .frame(minWidth: 320)
    }
}
#endif
#endif

#if !os(tvOS)
/// The circle on each tile while selecting, numbered the way Photos does it.
struct SelectionMark: View {
    let isPicked: Bool

    var body: some View {
        ZStack {
            Circle().fill(isPicked ? AnyShapeStyle(Color.accentColor)
                                   : AnyShapeStyle(.black.opacity(0.25)))
            Circle().strokeBorder(.white, lineWidth: 1.5)
            if isPicked {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 22, height: 22)
    }
}
#endif
