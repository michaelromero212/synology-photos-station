import Foundation

// MARK: - On-device analysis
//
// What a person's own devices saw in their photographs, sent to their own NAS
// and nowhere else. Devices report Vision's labels as Vision names them. What
// any of it *means* (a birthday, a beach day, evidence of Christmas) is decided
// on the server, so tuning it never needs an app update or a second pass over
// the library. See ARCHITECTURE.md, "Curated albums".

/// One thing Vision recognized, in its own words.
public struct ObservedLabel: Codable, Sendable, Hashable {
    /// Vision's identifier, such as `"birthday_cake"` or `"beach"`.
    public let id: String
    public let confidence: Float

    public init(id: String, confidence: Float) {
        self.id = id
        self.confidence = confidence
    }
}

/// What one photograph looked like to the device that analyzed it.
public struct AssetObservation: Codable, Sendable, Hashable {
    public let assetID: UUID
    /// Strongest first, and only the ones worth keeping.
    public let labels: [ObservedLabel]
    /// Vision's overall aesthetic score, from -1 to 1.
    public let aesthetic: Float?
    /// Screenshots, receipts, documents: kept for what they say rather than
    /// how they look, and never evidence of an occasion.
    public let isUtility: Bool
    /// How many people are in frame. A count, never who.
    public let peopleCount: Int
    public let animalCount: Int

    public init(
        assetID: UUID, labels: [ObservedLabel], aesthetic: Float?,
        isUtility: Bool, peopleCount: Int, animalCount: Int
    ) {
        self.assetID = assetID
        self.labels = labels
        self.aesthetic = aesthetic
        self.isUtility = isUtility
        self.peopleCount = peopleCount
        self.animalCount = animalCount
    }
}

public struct SubmitObservationsRequest: Codable, Sendable, Hashable {
    /// Which version of the analysis produced these. A newer version replaces
    /// an older one; the same version never replaces itself, so a second
    /// device analyzing the same photo changes nothing.
    public let analysisVersion: Int
    /// The Vision revisions behind them, kept for the record.
    public let modelVersion: String
    public let observations: [AssetObservation]

    public init(analysisVersion: Int, modelVersion: String, observations: [AssetObservation]) {
        self.analysisVersion = analysisVersion
        self.modelVersion = modelVersion
        self.observations = observations
    }
}

public struct SubmitObservationsResponse: Codable, Sendable, Hashable {
    /// How many were stored. Photos the caller can't see, and ones already
    /// analyzed at this version, aren't counted.
    public let accepted: Int

    public init(accepted: Int) {
        self.accepted = accepted
    }
}

/// A photograph waiting to be analyzed: enough to fetch its thumbnail.
public struct PendingAnalysisItem: Codable, Sendable, Hashable {
    public let assetID: UUID
    public let thumbVersion: Int

    public init(assetID: UUID, thumbVersion: Int) {
        self.assetID = assetID
        self.thumbVersion = thumbVersion
    }
}

public struct PendingAnalysisResponse: Codable, Sendable, Hashable {
    /// Newest first.
    public let items: [PendingAnalysisItem]
    /// Everything still waiting, these included.
    public let remaining: Int

    public init(items: [PendingAnalysisItem], remaining: Int) {
        self.items = items
        self.remaining = remaining
    }
}

/// A person's curation settings, held on the server so every one of their
/// devices follows them.
public struct CurationSettings: Codable, Sendable, Hashable {
    /// Whether their devices analyze their photos and the Albums page uses
    /// what was found.
    public let enabled: Bool
    /// Whether holidays get albums of their own, in any library they see.
    public let holidays: Bool

    public init(enabled: Bool, holidays: Bool) {
        self.enabled = enabled
        self.holidays = holidays
    }
}

/// Changes only what it names.
public struct UpdateCurationSettingsRequest: Codable, Sendable, Hashable {
    public let enabled: Bool?
    public let holidays: Bool?
    /// Preview the Albums page built from the NAS's analysis. Only for a
    /// person the NAS analyzes; a server from before ignores it.
    public let nasPreview: Bool?
    /// People on or off, for a person the NAS analyzes. Off deletes their
    /// people, names and face templates; on has the NAS read their library
    /// for faces again. A server from before ignores it.
    public let people: Bool?

    public init(enabled: Bool? = nil, holidays: Bool? = nil, nasPreview: Bool? = nil, people: Bool? = nil) {
        self.enabled = enabled
        self.holidays = holidays
        self.nasPreview = nasPreview
        self.people = people
    }
}

/// How far the NAS's own analysis of a person's library has got, for someone
/// it analyzes. See NAS-ANALYSIS.md.
public struct NASAnalysisStatus: Codable, Sendable, Hashable {
    /// "shadow" while it's being judged, "on" once the page uses it.
    public let state: String
    /// Files the NAS has analyzed and scored.
    public let analyzed: Int
    public let total: Int
    /// Whether the Albums page is currently built from it as a preview.
    public let preview: Bool
    /// Whether People is on: faces recognized and grouped. Nil from a server
    /// before the switch.
    public let people: Bool?

    public init(state: String, analyzed: Int, total: Int, preview: Bool, people: Bool? = nil) {
        self.state = state
        self.analyzed = analyzed
        self.total = total
        self.preview = preview
        self.people = people
    }
}

/// Where the analysis of a person's own library stands.
public struct CurationStatus: Codable, Sendable, Hashable {
    public let settings: CurationSettings
    public let analyzed: Int
    /// Everything that can be analyzed: photos, and videos by their poster
    /// frame, once the NAS has made a thumbnail.
    public let total: Int
    /// Present only for a person the NAS analyzes, from a server that does.
    public let nas: NASAnalysisStatus?

    public init(settings: CurationSettings, analyzed: Int, total: Int, nas: NASAnalysisStatus? = nil) {
        self.settings = settings
        self.analyzed = analyzed
        self.total = total
        self.nas = nas
    }
}

/// What the library knows about one photograph, for the Information panel.
public struct AssetObservationDetail: Codable, Sendable, Hashable {
    public let labels: [ObservedLabel]
    public let aesthetic: Float?
    public let isUtility: Bool
    public let peopleCount: Int
    public let animalCount: Int
    /// What the server made of it, such as `"birthday"` or `"christmas"`.
    public let tags: [String]

    public init(
        labels: [ObservedLabel], aesthetic: Float?, isUtility: Bool,
        peopleCount: Int, animalCount: Int, tags: [String]
    ) {
        self.labels = labels
        self.aesthetic = aesthetic
        self.isUtility = isUtility
        self.peopleCount = peopleCount
        self.animalCount = animalCount
        self.tags = tags
    }
}

/// What the NAS itself saw in one photo or video, for the Information panel:
/// labels in the same words as the device's, and what the server made of
/// them. Never anything about who is in it.
public struct NASObservationDetail: Codable, Sendable, Hashable {
    public let labels: [ObservedLabel]
    public let tags: [String]
    /// Faces in the frame with the most. A count only.
    public let peopleCount: Int
    /// 1 for a photo; the keyframes sampled from a video.
    public let frames: Int

    public init(labels: [ObservedLabel], tags: [String], peopleCount: Int, frames: Int) {
        self.labels = labels
        self.tags = tags
        self.peopleCount = peopleCount
        self.frames = frames
    }
}
