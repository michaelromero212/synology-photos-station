#if os(iOS)
import FrameStationAPI
import FrameStationKit
import Foundation
import Photos

/// What the app and its background upload extension share.
///
/// iOS runs the extension in a process of its own, with a container of its
/// own, so everything both need goes through the app group:
///
/// - the sign-in, copied into the group's keychain (`credentials`);
/// - what backup covers, as the app's settings say (`Setup`);
/// - the extension's record of what it has sent (`Progress`), which the app
///   reads back so it doesn't send those photos again.
///
/// Compiled into both targets, along with `PhotoLibraryScanner` and
/// `UploadDescriptor`, so the extension picks the same files and says the same
/// things about them that the app's own backup does. See
/// `BackgroundUploadExtension` and `BackgroundUploads`.
enum BackgroundUploadShared {
    /// The app group, from the bundle's `FSAppGroup`: one for the App Store
    /// build and one for the debug build, so the two never read each other's.
    static var appGroup: String? {
        (Bundle.main.object(forInfoDictionaryKey: "FSAppGroup") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    static var container: URL? {
        appGroup.flatMap {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
    }

    /// The address iOS lets the extension upload to.
    ///
    /// iOS checks every upload's destination against the extension's
    /// `BackgroundUploadURLBase`, which is fixed when the app is built. The app
    /// carries the same address as `FSBackgroundUploadURLBase`, to check it
    /// against the one it's signed in to. Both come from `BACKGROUND_UPLOAD_HOST`
    /// in `Config/Local.xcconfig`, kept out of the public repo. Nil when this
    /// build wasn't given one.
    static var uploadBase: URL? {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "BackgroundUploadURLBase") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "FSBackgroundUploadURLBase") as? String)
        guard let raw, let url = URL(string: raw), let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// The upload endpoint under the address. See `BackgroundUploadController`
    /// on the server.
    static func destination(base: URL) -> URL {
        base.appendingPathComponent("v1/uploads/background")
    }

    /// The sign-in, copied into the group's keychain for the extension. The
    /// app's own copy stays where it always was.
    static var credentials: CredentialStore? {
        appGroup.map { CredentialStore(account: "background-upload", accessGroup: $0) }
    }

    // MARK: - Setup

    /// What backup covers, as the app's settings say. Written by the app
    /// whenever they change, read by the extension each time it runs.
    struct Setup: Codable, Equatable {
        /// The person's own library: backup never sends anywhere else.
        var spaceID: UUID
        var includeVideos: Bool
        /// `BackupRule`'s raw value.
        var rule: String
        var cutoff: Date?

        var scope: BackupScope {
            BackupScope(
                includeVideos: includeVideos,
                rule: BackupRule(rawValue: rule) ?? .resume,
                cutoff: cutoff
            )
        }
    }

    static func loadSetup() -> Setup? {
        guard let url = file("setup.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? FrameStationCoding.decoder.decode(Setup.self, from: data)
    }

    static func saveSetup(_ setup: Setup) {
        guard let url = file("setup.json"),
              let data = try? FrameStationCoding.encoder.encode(setup) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clearSetup() {
        guard let url = file("setup.json") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Progress

    /// The extension's record of where it has got to.
    struct Progress: Codable {
        /// How far through the library's history of changes has been dealt
        /// with, as an archived `PHPersistentChangeToken`. The extension sends
        /// photos added after it; the app moves it forward whenever it has
        /// looked at the library itself, so the extension only ever sends
        /// photos the app hasn't seen.
        var mark: Data?
        /// Jobs made and not yet finished, by the job's local identifier.
        var jobs: [String: Job] = [:]
        /// What finished, for the app to take into its ledger.
        var results: [Result] = []
        /// Every file a job has been made for, and when, so a photo is never
        /// sent twice even after the app has taken in its result. Kept for a
        /// month.
        var handled: [String: Date] = [:]
    }

    /// One file iOS is sending.
    struct Job: Codable {
        /// The backup ledger's key: the photo's identifier, or its Live
        /// Photo's video half. See `BackupKey`.
        let key: String
        /// Shared by a Live Photo's two halves, so the app can pair a half
        /// that failed with the one that went.
        let liveGroupID: UUID?
        /// Which version of the photo this file shows. See
        /// `BackupItem.sentVersion`.
        let version: String?
        let createdAt: Date
    }

    /// One file iOS has finished with.
    struct Result: Codable {
        let key: String
        let assetID: UUID?
        /// `BackgroundUploadResult`'s raw value, or `failed`.
        let outcome: String
        let liveGroupID: UUID?
        let version: String?
        let finishedAt: Date

        var succeeded: Bool {
            outcome == BackgroundUploadResult.stored.rawValue
                || outcome == BackgroundUploadResult.have.rawValue
        }
    }

    static func readProgress() -> Progress {
        guard let url = file("progress.json") else { return Progress() }
        var progress = Progress()
        coordinate(url, writing: false) { url in
            if let data = try? Data(contentsOf: url),
               let stored = try? FrameStationCoding.decoder.decode(Progress.self, from: data) {
                progress = stored
            }
        }
        return progress
    }

    /// Reads the progress, changes it and writes it back, with the other
    /// process kept out meanwhile: the app and the extension can both be
    /// running.
    @discardableResult
    static func updateProgress<T>(_ change: (inout Progress) -> T) -> T? {
        guard let url = file("progress.json") else { return nil }
        var answer: T?
        coordinate(url, writing: true) { url in
            var progress = Progress()
            if let data = try? Data(contentsOf: url),
               let stored = try? FrameStationCoding.decoder.decode(Progress.self, from: data) {
                progress = stored
            }
            answer = change(&progress)
            let month = Date().addingTimeInterval(-30 * 86_400)
            progress.handled = progress.handled.filter { $0.value > month }
            if let data = try? FrameStationCoding.encoder.encode(progress) {
                try? data.write(to: url, options: .atomic)
            }
        }
        return answer
    }

    // MARK: - Marks

    static func archive(_ token: PHPersistentChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    static func token(from data: Data) -> PHPersistentChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
    }

    // MARK: - Files

    private static func file(_ name: String) -> URL? {
        container?.appendingPathComponent(name)
    }

    private static func coordinate(_ url: URL, writing: Bool, _ body: (URL) -> Void) {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?
        if writing {
            coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &error, byAccessor: body)
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &error, byAccessor: body)
        }
    }
}
#endif
