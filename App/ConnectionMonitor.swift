import FrameStationKit
import Foundation
import Network
import Observation
import SwiftUI

/// Whether the app can reach the NAS right now, and why not when it can't.
///
/// Two different facts, deliberately not collapsed into one. "You have no
/// signal" and "your NAS isn't answering" call for different things from the
/// person reading the banner — one is wait, the other is go and look at the
/// box — and a single "offline" state would tell them neither.
///
/// Evidence, not polling. The state changes when a request the app was making
/// anyway fails, and `/health` is only asked while something is already known
/// to be wrong. A healthy app never sends a single extra request.
@Observable
@MainActor
final class ConnectionMonitor {
    enum State: Equatable {
        /// Requests are working, as far as anything knows.
        case online
        /// The device has no usable network path at all.
        case offline
        /// The network is fine and FrameStation isn't answering.
        case serverUnreachable
    }

    private(set) var state: State = .online

    /// Whether the current network path is metered — cellular or a personal
    /// hotspot, as opposed to Wi-Fi or wired. Drives the "Wi-Fi Only" backup
    /// setting: an unattended backup must not spend the user's cellular data.
    /// Defaults to false (assume Wi-Fi) so a probe that hasn't reported yet
    /// doesn't wrongly block; `NWPathMonitor` reports within milliseconds of
    /// starting.
    private(set) var isExpensive = false

    /// Called on the edge back to `.online`, so backup picks up where the
    /// outage stopped it rather than waiting for the next background window.
    var onReconnect: (@MainActor () async -> Void)?

    /// Read late rather than held: the client changes on sign-in and sign-out,
    /// and a captured one would go stale.
    private let client: @MainActor () -> FrameStationClient?

    private let path = NWPathMonitor()
    /// So a path update only gets logged when something actually changed.
    private var lastSatisfied: Bool?
    /// So a change of interface is logged even when the metered flag does not move.
    private var lastInterface: String?
    private var hasPath = true
    private var probe: Task<Void, Never>?
    /// The probe's own `/health` request goes through the same client the
    /// observer watches, so without this the probe would report its own result
    /// back to itself — cancelling the task it was reporting from. While a
    /// probe is in flight its result is the only one that counts.
    private var isProbing = false

    init(client: @escaping @MainActor () -> FrameStationClient?) {
        self.client = client
    }

    deinit { path.cancel() }

    func start() {
        path.pathUpdateHandler = { [weak self] update in
            let satisfied = update.status == .satisfied
            let expensive = update.isExpensive
            // Recorded because `isExpensive` was seen reporting *unmetered* on a
            // cellular-only connection, and it is not a cosmetic reading: backup
            // uses it to decide whether it may spend the user's data. The
            // interface NWPath says it is using settles whether the framework is
            // wrong or our reading of it is.
            let interface = update.usesInterfaceType(.wifi) ? "wifi"
                : update.usesInterfaceType(.cellular) ? "cellular"
                : update.usesInterfaceType(.wiredEthernet) ? "ethernet"
                : "other"
            let constrained = update.isConstrained
            Task { @MainActor [weak self] in
                // Strongify before touching properties. The optional-chained
                // writes this replaced (`self?.isExpensive = …`) are what Swift 6
                // flags as "reference to captured var 'self' in concurrently-
                // executing code"; unwrapping first is the pattern the
                // `observeOutcomes` hop below already uses.
                guard let self else { return }
                // Recorded because the app is meant to adapt when the network
                // changes underfoot — wi-fi to cellular on the way out of the
                // house, or a good connection going bad mid-clip — and the only
                // way to see whether it actually did is to have both the change
                // and what playback did next in one timeline.
                if self.isExpensive != expensive || self.lastSatisfied != satisfied
                    || self.lastInterface != interface {
                    Diagnostics.shared.log(
                        .network,
                        "Path now \(satisfied ? "up" : "down") on \(interface)"
                            + ", \(expensive ? "metered" : "unmetered")"
                            + (constrained ? ", low data mode" : "")
                    )
                }
                self.lastSatisfied = satisfied
                self.lastInterface = interface
                self.isExpensive = expensive
                self.pathChanged(satisfied: satisfied)
            }
        }
        path.start(queue: DispatchQueue(label: "com.michaelromero.FrameStation.path"))

        // Every request the app makes becomes evidence, not just uploads.
        // Browsing is the case that matters most here: with backup off, or
        // simply nothing to send, the grid failing to load is the only sign
        // the NAS is gone.
        guard let client = client() else { return }
        // Weak at the outermost hop rather than on the inner closure. The
        // observation closure is stored for the life of the client, so nothing
        // here may retain the monitor — and declaring it weak on the *inner*
        // closure while the enclosing Task held it strongly is what Swift 6.4
        // flags as `ImplicitStrongCapture`: the weak capture reads as protection
        // it was not actually providing at that level.
        Task { [weak self] in
            await client.observeOutcomes { failure in
                Task { @MainActor in
                    guard let self else { return }
                    if let failure { self.noteFailure(failure) } else { self.noteSuccess() }
                }
            }
        }
    }

