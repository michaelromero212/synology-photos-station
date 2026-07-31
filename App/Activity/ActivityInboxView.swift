import FrameStationAPI
import FrameStationKit
import Foundation
import Observation
import SwiftUI

/// Recent shared-space contributions, and the read watermark.
@Observable
@MainActor
final class ActivityStore {
    private(set) var items: [ActivityItemDTO] = []
    private(set) var unreadCount = 0
    private(set) var isLoading = false
    private(set) var lastError: String?

    private weak var session: AppSession?

    init(session: AppSession) { self.session = session }

    func refresh() async {
        guard let client = session?.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let feed = try await client.activityFeed()
            items = feed.items
            unreadCount = feed.unreadCount
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Clears the badge immediately, then tells the server. The optimistic
    /// update matters: tapping "Clear All" and watching the badge sit there
    /// while a round-trip completes reads as a broken button.
    func markAllRead() async {
        guard let client = session?.client else { return }
        let previous = items
        items = items.map {
            ActivityItemDTO(
                id: $0.id, spaceID: $0.spaceID, spaceName: $0.spaceName, user: $0.user,
                photoCount: $0.photoCount, videoCount: $0.videoCount, isBulk: $0.isBulk,
                at: $0.at, isUnread: false
            )
        }
        unreadCount = 0
        do {
            try await client.markActivityRead()
        } catch {
            // Put the dots back rather than claim it worked.
            items = previous
            unreadCount = previous.filter(\.isUnread).count
            lastError = error.localizedDescription
        }
    }
}

struct ActivityInboxView: View {
    @Bindable var session: AppSession
    let store: ActivityStore
    let onOpen: (ActivityItemDTO) -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    ContentUnavailableView(
                        "Nothing new",
                        systemImage: "bell.slash",
                        description: Text("When someone adds photos or videos to a shared space, it shows up here.")
                    )
                } else {
                    List(store.items) { item in
                        Button { onOpen(item) } label: { row(item) }
                            .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Recent Activity")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear All") { Task { await store.markAllRead() } }
                        .disabled(store.unreadCount == 0)
                }
            }
            .refreshable { await store.refresh() }
            .overlay(alignment: .bottom) {
                if let error = store.lastError {
                    Text(error)
                        .font(.caption).foregroundStyle(.red)
                        .padding(8)
                }
            }
        }
    }

    private func row(_ item: ActivityItemDTO) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(item.isUnread ? Color.accentColor : .clear)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.summary)
                    .font(.subheadline)
                    .fontWeight(item.isUnread ? .semibold : .regular)
                HStack(spacing: 4) {
                    Image(systemName: "person.2").font(.caption2)
                    Text(item.spaceName)
                    Text("·")
                    Text(item.at, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
