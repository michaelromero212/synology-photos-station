#if os(iOS)
import FrameStationAPI
import Foundation
import Photos
import SwiftUI

/// Backup preferences. Mirrors Synology's screen, with the two options it
/// lacks: charging-only, and choosing which space to back up into.
struct BackupSettings: Equatable {
    var enabled = false
    var wifiOnly = true
    var chargingOnly = false
    var includeVideos = true
    var targetSpaceID: UUID?

    func targetSpace(in spaces: [SpaceDTO]) -> SpaceDTO? {
        if let targetSpaceID, let match = spaces.first(where: { $0.id == targetSpaceID }) {
            return match
        }
        return spaces.first { $0.kind == .personal }
    }

    private enum Key {
        static let enabled = "backup.enabled"
        static let wifiOnly = "backup.wifiOnly"
        static let chargingOnly = "backup.chargingOnly"
        static let includeVideos = "backup.includeVideos"
        static let target = "backup.targetSpaceID"
    }

    static func load() -> BackupSettings {
        let defaults = UserDefaults.standard
        var settings = BackupSettings()
        settings.enabled = defaults.bool(forKey: Key.enabled)
        settings.wifiOnly = defaults.object(forKey: Key.wifiOnly) as? Bool ?? true
        settings.chargingOnly = defaults.bool(forKey: Key.chargingOnly)
        settings.includeVideos = defaults.object(forKey: Key.includeVideos) as? Bool ?? true
        settings.targetSpaceID = defaults.string(forKey: Key.target).flatMap(UUID.init(uuidString:))
        return settings
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: Key.enabled)
        defaults.set(wifiOnly, forKey: Key.wifiOnly)
        defaults.set(chargingOnly, forKey: Key.chargingOnly)
        defaults.set(includeVideos, forKey: Key.includeVideos)
        defaults.set(targetSpaceID?.uuidString, forKey: Key.target)
    }
}

struct BackupSettingsView: View {
    @Bindable var session: AppSession
    let engine: BackupEngine
    @Binding var settings: BackupSettings
    let onDone: () -> Void

    @State private var access = PhotoLibraryScanner.access
    private var registrar: PushRegistrar { .shared }

    var body: some View {
        NavigationStack {
            Form {
                accessSection

                Section {
                    Toggle("Back Up This iPhone", isOn: $settings.enabled)
                } footer: {
                    Text("Photos and videos are copied to your NAS. Nothing is removed from this device.")
                }

                Section("Backup Destination") {
                    Picker("Library", selection: $settings.targetSpaceID) {
                        ForEach(session.spaces) { space in
                            Text(space.name).tag(Optional(space.id))
                        }
                    }
                }

                Section("Upload Settings") {
                    Toggle("Wi-Fi Only", isOn: $settings.wifiOnly)
                    Toggle("Only While Charging", isOn: $settings.chargingOnly)
                    Toggle("Include Videos", isOn: $settings.includeVideos)
                }

                notificationSection

                statusSection
            }
            .navigationTitle("Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
            .onChange(of: settings) { _, new in
                new.save()
                engine.update(settings: new)
                // Asking iOS for background time only makes sense while backup
                // is actually on; leaving a request pending after it's switched
                // off wakes the app to do nothing.
                if new.enabled {
                    engine.enableBackgroundRuns()
                } else {
                    engine.disableBackgroundRuns()
                }
            }
            .task {
                access = PhotoLibraryScanner.access
                await registrar.refreshAuthorization()
                // Resolve the implicit default into the binding so the picker
                // shows the space that backup will actually use, instead of
                // rendering blank because nil matches no tag.
                if settings.targetSpaceID == nil {
                    settings.targetSpaceID = settings.targetSpace(in: session.spaces)?.id
                }
            }
        }
    }

    // MARK: - Access

    @ViewBuilder
    private var accessSection: some View {
        switch access {
        case .authorized:
            EmptyView()

        case .notDetermined:
            Section {
                Button("Allow Access to Photos") {
                    Task { access = await PhotoLibraryScanner.requestAccess() }
                }
            } footer: {
                Text("FrameStation needs to read your photo library to back it up.")
            }

        case .limited:
            Section {
                Label("Limited photo access", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Open Settings") { openSettings() }
            } footer: {
                // Said plainly rather than failing quietly: with limited access
                // we can only see the handful of photos you picked, so a
                // "complete" backup would be anything but.
                Text("FrameStation can only see the photos you selected, so it can't back up your library. Choose \"All Photos\" in Settings → Privacy → Photos.")
            }

        case .denied:
            Section {
                Label("Photo access denied", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Button("Open Settings") { openSettings() }
            } footer: {
                Text("Backup can't run without access to your photo library.")
            }
        }
    }

    // MARK: - Notifications

    @ViewBuilder
    private var notificationSection: some View {
        Section {
            switch registrar.authorization {
            case .authorized, .provisional, .ephemeral:
                Label("On", systemImage: "bell.fill").foregroundStyle(.green)
            case .notDetermined:
                Button("Turn On Notifications") {
                    Task { await registrar.requestAuthorization() }
                }
            case .denied:
                Label("Off", systemImage: "bell.slash").foregroundStyle(.secondary)
                Button("Open Settings") { openSettings() }
            @unknown default:
                EmptyView()
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Get told when someone adds photos or videos to a shared space.")
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Backed up", value: "\(engine.progress.done)")
            LabeledContent("Remaining", value: "\(engine.progress.pending)")
            if engine.progress.failed > 0 {
                LabeledContent("Needs retrying", value: "\(engine.progress.failed)")
                Button("Retry Failed") { Task { await engine.retryFailed() } }
            }
            if engine.progress.skipped > 0 {
                LabeledContent("Skipped", value: "\(engine.progress.skipped)")
            }
            if engine.progress.bytesRemaining > 0 {
                LabeledContent("To upload", value: Self.bytes(engine.progress.bytesRemaining))
            }

            if engine.isRunning {
                Button("Pause") { engine.stop() }
            } else if access == .authorized {
                Button("Back Up Now") {
                    Task {
                        await engine.scanLibrary()
                        await engine.start()
                    }
                }
            }

            if let error = engine.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    static func bytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(value), unit = 0
        while amount >= 1024, unit < units.count - 1 { amount /= 1024; unit += 1 }
        return String(format: unit <= 1 ? "%.0f %@" : "%.1f %@", amount, units[unit])
    }
}
#endif
