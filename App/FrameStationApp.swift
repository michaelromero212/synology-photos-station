import BackgroundTasks
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
            await MainActor.run { BackupEngine.backgroundRunner?() }
        }
        return true
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

    /// Portrait everywhere except the full-screen media viewer, which may turn
    /// landscape so a video can fill the screen. `OrientationGate` holds the
    /// current allowance; the viewer flips it as it opens and closes.
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        // iPad rotates freely — it multitasks and lives in every orientation.
        // Only iPhone is held portrait except inside the viewer.
        UIDevice.current.userInterfaceIdiom == .pad ? .all : OrientationGate.mask
    }
}

/// Which orientations the app allows right now.
///
/// The app is a portrait app — the grid and everything around it stay vertical.
/// The one exception is the full-screen media viewer: while it is open the
/// device may turn landscape so a video fills the screen, and leaving it snaps
/// back to portrait. The app delegate reports `mask`; the viewer drives it
/// through `openMedia` / `closeMedia`.
enum OrientationGate {
    /// Read by the delegate on the main thread and written from the main actor;
    /// a plain static so the non-isolated delegate callback can read it.
    static var mask: UIInterfaceOrientationMask = .portrait

    /// The media viewer opened — let the device rotate to landscape.
    @MainActor static func openMedia() { apply(.allButUpsideDown) }

    /// Back to the grid — hold portrait, rotating a landscape video back.
    @MainActor static func closeMedia() { apply(.portrait) }

    @MainActor private static func apply(_ new: UIInterfaceOrientationMask) {
        // iPad is left to rotate on its own — never forced by the viewer.
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        mask = new
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }
        // Re-evaluate the window: this lets landscape in while the viewer is
        // open and, on close, turns a landscape video back to the portrait grid.
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: new))
        scene.keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
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
        do { return try ModelContainer(for: BackupItem.self) }
        catch { fatalError("Could not open the backup queue: \(error)") }
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
            // A cut from a blank screen to a full library reads as a jolt even
            // when it is fast. Short and eased: long enough to feel like the
            // library arriving, too short to feel like waiting for it.
            .animation(.easeOut(duration: 0.18), value: session.phase)
            // At the root rather than on the sign-in screen. Hanging the
            // restore off `ConnectionView` meant the only way to *start*
            // restoring was to already be showing the form — which is why a
            // relaunch flashed sign-in at someone who was signed in.
            .task {
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
                } else {
                    await registrar.registerIfAuthorized()
                }
                await registrar.flushPendingRegistration()
            }
            #endif
            .transition(.opacity)

        case .launching:
            LaunchView()
                .transition(.opacity)

        case .disconnected, .connecting, .failed:
            ConnectionView(session: session)
                .transition(.opacity)
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
