import ExtensionFoundation
import FrameStationAPI
import FrameStationKit
import Foundation
import os
import Photos
import Synchronization

/// Backs up new photos while FrameStation is closed.
///
/// A closed app can't watch the photo library, so the app's own backup only
/// noticed a new photo when something woke it: iOS's occasional background
/// window, usually overnight on a charger, or the app being opened. Synology
/// Photos had the same photos on the NAS within minutes. This is how: PhotoKit
/// runs this extension when the library gains photos and conditions allow, and
/// iOS itself sends the files it hands over, closed app or not.
///
/// Each run settles what finished (recording it for the app), makes jobs for
/// the photos added since the mark, and moves the mark past them. The files
/// are the ones the app would send, described the same way: the same scanner
/// and descriptor, compiled into both. iOS asks for each job's destination up
/// front, so what the server needs to know about a photo travels with it in a
/// header. See `BackgroundUploadController` on the server.
///
/// Only photos the app hasn't seen. The app moves the mark forward whenever it
/// looks at the library itself, and it takes in what this sent, so neither
/// sends a photo the other already has. When both do anyway, which can happen
/// when a photo is taken with the app open, the NAS keeps one copy.
@main
final class BackgroundUploadExtension: PHBackgroundResourceUploadJobExtension {
    private let stopping = Atomic<Bool>(false)
    private let logger = Logger(subsystem: "com.michaelromero.FrameStation", category: "background-upload")

    required init() {}

    func processJobs() async -> PHBackgroundResourceUploadProcessingResult {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
              let setup = BackgroundUploadShared.loadSetup(),
              let credentials = BackgroundUploadShared.credentials?.load(),
              let base = BackgroundUploadShared.uploadBase
        else {
            logger.notice("not set up, so nothing to send")
            return .completed
        }
        do {
            try await retryFailed()
            try await settle()
            if stopping.load(ordering: .acquiring) { return .processing }
            let more = try await makeJobs(setup: setup, token: credentials.token, base: base)
            return more ? .processing : .completed
        } catch PHPhotosError.limitExceeded {
            // As many in flight as iOS holds. It calls again as they finish.
            return .processing
        } catch PHPhotosError.persistentChangeTokenExpired {
            // Photos has let go of its history past the mark, so start again
            // from now. What was added in between is the app's own catch-up
            // to find, the next time it runs.
            BackgroundUploadShared.updateProgress {
                $0.mark = BackgroundUploadShared.archive(PHPhotoLibrary.shared().currentChangeToken)
            }
            return .processing
        } catch {
            logger.error("background upload failed: \(error, privacy: .public)")
            return .failure
        }
    }

    func willTerminate() async {
        stopping.store(true, ordering: .releasing)
    }

    // MARK: - Finished jobs

