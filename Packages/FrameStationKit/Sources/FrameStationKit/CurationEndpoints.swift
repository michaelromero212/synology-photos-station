import FrameStationAPI
import Foundation

// MARK: - Curation
//
// What this person's devices report about their own photographs, and their say
// over it. See ARCHITECTURE.md, "Curated albums".

extension FrameStationClient {
    /// Settings, and how far the analysis of this person's own library has got.
    public func curationStatus() async throws -> CurationStatus {
        try await get("v1/curation")
    }

    /// Changes only what's passed. Applies to every one of this person's
    /// devices, since the setting lives on the NAS.
    @discardableResult
    public func updateCurationSettings(
        enabled: Bool? = nil, holidays: Bool? = nil
    ) async throws -> CurationSettings {
        try await put(
            "v1/curation/settings",
            body: UpdateCurationSettingsRequest(enabled: enabled, holidays: holidays)
        )
    }

    /// Forgets everything this person's devices ever reported. Never the
    /// photographs, their albums, or anything named by hand.
    public func deleteCurationData() async throws {
        try await sendEmpty(.delete, "v1/curation/data")
    }

    /// Photos in this person's own library not yet analyzed at `analysisVersion`,
    /// newest first.
    public func pendingAnalysis(
        spaceID: UUID, analysisVersion: Int, limit: Int
    ) async throws -> PendingAnalysisResponse {
        try await get(
            "v1/spaces/\(spaceID)/curation/pending"
            + "?analysisVersion=\(analysisVersion)&limit=\(limit)"
        )
    }

    @discardableResult
    public func submitObservations(
        spaceID: UUID, _ request: SubmitObservationsRequest
    ) async throws -> SubmitObservationsResponse {
        try await post("v1/spaces/\(spaceID)/curation/observations", body: request)
    }

    /// What this person's devices saw in one photo. Nil when it hasn't been
    /// analyzed, and from a server that predates curation.
    public func observation(spaceID: UUID, assetID: UUID) async throws -> AssetObservationDetail? {
        do {
            return try await get("v1/spaces/\(spaceID)/assets/\(assetID)/observation")
        } catch FrameStationClientError.http(status: 404, reason: _) {
            return nil
        }
    }

    /// One thumbnail's bytes, straight from the NAS.
    ///
    /// Deliberately not through `ThumbnailLoader`. The analyzer looks at each
    /// photo once, and running a whole library through the image cache would
    /// push out the photos someone is actually browsing.
    public func thumbnailData(assetID: UUID, size: Int, version: Int) async throws -> Data {
        guard let url = thumbnailURL(assetID: assetID, size: size, version: version) else {
            throw FrameStationClientError.invalidURL("thumbnail")
        }
        var request = URLRequest(url: url)
        if let header = authorizationHeader() {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FrameStationClientError.http(
                status: (response as? HTTPURLResponse)?.statusCode ?? -1, reason: nil
            )
        }
        return data
    }
}
