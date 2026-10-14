import FrameStationAPI
import Foundation

/// Deleting the account, reporting a photo and blocking a member. See the
/// server's `AccountController` and `SafetyController`; `/health` lists
/// `ServerCapability` values for the ones a NAS can do.
extension FrameStationClient {
    /// Deletes this account on the NAS: its own library and albums, and every
    /// device signed in to it, this one included. What it added to shared
    /// libraries stays with the family.
    public func deleteAccount() async throws {
        try await sendEmpty(.delete, "v1/me")
    }

    /// Reports a photo in a shared library: hidden from this account at once,
    /// and the library's owner told.
    public func reportPhoto(spaceID: UUID, placementID: UUID, reason: ReportReason) async throws {
        try await sendBodyNoContent(
            .post, "v1/spaces/\(spaceID.uuidString)/reports",
            body: ReportPhotoRequest(placementID: placementID, reason: reason)
        )
    }

    /// The reported photos waiting on a library's owner. Owners only.
    public func openReports(spaceID: UUID) async throws -> [ContentReportDTO] {
        let response: ContentReportsResponse = try await get(
            "v1/spaces/\(spaceID.uuidString)/reports"
        )
        return response.reports
    }

    /// Closes a photo's reports as the owner decided. Removing the photo
    /// itself is the ordinary `removeAsset`, done first.
    public func resolveReports(
        spaceID: UUID, placementID: UUID, outcome: ReportOutcome
    ) async throws {
        try await sendBodyNoContent(
            .post,
            "v1/spaces/\(spaceID.uuidString)/reports/\(placementID.uuidString)/resolve",
            body: ResolveReportRequest(outcome: outcome)
        )
    }

    public func blockedUsers() async throws -> [BlockedUserDTO] {
        let response: BlockedUsersResponse = try await get("v1/blocks")
        return response.users
    }

    public func block(userID: UUID) async throws {
        try await sendEmpty(.put, "v1/blocks/\(userID.uuidString)")
    }

    public func unblock(userID: UUID) async throws {
        try await sendEmpty(.delete, "v1/blocks/\(userID.uuidString)")
    }
}
