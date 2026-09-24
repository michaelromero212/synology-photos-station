import Foundation

/// The backup ledger's keys: one for every file backup sends from the phone.
///
/// A photo on the phone is one `PHAsset`, but backup can send it as several
/// files — the photo itself, a Live Photo's video half, and each edit someone
/// makes to it after it has been backed up, which arrives on the NAS as a new
/// photo beside the one already there rather than replacing it. The ledger keys
/// every row on a unique string, so each of those needs a key of its own that
/// still leads back to the one photo on the phone.
///
/// A PhotoKit identifier is a UUID with a `/Lnn/nnn` suffix, so `#` cannot occur
/// in one, and anything after it can never collide with a real photo.
public enum BackupKey {
    public enum Kind: Equatable, Sendable {
        /// The photo itself, as it looked when it went up.
        case main
        /// A Live Photo's video half. Hidden in the timeline; played with the
        /// still it belongs to.
        case pairedVideo
        /// One edit made after the photo went up.
        case edit
    }

    static let pairedVideoMark = "#pairedVideo"
    static let editMark = "#edit@"

    public static func pairedVideo(of photo: String) -> String {
        photo + pairedVideoMark
    }

    /// Keyed on when the edit was made, so editing again is a new key — and a
    /// new photo on the NAS — while finding the same edit again is the same key
    /// and nothing new.
    ///
    /// Whole seconds: the ledger has to recognize the key it made last time, and
    /// a `Date` round-tripped through anything loses sub-second precision.
    public static func edit(of photo: String, editedAt: Date) -> String {
        photo + editMark + String(Int64(editedAt.timeIntervalSince1970))
    }

    /// The PhotoKit identifier behind a key — the only thing Photos can find a
    /// photo by. Fetching by the whole key finds nothing.
    public static func photo(_ key: String) -> String {
        guard let mark = key.firstIndex(of: "#") else { return key }
        return String(key[..<mark])
    }

    public static func kind(_ key: String) -> Kind {
        if key.hasSuffix(pairedVideoMark) { return .pairedVideo }
        if key.contains(editMark) { return .edit }
        return .main
    }

    /// What an edit made after the photo went up is called on the NAS.
    ///
    /// Apple's own name for an edited export — `IMG_1234` becomes `IMG_E1234`,
    /// which is what Image Capture writes and what anyone who has pulled photos
    /// off an iPhone will recognize in File Station. A name not in Apple's shape
    /// gets `_E` on the end instead.
    ///
    /// Repeated edits share a name; the NAS tells same-named files apart itself.
    public static func editedFilename(original: String, renderExtension: String) -> String {
        let stem = (original as NSString).deletingPathExtension
        let edited = stem.hasPrefix("IMG_")
            ? "IMG_E" + stem.dropFirst("IMG_".count)
            : stem + "_E"
        return named(edited, like: original, renderExtension: renderExtension)
    }

    /// What a photo edited before it went up is called on the NAS: its own name.
    ///
    /// It is the only copy there, so it is the photo rather than a version of
    /// it. PhotoKit names every edited render the same thing whichever photo it
    /// belongs to, which is no name at all in File Station.
    public static func renderFilename(original: String, renderExtension: String) -> String {
        named(
            (original as NSString).deletingPathExtension,
            like: original, renderExtension: renderExtension
        )
    }

    /// `stem` with the render's own extension — an edited HEIC often renders to
    /// JPEG, and the name must not claim otherwise — in the original's case, so
    /// the files of one photo sit together.
    ///
    /// The same format under another spelling keeps the original's: PhotoKit
    /// calls a render `.jpeg` beside a camera's `.JPG`.
    private static func named(
        _ stem: String, like original: String, renderExtension: String
    ) -> String {
        let originalExtension = (original as NSString).pathExtension
        let lowered = renderExtension.lowercased()
        guard !lowered.isEmpty else { return stem }
        if format(lowered) == format(originalExtension.lowercased()) {
            return stem + "." + originalExtension
        }
        let isUpper = !originalExtension.isEmpty
            && originalExtension == originalExtension.uppercased()
        return stem + "." + (isUpper ? lowered.uppercased() : lowered)
    }

    private static func format(_ ext: String) -> String {
        switch ext {
        case "jpeg", "jpe": "jpg"
        case "tiff": "tif"
        default: ext
        }
    }
}
