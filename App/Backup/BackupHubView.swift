#if os(iOS)
import FrameStationAPI
import SwiftUI

/// Where the status bar on the Photos page leads.
///
/// One screen that answers "what is my backup doing" and offers the three
/// things you'd want next: run it now, watch the queue, change the rules.
struct BackupHubView: View {
    @Bindable var session: AppSession
    let engine: BackupEngine
    @Binding var settings: BackupSettings
    let onDone: () -> Void

    /// Held in state rather than read inline: `PhotoLibraryScanner.access` is a
    /// computed lookup, so SwiftUI has nothing to observe and the Start button
    /// stays disabled after the user grants permission until something else
    /// happens to redraw the view.
    @State private var access = PhotoLibraryScanner.access
    @State private var showFocused = false

    var body: some View {
        NavigationStack {
            list
        }
        .fullScreenCover(isPresented: $showFocused) {
            FocusedBackupView(engine: engine) { showFocused = false }
        }
    }

    private var list: some View {
        Group {
            List {
                // What backup is doing, not another way to start it.
                //
                // This screen used to open on a "Back Up Now" card with a Start
                // button, directly above a "Focused Backup" card with a Start
                // button — two controls that, to anyone who hasn't read the
                // code, do the same thing. Ordinary backup is a service that is
                // already running; what it needs here is a status and a way to
                // pause it, and the *one* action on this screen should be the
                // one you actually choose to take.
                Section("Backup Details") {
                    HStack(spacing: 12) {
                        Image(systemName: statusIcon)
                            .font(.title3)
                            .foregroundStyle(statusTint)
                            .frame(width: 26)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(statusTitle)
                                .font(.subheadline.weight(.medium))
                            Text(statusDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        if access != .authorized {
                            Button("Allow") {
                                Task { access = await PhotoLibraryScanner.requestAccess() }
                            }
                            .buttonStyle(.bordered)
                        } else if engine.isRunning {
                            Button("Pause") { engine.stop() }
                                .buttonStyle(.bordered)
                        } else if settings.enabled, engine.progress.pending > 0 {
                            Button("Resume") {
                                Task {
                                    await engine.scanLibrary()
                                    await engine.start()
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 2)
                }

                // Absent when there is nothing to focus on. A Start button over
                // an empty queue is a control that cannot do anything, and this
                // app drops those rather than graying them out.
                if access == .authorized, settings.enabled, engine.progress.pending > 0 {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(
                                "Works through the backlog in one sitting. FrameStation "
                                + "stays open with the screen dark, so the upload keeps "
                                + "going instead of waiting for iOS to hand it a moment."
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            Button("Start Focused Backup") { showFocused = true }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("Focused Backup")
                    } footer: {
                        Text("Best on Wi‑Fi and a charger. Leaving the app stops it.")
                    }
                }

                Section("Backup Management") {
                    NavigationLink {
                        TaskQueueView(engine: engine)
                    } label: {
                        LabeledContent {
                            Text(engine.progress.pending > 0 ? "\(engine.progress.pending)" : "")
                                .foregroundStyle(.secondary)
                        } label: {
                            Text("Task Queue")
                        }
                    }
                    NavigationLink {
                        BackupSettingsView(
                            session: session, engine: engine, settings: $settings
                        ) {}
                    } label: {
                        Text("Backup Settings")
                    }
                }

                if engine.progress.failed > 0 {
                    Section {
                        Button("Retry \(engine.progress.failed) Failed") {
                            Task { await engine.retryFailed() }
                        }
                    } footer: {
                        Text(engine.lastError ?? "")
                    }
                }
            }
            .onAppear { access = PhotoLibraryScanner.access }
            .navigationTitle("Photo Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onDone()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }

    // MARK: - What backup is doing

    private var statusIcon: String {
        if access != .authorized { return "lock.circle" }
        if !settings.enabled { return "icloud.slash" }
        if engine.progress.pending == 0 { return "checkmark.icloud" }
        return engine.isRunning ? "arrow.triangle.2.circlepath.icloud" : "pause.circle"
    }

    private var statusTint: Color {
        if access != .authorized || !settings.enabled { return .orange }
        return engine.progress.pending == 0 ? .green : .accentColor
    }

    /// Off is a status too. Hiding the row when backup is disabled leaves "is
    /// my phone backed up?" unanswered, which is the question this screen
    /// exists to answer.
    private var statusTitle: String {
        if access != .authorized { return "Photos Access Needed" }
        if !settings.enabled { return "Photo Backup Off" }
        if engine.progress.pending == 0 { return "Everything Backed Up" }
        return engine.isRunning ? "Backing Up" : "Backup Paused"
    }

    private var statusDetail: String {
        if access != .authorized {
            return "FrameStation needs to see your library to back it up."
        }
        if !settings.enabled { return "Turn it on in Backup Settings." }
        let pending = engine.progress.pending
        if pending == 0 { return "Nothing waiting to upload." }
        return pending == 1 ? "1 item waiting" : "\(pending) items waiting"
    }
}

/// The queue, with progress you can actually read.
///
/// Synology puts a small indeterminate spinner on each row, which tells you
/// something is happening but not whether it's nearly done. A 4 GB video and a
/// 2 MB photo look identical there. A real bar plus "62 MB of 413 MB" is the
/// difference between "is this stuck?" and "this has a minute to go".
struct TaskQueueView: View {
    let engine: BackupEngine

    var body: some View {
        Group {
            if engine.queued.isEmpty {
                ContentUnavailableView {
                    Label("Nothing waiting", systemImage: "checkmark.icloud")
                } description: {
                    Text(
                        engine.progress.done > 0
                            ? "Everything on this iPhone is backed up."
                            : "Photos queued for backup will appear here."
                    )
                }
            } else {
                List {
                    if !engine.activeUploads.isEmpty {
                        Section("In progress") {
                            ForEach(engine.activeUploads, id: \.localIdentifier) { active in
                                ActiveRow(active: active)
                            }
                        }
                    }
                    Section(waitingTitle) {
                        ForEach(waiting, id: \.localIdentifier) { entry in
                            QueueRow(localIdentifier: entry.localIdentifier)
                        }
                    }
                }
            }
        }
        .navigationTitle("Task Queue")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var waiting: [(localIdentifier: String, capturedAt: Date, state: UploadState)] {
        let inFlight = Set(engine.activeUploads.map(\.localIdentifier))
        return engine.queued.filter { !inFlight.contains($0.localIdentifier) }
    }

    private var waitingTitle: String {
        let count = waiting.count
        return count == 1 ? "1 waiting" : "\(count) waiting"
    }
}

private struct ActiveRow: View {
    let active: BackupEngine.ActiveUpload

    var body: some View {
        HStack(spacing: 12) {
            PendingTile(
                localIdentifier: active.localIdentifier, state: .uploading,
                size: CGSize(width: 54, height: 54)
            )
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
                Text(active.isPreparing ? "Preparing…" : "Backing up…")
                    .font(.subheadline.weight(.medium))

                if let fraction = active.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                    Text(
                        "\(BackupSettingsView.bytes(active.sentBytes)) of \(BackupSettingsView.bytes(active.byteSize))"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                } else {
                    // Indeterminate while exporting: there is no meaningful
                    // fraction yet, and a bar pinned at zero reads as stuck.
                    ProgressView().progressViewStyle(.linear)
                    Text(BackupSettingsView.bytes(active.byteSize))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct QueueRow: View {
    let localIdentifier: String

    var body: some View {
        HStack(spacing: 12) {
            PendingTile(
                localIdentifier: localIdentifier, state: .pending,
                size: CGSize(width: 44, height: 44)
            )
            .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text("Waiting").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
#endif
