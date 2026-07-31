import Foundation

/// What a push carries besides its text, so a tap can open the right place.
public enum PushPayloadKey {
    public static let spaceID = "spaceID"
    public static let kind = "kind"
    /// Someone added photos or videos to a shared space.
    public static let kindActivity = "activity"
}

/// The wording of an upload notification.
///
/// Pure and shared so the phrasing is testable without APNs in the loop, and so
/// the server and any future client-side preview can't drift.
public enum ActivityMessage {
    /// `"Morgan added 10 photos and 2 videos"`, or for an initial backup
    /// `"Morgan backed up 8,240 items"`.
    public static func body(
        name: String, photos: Int, videos: Int, isBulk: Bool
    ) -> String {
        let total = photos + videos
        if isBulk {
            let formatted = NumberFormatter.localizedString(
                from: NSNumber(value: total), number: .decimal
            )
            return "\(name) backed up \(formatted) items"
        }
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos) photo\(photos == 1 ? "" : "s")") }
        if videos > 0 { parts.append("\(videos) video\(videos == 1 ? "" : "s")") }
        // A session always has at least one item, but say something sane rather
        // than "Morgan added " if it somehow doesn't.
        guard !parts.isEmpty else { return "\(name) added something new" }
        return "\(name) added \(parts.joined(separator: " and "))"
    }
}

// MARK: - In-app activity feed

/// One "someone added photos" entry.
public struct ActivityItemDTO: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let spaceID: UUID
    public let spaceName: String
    public let user: UserDTO
    public let photoCount: Int
    public let videoCount: Int
    public let isBulk: Bool
    /// When they last added something. Not the moment the server closed the
    /// batch — after downtime that would report a backlog as "just now".
    public let at: Date
    public let isUnread: Bool
    /// Sent on the wire rather than computed per client, so the inbox and the
    /// push banner provably read the same and a non-Swift client can't invent
    /// its own phrasing.
    public let summary: String

    public init(
        id: UUID, spaceID: UUID, spaceName: String, user: UserDTO,
        photoCount: Int, videoCount: Int, isBulk: Bool, at: Date, isUnread: Bool
    ) {
        self.id = id
        self.spaceID = spaceID
        self.spaceName = spaceName
        self.user = user
        self.photoCount = photoCount
        self.videoCount = videoCount
        self.isBulk = isBulk
        self.at = at
        self.isUnread = isUnread
        self.summary = ActivityMessage.body(
            name: user.displayName, photos: photoCount, videos: videoCount, isBulk: isBulk
        )
    }
}

public struct ActivityFeedResponse: Codable, Sendable {
    public let items: [ActivityItemDTO]
    public let unreadCount: Int

    public init(items: [ActivityItemDTO], unreadCount: Int) {
        self.items = items
        self.unreadCount = unreadCount
    }
}
