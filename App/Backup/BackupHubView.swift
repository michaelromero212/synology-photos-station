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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Back Up Now")
                            .font(.headline)
                        Text("Uploads as fast as the network allows while FrameStation is open. Backup also runs on its own in the background.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if access != .authorized {
                            Button("Allow Access to Photos") {
                                Task { access = await PhotoLibraryScanner.requestAccess() }
                            }
                            .buttonStyle(.borderedProminent)
                        } else if engine.isRunning {
                            Button("Pause") { engine.stop() }
                                .buttonStyle(.bordered)
                        } else {
                            Button("Start") {
                                Task {
                                    await engine.scanLibrary()
                                    await engine.start()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(access != .authorized)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Focused Backup")
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
                    if let active = engine.active {
                        Section("In progress") {
                            ActiveRow(active: active)
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
        engine.queued.filter { $0.localIdentifier != engine.active?.localIdentifier }
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
                localIdentifier: active.localIdentifier, state: .uploading, side: 54
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
            PendingTile(localIdentifier: localIdentifier, state: .pending, side: 44)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text("Waiting").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
#endif
