#if os(iOS)
import FrameStationAnalysis
import FrameStationAPI
import FrameStationKit
import Foundation
import Observation

/// Works through this person's own library a thumbnail at a time, with Vision
/// on the phone, and sends what it recognized to their NAS.
///
/// Never in a hurry, and never in the way:
/// - only their own personal library;
/// - only on Wi-Fi, in Low Power Mode never, and not while the phone runs warm;
/// - only while the app is open (it stops when the app is backgrounded and
///   picks up where it left off next time, since the NAS keeps track of what
///   has been analyzed).
///
/// What leaves the phone is labels, scores and counts. The thumbnail is looked
/// at here and discarded. See ARCHITECTURE.md, "Curated albums".
///
/// Once that's caught up, and only for someone with People on, the photos the
/// NAS calls a birthday are read for the age written in them, a few at a time
/// (`readWriting`). Whole numbers leave the phone, never the writing.
///
/// Nothing about what a photo showed is logged. The diagnostics export gets
/// counts and durations only, because that file gets shared.
@Observable
@MainActor
final class CurationRunner {
    enum State: Equatable {
        case idle
        case analyzing
        /// Held back by something outside the app, said in words.
        case waiting(String)
        case finished
        case off
        /// This device's iOS predates the Vision requests the analyzer uses.
        case unsupported
    }

    private(set) var state: State = .idle
    private(set) var status: CurationStatus?

    private weak var session: AppSession?
    private let connection: ConnectionMonitor
    /// True while a backup is uploading, which outranks this: getting photos
    /// onto the NAS is the app's first job, and both lean on the same Wi-Fi and
    /// the same J4125.
    private let isBackingUp: @MainActor () -> Bool
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Photos per round trip: few enough that stopping halfway wastes little,
    /// enough that the round trips don't dominate.
    private static let batchSize = 24
    /// Thumbnails fetched at once while the previous ones are analyzed.
    private static let fetchLanes = 4
    /// Birthday photos read per round trip. Each is a full-screen copy, which
    /// the NAS may have to make first, so they go one at a time and few to a
    /// batch.
    private static let readingBatchSize = 8
    /// Held back before the first photo, so opening the app is about the grid
    /// someone came to look at, not about this.
    private static let settleDelay: Duration = .seconds(3)
    /// How often a held-back pass looks again while the app stays open.
    private static let recheckDelay: Duration = .seconds(30)
    /// How often a pass that has caught up looks for photos backup has added
    /// since: one small request, a few times an hour.
    private static let caughtUpDelay: Duration = .seconds(300)

    init(
        session: AppSession, connection: ConnectionMonitor,
        isBackingUp: @escaping @MainActor () -> Bool = { false }
    ) {
        self.session = session
        self.connection = connection
        self.isBackingUp = isBackingUp
    }

