import Foundation

/// What `/health` lists when the server can do something newer than the oldest
/// app talking to it: delete an account, take reports and blocks, share an
/// album with people. The app offers each only where the server says it can,
/// so an app ahead of the NAS never shows a button that can only fail.
public enum ServerCapability {
    public static let accountDeletion = "account-deletion"
    public static let reportAndBlock = "report-and-block"
    /// Albums shared with the people you pick, rather than with a library.
    public static let peopleAlbums = "people-albums"
}

// MARK: - Reports

/// Why someone reported a photo. Sent as its raw value; a server that gets one
/// it doesn't know keeps it as written.
public enum ReportReason: String, Codable, Sendable, CaseIterable, Hashable {
    case inappropriate
    case spam
    case other

    /// How the app names it, for the person reporting and the owner reading.
    public var label: String {
        switch self {
        case .inappropriate: return "Inappropriate or offensive"
        case .spam: return "Spam or unwanted"
        case .other: return "Something else"
        }
    }
}

/// Reporting one photo in a shared library. `placementID` is the photo's place
/// in that library — `TimelineItem.id`.
public struct ReportPhotoRequest: Codable, Sendable {
    public let placementID: UUID
    public let reason: ReportReason

    public init(placementID: UUID, reason: ReportReason) {
        self.placementID = placementID
        self.reason = reason
    }
}

/// A reported photo waiting on its library's owner: one entry a photo, however
/// many people reported it.
///
/// Who reported it isn't part of it. In a family, a report someone has to put
/// their name to is one they often won't make.
public struct ContentReportDTO: Codable, Sendable, Identifiable, Hashable {
    /// The photo's place in the library, which removing or keeping it acts on.
    public let id: UUID
    /// The photo itself, for its thumbnail.
    public let assetID: UUID
    public let mediaType: MediaType
    /// Each reason given, newest first; usually `ReportReason` raw values.
    public let reasons: [String]
    /// How many people reported it.
    public let reportCount: Int
    /// Who the photo counts as added by.
    public let addedByName: String
    /// When it was last reported.
    public let reportedAt: Date

    public init(
        id: UUID, assetID: UUID, mediaType: MediaType, reasons: [String],
        reportCount: Int, addedByName: String, reportedAt: Date
    ) {
        self.id = id
        self.assetID = assetID
        self.mediaType = mediaType
        self.reasons = reasons
        self.reportCount = reportCount
        self.addedByName = addedByName
        self.reportedAt = reportedAt
    }
}

public struct ContentReportsResponse: Codable, Sendable {
    public let reports: [ContentReportDTO]

    public init(reports: [ContentReportDTO]) {
        self.reports = reports
    }
}

/// What the owner decided: take the photo out of the library, or keep it.
public enum ReportOutcome: String, Codable, Sendable {
    case removed
    case kept
}

public struct ResolveReportRequest: Codable, Sendable {
    public let outcome: ReportOutcome

    public init(outcome: ReportOutcome) {
        self.outcome = outcome
    }
}

// MARK: - Blocks

/// Someone this account has blocked.
public struct BlockedUserDTO: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let displayName: String
    public let blockedAt: Date

    public init(id: UUID, displayName: String, blockedAt: Date) {
        self.id = id
        self.displayName = displayName
        self.blockedAt = blockedAt
    }
}

public struct BlockedUsersResponse: Codable, Sendable {
    public let users: [BlockedUserDTO]

    public init(users: [BlockedUserDTO]) {
        self.users = users
    }
}
