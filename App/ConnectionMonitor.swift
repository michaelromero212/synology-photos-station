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
///
/// And enough evidence before saying so. One failed request and one failed
/// `/health` used to be the whole case, which is what a phone coming back from
/// the background or changing networks produces with the NAS fine: its first
/// requests die on connections that went stale, and the check sent straight
/// after them finds the network not yet settled. The banner went up and, five
/// seconds later, came down, too briefly to read. An outage now has to last:
/// three checks over five seconds, each unanswered, and no other request
/// getting through meanwhile.
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

    /// What the status pill over the tab bar says. See `ConnectionPill`.
    ///
    /// Follows `state`, with one addition: when the connection comes back after
    /// the pill has said it was gone, it says so for two seconds before it
    /// goes. A warning that simply vanishes leaves you wondering whether it was
    /// ever true, and whether it's safe to carry on.
    enum Notice: Equatable {
        case offline
        case unreachable
        case reconnected
    }

    private(set) var notice: Notice?

    /// While a Try Again is being answered.
    private(set) var isChecking = false

    /// Whether spending data on this path would spend the user's mobile
    /// allowance — cellular or a personal hotspot, as opposed to Wi-Fi or wired.
    /// Drives the "Wi-Fi Only" backup setting.
    ///
    /// **Two readings, OR'd, because neither is sufficient alone.**
    ///
    /// `isExpensive` is the obvious one and it cannot be trusted by itself: it
    /// was observed reporting *unmetered* on a cellular-only connection on this
    /// very device. Trusting it alone is what let an unattended backup send
    /// gigabytes of video over cellular with "Wi-Fi Only" switched on — the
    /// setting failed open, which for a backup app is a phone bill rather than a
    /// glitch.
    ///
    /// `usesInterfaceType(.cellular)` catches exactly that case, and cannot
    /// catch the other one: a personal hotspot is reached over the *Wi-Fi*
    /// interface and is only known to be costly because `isExpensive` says so.
    /// So each covers the other's blind spot, and the union is what the gate
    /// wants — the question is "would this spend mobile data", not "which radio
    /// is it".
    ///
    /// Defaults to false (assume Wi-Fi) so a path that hasn't reported yet
    /// doesn't wrongly block; `NWPathMonitor` reports within milliseconds of
    /// starting.
    private(set) var isMetered = false

    /// Whether the path has reported at all. Until it has, `isMetered` is only
    /// its default — the permissive answer — which is fine for anything already
    /// under way and not good enough to *start* a backup on.
    var hasReportedPath: Bool { lastSatisfied != nil }

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
    /// The checks that decide whether a failed request was an outage. See
    /// `confirmOutage`.
    private var confirmation: Task<Void, Never>?
    /// Holds off `.offline` for a moment. See `pathChanged`.
    private var pathLoss: Task<Void, Never>?
    /// Takes `.reconnected` down again.
    private var noticeTimer: Task<Void, Never>?
    /// When a request last got an answer, so a check can tell whether the NAS
    /// answered something else while it was waiting.
    private var lastSuccess: Date?
    /// The probe's own `/health` request goes through the same client the
    /// observer watches, so without this the probe would report its own result
    /// back to itself — canceling the task it was reporting from. While a
    /// probe is in flight its result is the only one that counts.
    ///
    /// A count, because the confirming checks and the reconnect poll can each
    /// have one out at once, and the first to finish mustn't speak for both.
    private var probesInFlight = 0
    private var isProbing: Bool { probesInFlight > 0 }

    init(client: @escaping @MainActor () -> FrameStationClient?) {
        self.client = client
    }

    deinit { path.cancel() }

    func start() {
        path.pathUpdateHandler = { [weak self] update in
            let satisfied = update.status == .satisfied
            let expensive = update.isExpensive
            let usesCellular = update.usesInterfaceType(.cellular)
            // See `isMetered`. The radio is believed over the flag, and the flag
            // is believed over nothing — either one saying it costs money is
            // enough to treat the path as costing money.
            let metered = usesCellular || expensive
            let interface = update.usesInterfaceType(.wifi) ? "wifi"
                : usesCellular ? "cellular"
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
                if self.isMetered != metered || self.lastSatisfied != satisfied
                    || self.lastInterface != interface {
                    Diagnostics.shared.log(
                        .network,
                        "Path now \(satisfied ? "up" : "down") on \(interface)"
                            + ", \(metered ? "metered" : "unmetered")"
                            // Kept visible when the two disagree, because that
                            // disagreement is the bug this guards against and it
                            // is otherwise invisible now that the radio wins.
                            + (usesCellular && !expensive ? " (isExpensive said unmetered)" : "")
                            + (constrained ? ", low data mode" : "")
                    )
                }
                self.lastSatisfied = satisfied
                self.lastInterface = interface
                self.isMetered = metered
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
        guard !isProbing else { return }
        lastSuccess = Date()
        // An answer while an outage was still being checked is the check's
        // answer too.
        confirmation?.cancel()
        confirmation = nil
        guard state != .online else { return }
        recover()
    }

    /// Anything that didn't. Only `.unreachable` moves the banner — a request
    /// the server actively refused says nothing about whether it can be
    /// reached.
    func noteFailure(_ failure: TransferFailure) {
        guard failure == .unreachable, !isProbing else { return }
        guard state == .online else { return }

        // No path is the path monitor's to report, and it does: see
        // `pathChanged`. Asking the network a question while the device knows
        // there is no network only spends a few seconds showing nothing.
        guard hasPath else { return }

        // With a path, one failed request is not yet evidence of an outage:
        // it could be one dropped connection, or a dozen dropped at once on
        // the way back from the background. The checks already running answer
        // for this failure as well.
        guard confirmation == nil else { return }
        let failedAt = Date()
        confirmation = Task { [weak self] in
            await self?.confirmOutage(since: failedAt)
        }
    }

    /// Seconds before each check. The first goes at once, which is all a
    /// single dropped connection needs; the last is five seconds in, past the
    /// time a phone takes to settle on a network it has just joined.
    private static let confirmationDelays: [Double] = [0, 2, 3]

    /// Decides whether a failed request at `failedAt` was the NAS going away.
    private func confirmOutage(since failedAt: Date) async {
        for delay in Self.confirmationDelays {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            // Gone altogether: the path monitor speaks for that.
            guard hasPath else { break }
            // The NAS answered something else in the meantime.
            if let lastSuccess, lastSuccess > failedAt { break }
            if await isHealthy() { break }
            guard !Task.isCancelled else { return }
            // All three unanswered, with a network to ask over: the NAS.
            if delay == Self.confirmationDelays.last, state == .online {
                set(.serverUnreachable)
                beginProbing()
            }
        }
        confirmation = nil
    }

    // MARK: - Path

    private func pathChanged(satisfied: Bool) {
        hasPath = satisfied
        if !satisfied {
            confirmation?.cancel()
            confirmation = nil
            probe?.cancel()
            probe = nil
            // A path that comes straight back isn't being offline: Wi-Fi
            // handing over to cellular on the way out of the house drops it
            // for a moment. Said only once it has stayed gone.
            guard state != .offline, pathLoss == nil else { return }
            pathLoss = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                self.pathLoss = nil
                guard !self.hasPath else { return }
                self.set(.offline)
            }
            return
        }
        pathLoss?.cancel()
        pathLoss = nil
        // A path coming back is not the same as the NAS being up — the phone
        // can rejoin Wi-Fi while the NAS is still rebooting. Confirm before
        // clearing.
        guard state != .online else { return }
        beginProbing()
    }

    // MARK: - Saying so

    /// Every change of state goes through here, so the pill can't fall out of
    /// step with it.
    private func set(_ new: State) {
        guard new != state else { return }
        state = new
        noticeTimer?.cancel()
        noticeTimer = nil
        switch new {
        case .offline:
            notice = .offline
        case .serverUnreachable:
            notice = .unreachable
        case .online:
            // Only a pill that warned of something has anything to take back.
            guard notice == .offline || notice == .unreachable else {
                notice = nil
                return
            }
            notice = .reconnected
            noticeTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.notice = nil
            }
        }
    }

    /// Checks now, for the Try Again on the pill, rather than whenever the
    /// backed-off poll next comes round: half a minute is a long time to wait
    /// after switching the NAS back on.
    func retryNow() {
        guard state != .online, !isChecking else { return }
        probe?.cancel()
        probe = Task { [weak self] in
            guard let self else { return }
            self.isChecking = true
            let started = Date()
            let healthy = self.hasPath ? await self.isHealthy() : false
            // Long enough to be seen to have tried: an answer back in forty
            // milliseconds flashed the spinner too briefly to register, and
            // the tap looked like it had done nothing.
            let shown = Date().timeIntervalSince(started)
            if shown < 0.6 { try? await Task.sleep(for: .seconds(0.6 - shown)) }
            self.isChecking = false
            guard !Task.isCancelled else { return }
            if healthy {
                self.recover()
            } else {
                await self.pollUntilHealthy()
            }
        }
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
            if state == .offline { set(.serverUnreachable) }
        }
    }

    /// Whether the NAS answers right now, for a caller deciding what one failed
    /// request meant. A dropped connection while the NAS answers is a reason to
    /// try again, not to stop; see `BackupEngine.drainLane`.
    func confirmReachable() async -> Bool {
        guard hasPath else { return false }
        return await isHealthy()
    }

    private func isHealthy() async -> Bool {
        guard let client = client() else { return false }
        probesInFlight += 1
        defer { probesInFlight -= 1 }
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
        set(.online)
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
        // The player wraps a dropped connection in an error of its own, which
        // reads as the video's fault. The network error underneath is the one
        // that says what happened.
        switch TransferFailure.classify(networkCause(of: error) ?? error) {
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

    /// The network error inside one of the player's own, if there is one.
    private static func networkCause(of error: any Error) -> URLError? {
        if let url = error as? URLError { return url }
        var cause = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        var depth = 0
        while let underlying = cause, depth < 3 {
            if underlying.domain == NSURLErrorDomain {
                return URLError(URLError.Code(rawValue: underlying.code))
            }
            cause = underlying.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return nil
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

#if os(iOS)
/// The connection's state, in one place on every tab: a pill just above the
/// tab bar, where the app's other passing word goes (`GridToast`).
///
/// It replaces a banner that floated over the Photos grid alone, on a fill so
/// faint over photographs that it couldn't be read, and that came and went in
/// a few seconds because it went up on too little evidence (see
/// `ConnectionMonitor`). Here it sits on glass, on whichever tab is open, and
/// stays for as long as the NAS really is out of reach. When the NAS answers
/// again it says so before it goes.
///
/// Out of the way while the tab bar is: a photo open, or a grid selecting,
/// each has its own bar in this strip, and a photo that can't load says why
/// itself (`ConnectionMonitor.mediaMessage`).
struct ConnectionPill: View {
    let monitor: ConnectionMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let notice = monitor.notice, !GridChrome.shared.hidesTabBar {
                pill(notice)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
            }
        }
        .animation(.spring(duration: 0.4), value: monitor.notice)
        .onChange(of: monitor.notice) { _, notice in
            // Said aloud as well as shown: it comes and goes without anyone
            // having touched anything.
            guard let notice else { return }
            AccessibilityNotification.Announcement(Self.title(notice)).post()
        }
    }

    private func pill(_ notice: ConnectionMonitor.Notice) -> some View {
        content(notice)
            // One message out, then the next in, while the capsule resizes
            // between them. Left to morph, "Can't Reach Your NAS" and
            // "Connected Again" were drawn through each other for a moment,
            // half of each legible.
            .id(notice)
            .transition(.asymmetric(
                insertion: .opacity.animation(.easeIn(duration: 0.18).delay(0.12)),
                removal: .opacity.animation(.easeOut(duration: 0.12))
            ))
            .padding(.leading, 14)
            .padding(.trailing, notice == .unreachable ? 8 : 18)
            .padding(.vertical, 9)
            // Glass alone wasn't enough. Clear glass passes the photograph
            // under it straight through, and over a pale one the white title
            // measured worse than the banner this replaces. The background
            // color under the text makes it read on anything, dark mode or
            // light; the glass is left for the edge.
            .background(Color(uiColor: .systemBackground).opacity(0.78), in: Capsule())
            .glassCapsule(interactive: false, fallback: .regularMaterial)
            .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
            .padding(.horizontal, 16)
    }

    private func content(_ notice: ConnectionMonitor.Notice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: Self.symbol(notice))
                .font(.body.weight(.semibold))
                .foregroundStyle(Self.tint(notice))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(notice))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let detail = Self.detail(notice) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            // Only where trying again is up to the NAS. Without a network
            // there is nothing to try, and the phone says when there is one.
            if notice == .unreachable {
                Button { monitor.retryNow() } label: {
                    ZStack {
                        // Both laid out so the pill doesn't change width
                        // under a finger.
                        Text("Try Again").opacity(monitor.isChecking ? 0 : 1)
                        ProgressView()
                            .controlSize(.small)
                            .opacity(monitor.isChecking ? 1 : 0)
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.tint.opacity(0.18), in: Capsule())
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .disabled(monitor.isChecking)
                .accessibilityLabel(monitor.isChecking ? "Checking" : "Try Again")
            }
        }
    }

    static func title(_ notice: ConnectionMonitor.Notice) -> String {
        switch notice {
        case .offline: return "No Internet Connection"
        case .unreachable: return "Can't Reach Your NAS"
        case .reconnected: return "Connected Again"
        }
    }

    static func detail(_ notice: ConnectionMonitor.Notice) -> String? {
        switch notice {
        case .offline: return "Your library will update when you're back online."
        case .unreachable: return "Trying again automatically."
        case .reconnected: return nil
        }
    }

    private static func symbol(_ notice: ConnectionMonitor.Notice) -> String {
        switch notice {
        case .offline: return "wifi.slash"
        case .unreachable: return "exclamationmark.icloud.fill"
        case .reconnected: return "checkmark.circle.fill"
        }
    }

    private static func tint(_ notice: ConnectionMonitor.Notice) -> Color {
        notice == .reconnected ? .green : .orange
    }
}
#endif
