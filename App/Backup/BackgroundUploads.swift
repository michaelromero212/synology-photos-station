#if os(iOS)
import FrameStationAPI
import FrameStationKit
import Foundation
import Photos
import SwiftData

/// The app's half of backing up while it's closed. See
/// `BackgroundUploadExtension` for the other half.
///
/// On only when backup is, against a NAS that takes background uploads, at the
/// address this build declared to iOS, and never under "Only While Charging":
/// iOS has no way to hold these jobs for a charger, and the overnight window
/// the backup has always used already does. "Wi-Fi Only" goes to iOS as
/// `preventsExpensiveNetworkAccess`, so iOS itself keeps the uploads off
/// cellular.
///
/// iOS 27 and later. Earlier systems back up as they always have.
@MainActor
enum BackgroundUploads {
    /// What `/health` said, by address, asked once per launch.
    private static var capable: [URL: Bool] = [:]

    /// Brings iOS's background uploads in line with backup's settings and the
    /// sign-in. Called when either changes, and at launch.
    static func sync(settings: BackupSettings, session: AppSession) async {
        guard #available(iOS 27, *) else { return }
        let library = PHPhotoLibrary.shared()

        if let reason = await reasonOff(settings: settings, session: session) {
            if library.uploadJobExtensionEnabled {
                do {
                    try library.disableUploadJobExtension()
                    Diagnostics.shared.log(.backup, "background uploads off: \(reason)")
                } catch {
                    Diagnostics.shared.log(.backup, "couldn't turn background uploads off: \(error)")
                }
            }
            return
        }

        guard let saved = CredentialStore().load(),
              let spaceID = settings.targetSpace(in: session.spaces)?.id,
              let shared = BackgroundUploadShared.credentials
        else { return }
        try? shared.save(saved)
        BackgroundUploadShared.saveSetup(.init(
            spaceID: spaceID, includeVideos: settings.includeVideos,
            rule: settings.rule.rawValue, cutoff: settings.futureCutoff
        ))

        let options = PHAssetResourceUploadJobOptions()
        options.preventsExpensiveNetworkAccess = settings.wifiOnly
        do {
            if library.uploadJobExtensionEnabled {
                if library.uploadJobExtensionOptions?.preventsExpensiveNetworkAccess != settings.wifiOnly {
                    try library.setUploadJobExtensionOptions(options)
                }
            } else {
                // From now on. What's on the phone already is the app's own
                // backup to send, and it is sending it.
                let now = BackgroundUploadShared.archive(library.currentChangeToken)
                BackgroundUploadShared.updateProgress {
                    $0.mark = now
                    $0.jobs = [:]
                }
                try library.enableUploadJobExtension(with: options)
                Diagnostics.shared.log(.backup, "background uploads on")
            }
        } catch {
            Diagnostics.shared.log(.backup, "couldn't turn background uploads on: \(error)")
        }
    }

    /// Why background uploads should be off, or nil when they should be on.
    private static func reasonOff(settings: BackupSettings, session: AppSession) async -> String? {
        guard settings.enabled else { return "backup is off" }
        guard !settings.chargingOnly else { return "only while charging" }
        guard PhotoLibraryScanner.access == .authorized else { return "no full access to Photos" }
        guard let client = session.client, settings.targetSpace(in: session.spaces) != nil
        else { return "not signed in" }
        guard let base = BackgroundUploadShared.uploadBase else {
            return "this build has no upload address (Config/Local.xcconfig)"
        }
        let server = await client.baseURL
        guard base.scheme == server.scheme, base.host == server.host, base.port == server.port else {
            return "signed in at an address other than the one this build declared"
        }
        if capable[server] == nil {
            capable[server] = (try? await client.health())?.capabilities?
                .contains(BackgroundUploadRequest.capability)
        }
        guard capable[server] == true else { return "the NAS doesn't take them yet" }
        return nil
    }

