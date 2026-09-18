import BackgroundTasks
import FrameStationAPI
import SwiftData
import SwiftUI
#if os(iOS)
import UIKit
#endif

#if os(iOS)
/// Carries a value across an isolation boundary the compiler can't verify.
///
/// Only for bridging framework callbacks that predate strict concurrency —
/// never as a way to quiet a warning about our own types.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Exists only to receive the APNs token: `didRegisterForRemoteNotifications`
/// has no SwiftUI equivalent.
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Both have to happen before launch finishes: BGTaskScheduler throws if
        // an identifier is registered later, and the background session has to
        // exist for iOS to hand back transfers that finished while we were gone.
        BackgroundTransfers.shared.reconnect()
        BackupScheduler.register {
            _ = await BackupEngine.backgroundRunner?()
        }
        return true
    }

    /// A silent push: the NAS believes this device has a backup it hasn't
    /// finished, and has asked iOS to give us a moment to get on with it.
    ///
    /// This is the one wake-up we can influence. A `BGProcessingTask` window
    /// arrives when iOS decides — often overnight, sometimes not for most of a
    /// day — which is why a first backup of a few thousand photographs can
    /// appear to have stopped. See the server's `BackupNudger` for what decides
    /// to send one, and for the restraint that keeps Apple's background budget
    /// from being spent on a phone that is switched off.
    ///
    /// The completion handler's answer is not a formality. iOS reads it to
    /// decide how generous to be next time, so this reports `.newData` only when
    /// photographs actually moved; claiming it every time is how an app teaches
    /// the system to stop waking it.
    ///
    /// Anything that is not ours is answered `.noData` rather than ignored —
    /// iOS suspends the app rather harshly if the handler is never called.
    /// The completion-handler form rather than the `async` one, which is the
    /// same choice `handleEventsForBackgroundURLSession` above makes. UIKit
    /// hands over a `[AnyHashable: Any]`, which is not `Sendable`: taken as an
    /// `async` method the payload has to cross an isolation boundary to be read
    /// at all, and no amount of annotation makes that clean. This form is
    /// ordinary main-actor code, so the dictionary is read where it arrives and
    /// only the decision travels on.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification payload: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // `backgroundRunner` is nil when iOS woke us before the app had built an
        // engine — signed out, or launched straight into the background. The
        // scheduled window is still booked, so that costs promptness rather than
        // the backup.
        guard payload[PushPayloadKey.kind] as? String == PushPayloadKey.kindBackup else {
            completionHandler(.noData)
            return
        }
        guard let runner = BackupEngine.backgroundRunner else {
            Diagnostics.shared.log(.backup, "woken by the NAS, but backup isn't running here")
            completionHandler(.noData)
            return
        }
        // Written down because this is the only record there will be. A silent
        // push arrives while the phone is in somebody's pocket, hours from the
        // nearest console, and "did the wake-ups actually happen?" is the first
        // question to ask of a backup that still looks stuck.
        Diagnostics.shared.log(.backup, "woken by the NAS to finish backing up")
        let box = UncheckedSendableBox(completionHandler)
        Task {
            // Unstructured, and left running on purpose. iOS wants the handler
            // called within about thirty seconds and a backup is not a
            // thirty-second job; chunks sent while backgrounded go over a
            // background `URLSession` that outlives this handler and outlives
            // the process, so returning hands the work over rather than
            // abandoning it. See `BackgroundTransfers`.
            let work = Task { await runner() }
            let moved = await Self.answer(for: work)
            Diagnostics.shared.log(
                .backup, moved ? "wake-up moved photographs" : "wake-up found nothing to do"
            )
            box.value(moved ? .newData : .noData)
        }
    }

    /// What to tell iOS about a wake-up that may not be finished.
    ///
    /// Waits for the run, or for the budget to run out, whichever comes first —
    /// and does not cancel the run when it is the latter, which is the whole
    /// reason `work` is unstructured rather than a child of this group.
    ///
    /// Out of time is reported as `.newData`. It means the run found something
    /// to do and is still doing it, and the question iOS is really asking is
    /// whether waking us was worth it. Answering `.noData` to a productive
    /// wake-up is how an app teaches the system to stop bothering.
    private static func answer(for work: Task<Bool, Never>) async -> Bool {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await work.value }
            group.addTask {
                // Twenty-five of the thirty, leaving margin for the handler
                // itself to be called and for iOS to act on it.
                try? await Task.sleep(for: .seconds(25))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? true
        }
    }

    /// iOS relaunched us purely to say background uploads finished.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // UIKit hands this back without a `Sendable` annotation, even though
        // its own contract is store-it-now and call-it-later from wherever the
        // session finishes. The box states that assumption explicitly instead
        // of weakening the property's type to hide the warning.
        let box = UncheckedSendableBox(completionHandler)
        BackgroundTransfers.shared.setSystemCompletionHandler { box.value() }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        MainActor.assumeIsolated { PushRegistrar.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        MainActor.assumeIsolated { PushRegistrar.shared.didFailToRegister(error) }
    }

    /// The iPhone app is portrait, full stop.
    ///
    /// Letting the *window* turn landscape so a video could fill the screen was
    /// the obvious way to do it, and it was wrong: the whole app came round with
    /// it, so the grid, the chrome and the tab bar all lay on their side. Only
    /// the picture should turn. `MediaTilt` rotates the clip inside a window
    /// that never moves — see `VideoPlayerView`.
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        // iPad rotates freely — it multitasks and lives in every orientation.
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }
}