    /// Sends again what failed on the way, once, as iOS allows. A file the
    /// server refused is left alone: sending it again would be refused again,
    /// and the app sends it its own way instead.
    private func retryFailed() async throws {
        let failed = PHAssetResourceUploadJob.fetchJobs(action: .retry, options: nil)
        var retrying: [PHAssetResourceUploadJob] = []
        for index in 0..<failed.count {
            let job = failed.object(at: index)
            if let error = job.error as? URLError,
               [.userAuthenticationRequired, .badServerResponse].contains(error.code) {
                continue
            }
            retrying.append(job)
        }
        guard !retrying.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            for job in retrying {
                PHAssetResourceUploadJobChangeRequest(for: job)?.retry(destination: nil)
            }
        }
    }

    /// Records what finished, for the app, then lets iOS forget it: a finished
    /// job keeps its place in the queue until it's acknowledged.
    private func settle() async throws {
        let finished = PHAssetResourceUploadJob.fetchJobs(action: .acknowledge, options: nil)
        guard finished.count > 0 else { return }
        var jobs: [PHAssetResourceUploadJob] = []
        for index in 0..<finished.count { jobs.append(finished.object(at: index)) }

        // Recorded first: once acknowledged, PhotoKit has nothing left to say
        // about a job.
        BackgroundUploadShared.updateProgress { progress in
            for job in jobs {
                let made = progress.jobs.removeValue(forKey: job.localIdentifier)
                guard let key = made?.key ?? Self.key(of: job) else { continue }
                let headers = job.responseHeaderFields ?? [:]
                let outcome = job.state == .succeeded
                    ? headers[BackgroundUploadRequest.resultHeader.lowercased()]
                        ?? BackgroundUploadResult.stored.rawValue
                    : "failed"
                progress.results.append(.init(
                    key: key,
                    assetID: headers[BackgroundUploadRequest.assetIDHeader.lowercased()]
                        .flatMap(UUID.init(uuidString:)),
                    outcome: outcome,
                    liveGroupID: made?.liveGroupID,
                    version: made?.version,
                    finishedAt: Date()
                ))
            }
        }
        for job in jobs where job.state == .failed {
            logger.notice("a background upload failed: \(String(describing: job.error), privacy: .public)")
        }
        try await PHPhotoLibrary.shared().performChanges {
            for job in jobs {
                PHAssetResourceUploadJobChangeRequest(for: job)?.acknowledge()
            }
        }
    }

    /// The ledger key of the file a job sent, for a job made before this
    /// extension kept records of its own.
    private static func key(of job: PHAssetResourceUploadJob) -> String? {
        guard let resource = PHAssetResource.assetResource(forUploadJob: job) else { return nil }
        let photo = resource.assetLocalIdentifier
        switch resource.type {
        case .pairedVideo, .fullSizePairedVideo: return BackupKey.pairedVideo(of: photo)
        default: return photo
        }
    }

    // MARK: - New photos

    /// Makes jobs for the photos added since the mark, and moves the mark past
    /// them. True when there's more to do than this run could make.
    ///
    /// The mark only moves once every photo after it has its jobs. A run cut
    /// short, by the job limit or by iOS, reads the same changes again next
    /// time, and `handled` keeps the photos it already made jobs for from
    /// being sent twice.
    private func makeJobs(setup: BackgroundUploadShared.Setup, token: String, base: URL) async throws -> Bool {
        let library = PHPhotoLibrary.shared()
        let progress = BackgroundUploadShared.readProgress()
        guard let saved = progress.mark, let mark = BackgroundUploadShared.token(from: saved) else {
            // No mark yet: the app sets one when it turns this on. Start from
            // now rather than send the whole library, which is the app's.
            BackgroundUploadShared.updateProgress {
                $0.mark = BackgroundUploadShared.archive(library.currentChangeToken)
            }
            return false
        }

        var added: [String] = []
        var latest: PHPersistentChangeToken?
        for change in try library.fetchPersistentChanges(since: mark) {
            added.append(contentsOf: try change.changeDetails(for: .asset).insertedLocalIdentifiers)
            latest = change.changeToken
        }
        guard let latest else { return false }

        let scope = setup.scope
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(Set(added)), options: nil)
        var assets: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in assets.append(asset) }
        // Oldest first, the order they were taken in.
        assets.sort { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }

        for asset in assets {
            if stopping.load(ordering: .acquiring) { return true }
            guard progress.handled[asset.localIdentifier] == nil,
                  PhotoLibraryScanner.isBackedUp(asset),
                  asset.mediaType == .image || asset.mediaType == .video,
                  scope.includes(isVideo: asset.mediaType == .video, takenAt: asset.creationDate)
            else { continue }
            try await makeJobs(for: asset, setup: setup, token: token, base: base)
        }
        BackgroundUploadShared.updateProgress { $0.mark = BackgroundUploadShared.archive(latest) }
        return false
    }

    /// The jobs for one photo: the file the app would send, and a Live
    /// Photo's motion with it, both carrying one group id.
    private func makeJobs(
        for asset: PHAsset, setup: BackgroundUploadShared.Setup, token: String, base: URL
    ) async throws {
        guard let candidate = PhotoLibraryScanner.describe(asset),
              let primary = PhotoLibraryScanner.primaryResource(for: asset)
        else { return }
        let motion = setup.includeVideos ? PhotoLibraryScanner.livePhotoResource(for: asset) : nil
        let liveGroupID = motion.map { _ in UUID() }

        var photo = UploadDescriptor(asset: asset, candidate: candidate)
        photo.liveGroupID = liveGroupID
        var files: [(key: String, resource: PHAssetResource, request: URLRequest, version: String?)] = [(
            asset.localIdentifier, primary,
            try request(photo, spaceID: setup.spaceID, token: token, base: base),
            PhotoLibraryScanner.versionKey(of: asset, sending: primary)
        )]
        if let motion, let video = candidate.pairedVideo {
            let key = BackupKey.pairedVideo(of: asset.localIdentifier)
            // As the app's backup describes the motion half: no size or
            // length of its own, which only the file knows, and the still's
            // moment and place, so the pair never lands on two different days.
            let half = UploadDescriptor(
                filename: video.filename, mime: video.mime, mediaType: .video,
                capturedAt: asset.creationDate,
                capturedTZOffsetFallback: asset.creationDate.map {
                    TimeZone.current.secondsFromGMT(for: $0)
                },
                latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude,
                liveGroupID: liveGroupID,
                sourceLocalID: key
            )
            files.append((key, motion, try request(half, spaceID: setup.spaceID, token: token, base: base), nil))
        }

        let made = Placeholders()
        try await PHPhotoLibrary.shared().performChanges {
            for file in files {
                let change = PHAssetResourceUploadJobChangeRequest.creationRequestForJob(
                    destination: file.request, resource: file.resource
                )
                if let id = change.placeholderForCreatedAssetResourceUploadJob?.localIdentifier {
                    made.add(id, .init(
                        key: file.key, liveGroupID: liveGroupID, version: file.version,
                        createdAt: Date()
                    ))
                }
            }
        }
        let jobs = made.jobs
        BackgroundUploadShared.updateProgress { progress in
            progress.jobs.merge(jobs) { _, new in new }
            progress.handled[asset.localIdentifier] = Date()
        }
        logger.info("queued \(files.count) file(s) for background upload")
    }

    /// Where iOS sends one file, and what the NAS should know about it.
    private func request(
        _ descriptor: UploadDescriptor, spaceID: UUID, token: String, base: URL
    ) throws -> URLRequest {
        var request = URLRequest(url: BackgroundUploadShared.destination(base: base))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        // No length: an edited photo's render can be a different size from
        // the one PhotoKit reports, and a mismatch would be refused.
        let header = BackgroundUploadRequest(
            filename: descriptor.filename, byteSize: nil, isAutomaticBackup: true,
            commit: descriptor.commitRequest(spaceID: spaceID)
        )
        request.setValue(try header.headerValue(), forHTTPHeaderField: BackgroundUploadRequest.header)
        return request
    }
}

/// The jobs a change block made, gathered from inside it.
private final class Placeholders: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [String: BackgroundUploadShared.Job] = [:]

    func add(_ id: String, _ job: BackgroundUploadShared.Job) {
        lock.lock()
        defer { lock.unlock() }
        made[id] = job
    }

    var jobs: [String: BackgroundUploadShared.Job] {
        lock.lock()
        defer { lock.unlock() }
        return made
    }
}