    // MARK: - Reporting

    /// Anything that reached the server and got an answer.
    func noteSuccess() {
        guard !isProbing, state != .online else { return }
        recover()
    }

    /// Anything that didn't. Only `.unreachable` moves the banner — a request
    /// the server actively refused says nothing about whether it can be
    /// reached.
    func noteFailure(_ failure: TransferFailure) {
        guard failure == .unreachable, !isProbing else { return }
        guard state == .online else { return }

        // No path is not worth confirming: `NWPathMonitor` is authoritative
        // about the radio, and asking the network a question while the device
        // knows there is no network wastes a few seconds showing nothing.
        guard hasPath else {
            state = .offline
            beginProbing()
            return
        }

        // With a path, one failed request is not yet evidence of an outage —
        // it could be a single dropped connection. `/health` is cheap and
        // unauthenticated, so ask before showing anyone a red banner.
        probe?.cancel()
        probe = Task { [weak self] in
            guard let self else { return }
            if await self.isHealthy() { return }
            guard !Task.isCancelled else { return }
            self.state = .serverUnreachable
            await self.pollUntilHealthy()
        }
    }

    // MARK: - Path

    private func pathChanged(satisfied: Bool) {
        hasPath = satisfied
        if !satisfied {
            state = .offline
            probe?.cancel()
            probe = nil
            return
        }
        // A path coming back is not the same as the NAS being up — the phone
        // can rejoin Wi-Fi while the NAS is still rebooting. Confirm before
        // clearing.
        guard state != .online else { return }
        beginProbing()
    }

    // MARK: - Probing

    private func beginProbing() {
        probe?.cancel()
        probe = Task { [weak self] in
            await self?.pollUntilHealthy()
        }
    }

    /// Backs off to thirty seconds and stays there. The first few checks are
    /// close together because most outages are a NAS restart and clear in
    /// under a minute; after that, someone is fixing something and a slow
    /// heartbeat is enough.
    private func pollUntilHealthy() async {
        let delays: [UInt64] = [5, 10, 20, 30]
        var index = 0
        while !Task.isCancelled {
            let seconds = delays[min(index, delays.count - 1)]
            index += 1
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard hasPath else { continue }
            if await isHealthy() {
                guard !Task.isCancelled else { return }
                recover()
                return
            }
            // The path is up and the server still isn't answering, so this is
            // the NAS rather than the phone — correct the state if we arrived
            // here from `.offline`.
            if state == .offline { state = .serverUnreachable }
        }
    }

    private func isHealthy() async -> Bool {
        guard let client = client() else { return false }
        isProbing = true
        defer { isProbing = false }
        do {
            _ = try await client.health()
            return true
        } catch {
            // A server that answers "unauthorized" is a server that answered.
            // Only transport failures mean unreachable.
            return TransferFailure.classify(error) != .unreachable
        }
    }

    /// Idempotent: both the probe and an ordinary request that got through can
    /// arrive here, and `onReconnect` restarting backup twice would have two
    /// runs claiming the same queue.
    private func recover() {
        guard state != .online else { return }
        probe?.cancel()
        probe = nil
        state = .online
        if let onReconnect {
            Task { @MainActor in await onReconnect() }
        }
    }
}

extension ConnectionMonitor {
    /// Why a piece of media wouldn't load, in words rather than in Foundation's.
    ///
    /// The default was `error.localizedDescription`, which for a dropped
    /// connection is "The Internet connection appears to be offline." That is
    /// the wrong sentence in the most common case here: the phone has five
    /// bars, and the thing that is offline is a NAS in someone's basement.
    /// Saying so is the difference between "my phone is broken" and "the NAS
    /// is off."
    ///
    /// Deliberately no error codes. Synology's own answer to this is a modal
    /// alert reading `(-1009)`, which tells the person holding the phone
    /// nothing they can act on.
    static func mediaMessage(for error: (any Error)?, state: State?) -> String {
        switch state {
        case .offline:
            return "You're offline. This will play once you're back on a network."
        case .serverUnreachable:
            return "Your NAS isn't responding. This will play once it's back."
        case .online, nil:
            break
        }

        guard let error else { return "Something went wrong loading this." }
        switch TransferFailure.classify(error) {
        case .unreachable:
            // The monitor may not have caught up yet — a single failed request
            // is classified here before the banner has confirmed anything.
            return "Couldn't reach your NAS. Check that it's on, then try again."
        case .authentication:
            return "Sign in again to play this."
        case .itemFailed:
            return error.localizedDescription
        }
    }
}

/// Passed down rather than threaded through every view that draws a grid —
/// the same shape as `\.backupContainer`, and for the same reason.
private struct ConnectionMonitorKey: EnvironmentKey {
    static let defaultValue: ConnectionMonitor? = nil
}

extension EnvironmentValues {
    var connectionMonitor: ConnectionMonitor? {
        get { self[ConnectionMonitorKey.self] }
        set { self[ConnectionMonitorKey.self] = newValue }
    }
}