/// Which way the phone is actually being held.
///
/// The window is locked portrait, so nothing in UIKit turns when you rotate the
/// device — which is the point: the grid and its chrome must stay upright. But a
/// video still wants to fill the screen when you turn the phone sideways, and
/// the only way to do that in a window that never rotates is to rotate the clip
/// ourselves. This reports the physical tilt so `VideoPlayerView` can.
///
/// Reads the accelerometer-backed device orientation rather than the interface
/// orientation, because the interface orientation is now always portrait and
/// would tell us nothing.
@Observable
@MainActor
final class MediaTilt {
    /// One reader for the app. The pager builds each page's controller once and
    /// keeps it, so a tilt passed *in* would freeze at the value it had when the
    /// page was built; reaching for a shared observable instead lets every page
    /// body — whenever it was made — see the current one.
    static let shared = MediaTilt()

    /// Degrees to turn the picture so it looks upright to someone holding the
    /// phone this way. Zero in portrait.
    private(set) var angle: Double = 0
    var isSideways: Bool { angle != 0 }

    private var observer: (any NSObjectProtocol)?

    func start() {
        guard observer == nil else { return }
        let device = UIDevice.current
        device.beginGeneratingDeviceOrientationNotifications()
        read(device.orientation)
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.read(UIDevice.current.orientation) }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        angle = 0
    }

    /// `faceUp`, `faceDown` and `unknown` are deliberately ignored — a phone
    /// lying on a table shouldn't spin the video, it should keep whatever it had.
    private func read(_ orientation: UIDeviceOrientation) {
        switch orientation {
        // Home edge to the right: the device turned anticlockwise, so the
        // picture turns clockwise by the same amount to meet the eye.
        case .landscapeLeft: angle = 90
        case .landscapeRight: angle = -90
        case .portrait: angle = 0
        default: break
        }
    }
}
#endif

@main
struct FrameStationApp: App {
    @State private var session = AppSession()
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.default
    #if os(iOS)
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    #endif
    #if os(iOS)
    /// Durable backup queue. On-disk because the engine must survive being
    /// killed mid-run — see BackupQueue.
    private let backupContainer: ModelContainer = {
        // SwiftData puts its store in Application Support, and iOS does not
        // create that directory for you — only `Library` itself. On a fresh
        // install the store therefore fails to open, CoreData dumps a few
        // hundred lines of filesystem diagnostics walking the tree looking for
        // somewhere writable, and *then* recovers by creating the directory it
        // needed all along. The store ends up fine; the log looks like the app
        // is broken. Creating it first skips the whole performance.
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            try? FileManager.default.createDirectory(
                at: support, withIntermediateDirectories: true
            )
        }
        do { return try ModelContainer(for: BackupItem.self, ManualUpload.self) }
        catch {
            // Degraded, never dead.
            //
            // This was a `fatalError`, which made an unopenable queue a phone
            // that cannot start its photo library at all — the one outcome
            // worse than losing the queue. A store can fail to open for
            // reasons that have nothing to do with the photographs: a disk
            // full at the wrong moment, a schema the app can't migrate, a file
            // left unreadable by a restore.
            //
            // An in-memory container keeps every other part of the app
            // working: browsing, uploading by hand, shared albums, playback.
            // Only the durable queue is lost, and it rebuilds itself from the
            // photo library on the next scan.
            Diagnostics.shared.log(
                .launch, "backup queue unavailable, running in memory: \(error)"
            )
            do {
                return try ModelContainer(
                    for: BackupItem.self, ManualUpload.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                )
            } catch {
                fatalError("Could not open even an in-memory queue: \(error)")
            }
        }
    }()
    #endif

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
            #if os(iOS)
                .modelContainer(backupContainer)
                .environment(\.backupContainer, backupContainer)
            #endif
            #if os(macOS)
                .frame(minWidth: 640, minHeight: 480)
            #endif
                // At the root so it reaches the sign-in screen, every sheet and
                // every full-screen cover — a preference applied inside the tab
                // view would leave the parts presented over it on the system
                // scheme, which is exactly where a half-done dark mode shows.
                .preferredColorScheme(appearance.colorScheme)
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 800)
        #endif

        #if os(macOS)
        // Preferences behind ⌘, rather than as a destination in the app.
        //
        // They were a "More" tab, which is where a phone has to put them — a
        // tab bar is the only chrome it has. A Mac has a menu bar and a
        // Settings panel, and a fifth sidebar row competing with your library
        // for attention is a row you read past every day to reach the photos.
        Settings {
            MacSettingsView(session: session)
                .preferredColorScheme(appearance.colorScheme)
        }
        #endif
    }
}

