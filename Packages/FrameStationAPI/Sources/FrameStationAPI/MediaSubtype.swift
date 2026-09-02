import Foundation

/// What kind of photograph or video this is, beyond photo-or-video.
///
/// These come from `PHAsset.mediaSubtypes`, which the device sets at capture.
/// The server used to infer them: a screenshot was "a PNG no camera took", a
/// panorama was "twice as wide as it is tall". Both guesses are wrong in both
/// directions — an image saved from a web page is a PNG no camera took, and a
/// panorama you cropped is no longer twice as wide — and neither could see a
/// screen recording at all, because the predicate only looked at photos.
///
/// The device is not guessing. It has known since the moment of capture, and
/// the scanner was already reading this exact property to find Live Photos.
///
/// Stored as strings rather than Apple's bitmask so the database does not
/// depend on the numeric values of a UIKit enum, and so a subtype added later
/// is a new case rather than a migration.
public enum MediaSubtype: String, Codable, Sendable, Hashable, CaseIterable {
    case screenshot
    case screenRecording
    case panorama
    case slomo
    case timelapse
    case portrait
    case cinematic

    /// The album title for this subtype.
    public var title: String {
        switch self {
        case .screenshot: return "Screenshots"
        case .screenRecording: return "Screen Recordings"
        case .panorama: return "Panoramas"
        case .slomo: return "Slo-mo"
        case .timelapse: return "Time-lapse"
        case .portrait: return "Portrait"
        case .cinematic: return "Cinematic"
        }
    }
}