    /// Starts a pass unless one is running. Safe to call on every activation.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run()
            self?.task = nil
        }
    }

    /// Stops after the photo in hand. Nothing is lost: what was sent is kept,
    /// and the rest is still waiting next time.
    func stop() {
        task?.cancel()
        task = nil
        if state == .analyzing { state = .idle }
    }

    /// Settings and progress, re-read for the settings screen.
    func refreshStatus() async {
        guard let client = session?.client else { return }
        status = try? await client.curationStatus()
        if status?.settings.enabled == false {
            state = .off
        } else if state == .off {
            state = .idle
        }
    }

    /// Why a pass shouldn't run now, in words for the settings screen.
    private var holdBack: String? {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return "Waiting while Low Power Mode is on" }
        if info.thermalState == .serious || info.thermalState == .critical {
            return "Waiting for this device to cool down"
        }
        // The thumbnails are downloads. A whole library's worth is hundreds of
        // megabytes, and none of it is urgent.
        if connection.isMetered { return "Waiting for Wi-Fi" }
        if isBackingUp() { return "Waiting for backup to finish" }
        return nil
    }

    private func run() async {
        guard #available(iOS 18.0, *) else {
            state = .unsupported
            return
        }
        guard let session, let client = session.client, let space = session.personalSpace else {
            return
        }
        try? await Task.sleep(for: Self.settleDelay)
        guard !Task.isCancelled else { return }

        do {
            status = try await client.curationStatus()
        } catch {
            // A NAS that predates curation answers 404, and one that can't be
            // reached answers nothing. Either way there's nothing to do yet.
            state = .idle
            return
        }
        guard status?.settings.enabled == true else {
            state = .off
            return
        }

        let analyzer = PhotoAnalyzer()
        // Time spent fetching and analyzing, not waiting, so the figure in
        // the diagnostics log means something.
        var busy: TimeInterval = 0
        var sent = 0
        var reading: TimeInterval = 0
        var read = 0
        pass: while !Task.isCancelled {
            // Looked at again while the app stays open, so a backup finishing
            // or the phone cooling down picks this up without anyone having to
            // leave and come back. Backgrounding cancels the wait.
            if let reason = holdBack {
                state = .waiting(reason)
                try? await Task.sleep(for: Self.recheckDelay)
                continue
            }
            let page: PendingAnalysisResponse
            do {
                page = try await client.pendingAnalysis(
                    spaceID: space.id,
                    analysisVersion: PhotoAnalyzer.analysisVersion,
                    limit: Self.batchSize
                )
            } catch {
                state = .waiting("Can't reach your NAS")
                break
            }
            // Caught up. Then the birthday photos' writing, a batch at a time,
            // with the library looked at again between batches in case backup
            // has added photos. Photos keep arriving while the app is open, so
            // once both are done, look again now and then rather than stopping.
            guard !page.items.isEmpty else {
                let started = Date()
                switch await readWriting(spaceID: space.id, client: client, analyzer: analyzer) {
                case .read(let count):
                    read += count
                    reading += Date().timeIntervalSince(started)
                case .caughtUp:
                    state = .finished
                    try? await Task.sleep(for: Self.caughtUpDelay)
                case .stopped:
                    break
                case .unreachable:
                    state = .waiting("Can't reach your NAS")
                    break pass
                }
                continue
            }
            state = .analyzing
            let batchStarted = Date()

            guard let thumbnails = await fetchThumbnails(page.items, client: client) else {
                state = .waiting("Can't reach your NAS")
                break
            }
            var observations: [AssetObservation] = []
            for item in page.items {
                if Task.isCancelled { break pass }
                // Something came up mid-batch. The rest of it is offered again,
                // so drop it and wait at the top like any other hold.
                if holdBack != nil { continue pass }
                // A photo with no thumbnail to read, or one Vision can't read,
                // is reported as showing nothing so it isn't offered forever.
                // Never sent anywhere else to be read instead.
                var seen = PhotoAnalyzer.Observation.nothing
                if let data = thumbnails[item.assetID] {
                    seen = (try? await Task.detached(priority: .utility) {
                        try await analyzer.analyze(imageData: data)
                    }.value) ?? .nothing
                }
                observations.append(AssetObservation(
                    assetID: item.assetID,
                    labels: seen.labels.map { ObservedLabel(id: $0.id, confidence: $0.confidence) },
                    aesthetic: seen.aesthetic,
                    isUtility: seen.isUtility,
                    peopleCount: seen.peopleCount,
                    animalCount: seen.animalCount
                ))
            }
            guard !observations.isEmpty else { break }

            do {
                let response = try await client.submitObservations(
                    spaceID: space.id,
                    SubmitObservationsRequest(
                        analysisVersion: PhotoAnalyzer.analysisVersion,
                        modelVersion: PhotoAnalyzer.modelVersion,
                        observations: observations
                    )
                )
                sent += response.accepted
                busy += Date().timeIntervalSince(batchStarted)
                if let current = status {
                    status = CurationStatus(
                        settings: current.settings,
                        analyzed: min(current.total, current.analyzed + response.accepted),
                        total: current.total
                    )
                }
                // Nothing kept means curation was turned off on another device
                // since this pass began, or nothing here was new. Either way,
                // asking again would only get the same photos back.
                if response.accepted == 0 { break }
            } catch {
                state = .waiting("Can't reach your NAS")
                break
            }
        }

        if state == .analyzing { state = .idle }
        if sent > 0 {
            Diagnostics.shared.log(
                .measurement,
                "Curation: analyzed \(sent) photos in \(Int(busy.rounded())) s"
                    + " (\(Int((busy / Double(sent) * 1000).rounded())) ms each)"
            )
        }
        // A count and a duration. Never what any photo said.
        if read > 0 {
            Diagnostics.shared.log(
                .measurement,
                "Curation: read the writing in \(read) photos in \(Int(reading.rounded())) s"
            )
        }
    }

    private enum Reading {
        /// Read this many and sent them.
        case read(Int)
        /// Nothing left to read, or a NAS from before reading.
        case caughtUp
        /// Stopped, or held back, mid-batch. The batch is offered again.
        case stopped
        case unreachable
    }

    /// One batch of the photos the NAS calls a birthday, read for the age
    /// written in them (`PhotoAnalyzer.readNumbers`), and the numbers sent.
    ///
    /// Each is read from its full-screen copy, since a thumbnail is too small
    /// for a lone "2" candle, one at a time. The NAS lists none for someone
    /// without People. A photo gone since it was listed is sent as saying
    /// nothing; one the NAS can't make a copy of just now, as while it
    /// restarts, waits for a later batch. Never sent anywhere else to be read
    /// instead.
    @available(iOS 18.0, *)
    private func readWriting(
        spaceID: UUID, client: FrameStationClient, analyzer: PhotoAnalyzer
    ) async -> Reading {
        let page: PendingAnalysisResponse?
        do {
            page = try await client.pendingWriting(
                spaceID: spaceID, readingVersion: PhotoAnalyzer.readingVersion,
                limit: Self.readingBatchSize
            )
        } catch {
            return .unreachable
        }
        guard let page, !page.items.isEmpty else { return .caughtUp }
        state = .analyzing

        var photos: [WrittenNumbers] = []
        for item in page.items {
            if Task.isCancelled || holdBack != nil { return .stopped }
            let data: Data
            do {
                data = try await client.previewData(assetID: item.assetID)
            } catch FrameStationClientError.http(status: let status, reason: _) where status == 404 || status == 410 {
                photos.append(WrittenNumbers(assetID: item.assetID, numbers: []))
                continue
            } catch FrameStationClientError.http(status: _, reason: _) {
                continue
            } catch {
                return .unreachable
            }
            let numbers = (try? await Task.detached(priority: .utility) {
                try await analyzer.readNumbers(imageData: data)
            }.value) ?? []
            photos.append(WrittenNumbers(assetID: item.assetID, numbers: numbers))
        }
        guard !photos.isEmpty else { return .caughtUp }

        do {
            let response = try await client.submitWriting(
                spaceID: spaceID,
                SubmitWrittenNumbersRequest(readingVersion: PhotoAnalyzer.readingVersion, photos: photos)
            )
            // Nothing kept means People or curation went off since the list
            // was made: asking again would only get the same photos back.
            return response.accepted == 0 ? .caughtUp : .read(response.accepted)
        } catch {
            return .unreachable
        }
    }

    /// The batch's thumbnails, a few at a time. A thumbnail the NAS no longer
    /// has is simply missing from the answer. Nil when the NAS couldn't be
    /// reached at all, which ends the pass rather than reporting a batch of
    /// photos as showing nothing.
    private func fetchThumbnails(
        _ items: [PendingAnalysisItem], client: FrameStationClient
    ) async -> [UUID: Data]? {
        await withTaskGroup(of: (UUID, Data?, Bool).self) { group in
            var results: [UUID: Data] = [:]
            var unreachable = false
            var next = items.makeIterator()
            func add(_ item: PendingAnalysisItem) {
                group.addTask {
                    do {
                        let data = try await client.thumbnailData(
                            assetID: item.assetID, size: 512, version: item.thumbVersion
                        )
                        return (item.assetID, data, false)
                    } catch FrameStationClientError.http(status: let status, reason: _)
                        where status == 404 || status == 410 {
                        return (item.assetID, nil, false)
                    } catch {
                        return (item.assetID, nil, true)
                    }
                }
            }
            for _ in 0..<Self.fetchLanes {
                if let item = next.next() { add(item) }
            }
            while let (id, data, failed) = await group.next() {
                if let data { results[id] = data }
                if failed { unreachable = true }
                if !unreachable, let item = next.next() { add(item) }
            }
            return unreachable ? nil : results
        }
    }
}
#endif