struct RootView: View {
    @Bindable var session: AppSession

    var body: some View {
        content
            // No animation here, and specifically not an `.animation(_:value:)`
            // across this whole subtree.
            //
            // There used to be a 0.18s ease on `session.phase`, to stop a cut
            // from a blank screen to a full library reading as a jolt. The cost
            // was out of all proportion: that modifier animates *every* change
            // in the subtree that lands in the same transaction as the phase
            // flip, and the phase flips at exactly the moment the library is
            // doing its first layout. So the grid's own content was being
            // animated — two layouts of the same photographs cross-fading over
            // each other, which is why a frame-by-frame of the launch caught a
            // row of pictures apparently drawn *below* the backup banner, a
            // place nothing can legitimately be.
            //
            // Scoping it was tried and is not enough: `.transition(.identity)`
            // on the connected case stops that view fading itself, and does
            // nothing about the contents it animates on the way in.
            //
            // The jolt it was avoiding is worth less than this. An instant cut
            // is what Photos does, and a library that is simply *there* reads as
            // fast rather than as unfinished.
            // At the root rather than on the sign-in screen. Hanging the
            // restore off `ConnectionView` meant the only way to *start*
            // restoring was to already be showing the form — which is why a
            // relaunch flashed sign-in at someone who was signed in.
            .task {
                #if os(iOS)
                // Before anything lays out. The grid reads this on its very
                // first pass and `keyWindow` is not reliably there yet on a
                // device — see `WindowMetrics`.
                WindowMetrics.seed()
                #endif
                guard session.phase == .launching else { return }
                // Stored credentials first — a relaunch shouldn't need a
                // new invite.
                if await session.restore() { return }
                if session.shouldAutoConnect, session.phase == .disconnected {
                    await session.connect()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .connected:
            RootTabView(session: session)
            #if os(iOS)
            .task {
                let registrar = PushRegistrar.shared
                registrar.attach(to: session)
                // Ask once. Being told a family member shared photos is the
                // point of a shared space, so this is worth a prompt — but only
                // after sign-in, when the app can explain itself.
                if !UserDefaults.standard.bool(forKey: "push.didAsk") {
                    UserDefaults.standard.set(true, forKey: "push.didAsk")
                    await registrar.requestAuthorization()
                }
                // Whatever was said to the prompt. A token is needed either way
                // — the silent push that finishes a stalled backup travels on
                // it and shows nothing. See `registerForPushes`.
                await registrar.registerForPushes()
                await registrar.flushPendingRegistration()
            }
            #endif
            // `.identity`, not `.opacity`, and not merely omitted — an absent
            // transition defaults to a fade while an animation is running.
            //
            // The library arrives at full opacity and the launch screen
            // dissolves off the top of it. Cross-fading *into* it instead meant
            // the grid was changing opacity at the same moment it was doing its
            // first layout — lazy rows realising, `defaultScrollAnchor(.bottom)`
            // taking up the slack, the banner sizing itself — so the settling
            // that should happen behind a blank screen happened in front of the
            // user instead. That is the flash at the bottom of the screen about
            // a second into a cold launch: caught on a recording, the whole UI
            // dimmed at 4.13s and came back at 4.28s, which is this 0.18s fade.
            //
            // The intent above survives: it is still not a hard cut, because
            // the launch screen still eases away. Only the library stops being
            // animated while it is still assembling itself.
            .transition(.identity)

        case .launching:
            // `.identity` too. With no animation above there is nothing to
            // drive a fade, and leaving `.opacity` here would only suggest
            // otherwise to the next person reading it.
            LaunchView()
                .transition(.identity)

        case .disconnected, .connecting, .failed:
            ConnectionView(session: session)
                .transition(.identity)
        }
    }
}

/// What the app shows before it knows whether anyone is signed in.
///
/// Deliberately empty. `UILaunchScreen: {}` is a bare background, so anything
/// drawn here is a *second* thing the eye has to see and lose on the way to the
/// grid — which is exactly what a branded splash looked like: blank, logo,
/// grid, with the logo lingering for however long `/v1/me` took.
///
/// Matching the launch screen instead makes the handoff invisible. The first
/// frame the app draws is the frame iOS was already showing, and the only
/// visible change is the library arriving.
private struct LaunchView: View {
    var body: some View {
        Color.clear
    }
}
