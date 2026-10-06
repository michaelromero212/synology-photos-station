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
            // Caught up. Photos keep arriving from backup while the app is
            // open, so look again now and then rather than stopping.
            guard !page.items.isEmpty else {
                state = .finished
                try? await Task.sleep(for: Self.caughtUpDelay)
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
