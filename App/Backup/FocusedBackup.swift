#if os(iOS)
import Observation
import SwiftUI
import UIKit

/// Giving the backup the phone's full attention until it is done.
///
/// The reason this needs to exist is iOS, not the network. A background upload
/// runs when the system feels like letting it: it is scheduled against battery,
/// thermals, and how often you open the app, and a first backup of a large
/// library can take days of being handed occasional minutes. A foreground app
/// is under no such rationing — it uploads continuously for as long as it is on
/// screen.
///
/// So this holds the app on screen deliberately. It stops the display sleeping,
/// takes the brightness almost to nothing, and hands the queue everything it
/// has. The dark screen is the point rather than decoration: the phone has to
/// stay awake and unlocked for this to work at all, and a bright screen doing
/// that for an hour is a flat battery and a distraction on the side.
///
/// It does not make any single photograph upload faster, and does not pretend
/// to. Uploads stay one at a time — see ARCHITECTURE.md §8, a phone pushing six
/// files at once over home wifi finishes later and saturates the link for
/// everyone else. What changes is that the queue never stops moving.
@Observable
@MainActor
final class FocusedBackupSession {
    private(set) var isRunning = false
    /// True once the screen has been taken down, so the view can stop
    /// counting and get out of the way.
    private(set) var isDimmed = false

    /// What the brightness was before we touched it.
    ///
    /// Kept rather than assumed: restoring to some default would leave anybody
    /// who runs their phone dim at midday, and anybody who runs it bright in
    /// the dark. This has to put back exactly what it found.
    private var brightnessBefore: CGFloat?

    private weak var engine: BackupEngine?
    private var dimTask: Task<Void, Never>?

    /// Seconds of readable screen before it goes dark, so the instructions can
    /// actually be read first.
    static let dimAfter: Double = 4

    init(engine: BackupEngine?) {
        self.engine = engine
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        isDimmed = false

        // The phone must not lock. Everything else here follows from that.
        UIApplication.shared.isIdleTimerDisabled = true
        brightnessBefore = UIScreen.main.brightness

        dimTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.dimAfter * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isRunning else { return }
            withAnimation(.easeInOut(duration: 1.2)) {
                UIScreen.main.brightness = 0.02
                self.isDimmed = true
            }
        }

        Task { [weak engine] in
            await engine?.scanLibrary()
            await engine?.start()
        }
    }

    /// Puts the phone back exactly as it was found.
    ///
    /// Called from more places than feels necessary, on purpose. Leaving
    /// somebody's screen at two per cent brightness with auto-lock switched off
    /// is a genuinely bad thing to do to a phone, and every path out of this
    /// screen — the button, backgrounding the app, the view going away — has to
    /// end here.
    func stop() {
        dimTask?.cancel()
        dimTask = nil
        if let brightnessBefore {
            UIScreen.main.brightness = brightnessBefore
            self.brightnessBefore = nil
        }
        UIApplication.shared.isIdleTimerDisabled = false
        isDimmed = false
        guard isRunning else { return }
        isRunning = false
        engine?.stop()
    }
}

/// The screen that holds the phone's attention.
struct FocusedBackupView: View {
    let engine: BackupEngine
    let onDone: () -> Void

    @State private var session: FocusedBackupSession?
    @State private var countdown = Int(FocusedBackupSession.dimAfter)
    @Environment(\.scenePhase) private var scenePhase

    private var waiting: Int { engine.progress.pending }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 40)

                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.tint)
                    .padding(.bottom, 28)

                Text(waiting > 0 ? "Backing up…" : "All backed up")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)

                Text(waiting == 1 ? "1 item waiting" : "\(waiting) items waiting")
                    .font(.body)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 4)

                if let active = engine.active, let fraction = active.fraction {
                    ProgressView(value: fraction)
                        .tint(.white)
                        .frame(maxWidth: 220)
                        .padding(.top, 22)
                }

                // The three things that actually decide whether this finishes.
                // Stated as conditions rather than warnings: none of them are
                // errors, they are what the phone needs to get through a large
                // backlog in one sitting.
                VStack(alignment: .leading, spacing: 14) {
                    condition("wifi", "Stay on Wi‑Fi")
                    condition("bolt.fill", "Stay on the charger")
                    condition("iphone", "Leave FrameStation open")
                }
                .padding(.top, 40)

                Spacer()

                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 18)

                Button {
                    session?.stop()
                    onDone()
                } label: {
                    Text("Stop Focused Backup")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 28)
            }
            // Everything except the stop button fades with the screen, so what
            // is left glowing at two per cent is the way out.
            .opacity(session?.isDimmed == true ? 0.35 : 1)
            .animation(.easeInOut(duration: 1.2), value: session?.isDimmed)
        }
        .task {
            let created = FocusedBackupSession(engine: engine)
            session = created
            created.start()
            // Counts down only while there is something to count to.
            while countdown > 0, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                countdown -= 1
            }
        }
        // Leaving the app ends it. The whole feature is "the app is in front";
        // once it isn't, holding the screen awake would just be draining a
        // phone in somebody's pocket.
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            session?.stop()
        }
        .onDisappear { session?.stop() }
        // Finishing is a reason to hand the phone back, not to sit on a dark
        // screen that has nothing left to do.
        .onChange(of: engine.progress.pending) { _, pending in
            guard pending == 0, session?.isRunning == true else { return }
            session?.stop()
        }
        #if compiler(>=6.2)
        .persistentSystemOverlays(.hidden)
        #endif
        .preferredColorScheme(.dark)
    }

    private var footnote: String {
        if session?.isDimmed == true {
            return "The screen is dark to save battery. Backup is still running."
        }
        if countdown > 0 {
            return "The screen will turn dark in \(countdown) second\(countdown == 1 ? "" : "s")."
        }
        return "The screen is dark to save battery. Backup is still running."
    }

    private func condition(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(.white.opacity(0.8))
            Text(text)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}
#endif
