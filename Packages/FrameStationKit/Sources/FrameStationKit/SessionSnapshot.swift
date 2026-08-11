import FrameStationAPI
import Foundation

/// Who you are and which spaces you're in, remembered between launches.
///
/// The Keychain already holds the token, so the app knows perfectly well that
/// someone is signed in. What it could not do without this is *render* — the
/// tab bar needs a space list, and that only ever came from `/v1/me`. So one
/// unreachable NAS at launch put a signed-in family member back on the sign-in
/// screen, being asked for a password they already gave, with their library
/// sitting on disk the whole time.
///
/// This is the difference between an app that is offline and an app that looks
/// signed out.
public enum SessionSnapshotStore {
    private static var file: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        let directory = base.appendingPathComponent("FrameStation", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("session.json")
    }

    public static func save(_ me: MeResponse) {
        guard let file, let data = try? FrameStationCoding.encoder.encode(me) else { return }
        try? data.write(to: file, options: .atomic)
        // Names and space names — not something to sync into iCloud on our own
        // initiative when the account it belongs to is already stored properly.
        var url = file
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    public static func load() -> MeResponse? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? FrameStationCoding.decoder.decode(MeResponse.self, from: data)
    }

    public static func clear() {
        guard let file else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