    /// Turns background uploads off and forgets the sign-in copied for them,
    /// for an account signing out.
    static func signedOut() {
        if #available(iOS 27, *), PHPhotoLibrary.shared().uploadJobExtensionEnabled {
            try? PHPhotoLibrary.shared().disableUploadJobExtension()
        }
        BackgroundUploadShared.credentials?.clear()
        BackgroundUploadShared.clearSetup()
        BackgroundUploadShared.updateProgress { $0 = .init() }
        capable = [:]
    }

    /// The app has read the library's changes up to `mark`, so the extension
    /// needn't send anything before it.
    static func caughtUp(to mark: Data) {
        BackgroundUploadShared.updateProgress { $0.mark = mark }
    }

    // MARK: - Results

    /// Takes in what the extension sent: each photo's rows are marked done,
    /// so the backup doesn't read and hash them only to learn the NAS has
    /// them.
    ///
    /// Both halves of a Live Photo get a row, whichever of them went, with the
    /// group id the extension sent them under. A half that failed is queued
    /// under that id, so it still pairs with the half already on the NAS.
    /// Without its row it would never go at all: the backup sets aside any
    /// photo it already has a row for.
    static func absorb(into context: ModelContext) {
        guard let results = BackgroundUploadShared.updateProgress({ progress -> [BackgroundUploadShared.Result] in
            defer { progress.results = [] }
            return progress.results
        }), !results.isEmpty else { return }

        let byPhoto = Dictionary(grouping: results) { BackupKey.photo($0.key) }
        var taken = 0
        for (photo, finished) in byPhoto {
            guard let asset = PhotoLibraryScanner.asset(for: photo),
                  let candidate = PhotoLibraryScanner.describe(asset)
            else { continue }
            let liveGroupID = finished.lazy.compactMap(\.liveGroupID).first
            let keys = [photo] + (candidate.pairedVideo != nil && liveGroupID != nil
                ? [BackupKey.pairedVideo(of: photo)] : [])
            for key in keys {
                let result = finished.last { $0.key == key }
                let row = existingRow(key, in: context)
                    ?? newRow(key, asset: asset, candidate: candidate, liveGroupID: liveGroupID, in: context)
                guard let row else { continue }
                // Not one being sent right now: that upload finishes and says
                // the same.
                guard row.state != .uploading else { continue }
                if let result, result.succeeded {
                    row.state = .done
                    row.assetID = result.assetID ?? row.assetID
                    row.sentVersion = result.version ?? row.sentVersion
                    row.completedAt = result.finishedAt
                    row.lastError = nil
                    if let liveGroupID { row.liveGroupID = liveGroupID }
                    taken += 1
                } else if row.state != .done, let liveGroupID {
                    // Still to go, under the group its other half went with.
                    row.liveGroupID = liveGroupID
                }
            }
        }
        try? context.save()
        if taken > 0 {
            Diagnostics.shared.log(.backup, "took in \(taken) file(s) sent in the background")
        }
    }

    private static func existingRow(_ key: String, in context: ModelContext) -> BackupItem? {
        var descriptor = FetchDescriptor<BackupItem>(predicate: #Predicate { $0.localIdentifier == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// A row for a file the extension dealt with, described as the backup's
    /// own scan would have. Pending until a result says otherwise.
    private static func newRow(
        _ key: String, asset: PHAsset, candidate: PhotoLibraryScanner.Candidate,
        liveGroupID: UUID?, in context: ModelContext
    ) -> BackupItem? {
        let fallback = asset.creationDate.map { TimeZone.current.secondsFromGMT(for: $0) }
        let row: BackupItem
        if BackupKey.kind(key) == .pairedVideo {
            guard let video = candidate.pairedVideo else { return nil }
            row = BackupItem(
                localIdentifier: key, filename: video.filename, byteSize: video.byteSize,
                mediaType: MediaType.video.rawValue, mime: video.mime, width: 0, height: 0,
                capturedAt: asset.creationDate, capturedTZOffsetFallback: fallback,
                latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude,
                liveGroupID: liveGroupID
            )
        } else {
            row = BackupItem(
                localIdentifier: key, filename: candidate.filename, byteSize: candidate.byteSize,
                mediaType: candidate.mediaType.rawValue, mime: candidate.mime,
                width: asset.pixelWidth, height: asset.pixelHeight,
                durationMs: asset.duration > 0 ? Int(asset.duration * 1000) : nil,
                capturedAt: asset.creationDate, capturedTZOffsetFallback: fallback,
                latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude,
                isRaw: candidate.isRaw, burstID: asset.burstIdentifier,
                burstPick: asset.burstSelectionTypes.contains(.userPick)
                    || asset.burstSelectionTypes.contains(.autoPick),
                subtypes: candidate.subtypes, liveGroupID: liveGroupID
            )
        }
        context.insert(row)
        return row
    }

    // MARK: - Sending it ourselves

    /// Cancels iOS's job for a file the app is about to send itself, so the
    /// photo goes up once. Only a job iOS hasn't finished: one that has
    /// finished is in `absorb`'s hands.
    static func cancelJob(forKey key: String) {
        guard #available(iOS 27, *) else { return }
        let jobs = BackgroundUploadShared.readProgress().jobs.filter { $0.value.key == key }
        guard !jobs.isEmpty else { return }
        let inFlight = PHAssetResourceUploadJob.fetchJobs(action: .process, options: nil)
        var canceling: [PHAssetResourceUploadJob] = []
        for index in 0..<inFlight.count {
            let job = inFlight.object(at: index)
            if jobs[job.localIdentifier] != nil { canceling.append(job) }
        }
        guard !canceling.isEmpty else { return }
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                for job in canceling { PHAssetResourceUploadJobChangeRequest(for: job)?.cancel() }
            }
            BackgroundUploadShared.updateProgress { progress in
                for job in canceling { progress.jobs[job.localIdentifier] = nil }
            }
        } catch {
            Diagnostics.shared.log(.backup, "couldn't cancel a background upload: \(error)")
        }
    }
}
#endif
