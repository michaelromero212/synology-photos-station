#if os(iOS)
import FrameStationAPI
import Foundation
import Photos
import SwiftUI

/// Backup preferences. Mirrors Synology's screen, with the two options it
/// lacks: charging-only, and choosing which space to back up into.
/// What a backup run is asked to cover.
///
/// Synology's three, kept because they answer three questions people actually
/// have: pick up where you left off, sweep the whole library, or draw a line
/// under today and only take what comes next.
enum BackupRule: String, CaseIterable, Identifiable, Equatable {
    case resume
    case scanAll
    case futureOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .resume: return "Resume tasks"
        case .scanAll: return "Scan and back up all photos"
        case .futureOnly: return "Back up future photos"
        }
    }

    var detail: String {
        switch self {
        case .resume:
            return "Continue the last backup task. Changes to previous photos "
                + "will be backed up as new files."
        case .scanAll:
            return "Backed-up items will be skipped, but items renamed, deleted, "
                + "or moved to another space will be backed up again."
        case .futureOnly:
            return "Back up photos and videos taken from now on. Changes made to "
                + "previous items will also be backed up as new files."
        }
    }
}

struct BackupSettings: Equatable {
    var enabled = false
    var rule: BackupRule = .resume
    /// When `futureOnly` started, so a run knows where the line was drawn.
    var futureCutoff: Date?
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
        static let rule = "backup.rule"
        static let cutoff = "backup.futureCutoff"
    }

    static func load() -> BackupSettings {
        let defaults = UserDefaults.standard
        var settings = BackupSettings()
        settings.enabled = defaults.bool(forKey: Key.enabled)
        settings.wifiOnly = defaults.object(forKey: Key.wifiOnly) as? Bool ?? true
        settings.chargingOnly = defaults.bool(forKey: Key.chargingOnly)
        settings.includeVideos = defaults.object(forKey: Key.includeVideos) as? Bool ?? true
        settings.targetSpaceID = defaults.string(forKey: Key.target).flatMap(UUID.init(uuidString:))
        settings.rule = defaults.string(forKey: Key.rule)
            .flatMap(BackupRule.init(rawValue:)) ?? .resume
        settings.futureCutoff = defaults.object(forKey: Key.cutoff) as? Date
        return settings
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: Key.enabled)
        defaults.set(wifiOnly, forKey: Key.wifiOnly)
        defaults.set(chargingOnly, forKey: Key.chargingOnly)
        defaults.set(includeVideos, forKey: Key.includeVideos)
        defaults.set(targetSpaceID?.uuidString, forKey: Key.target)
        defaults.set(rule.rawValue, forKey: Key.rule)
        defaults.set(futureCutoff, forKey: Key.cutoff)
    }
}

struct BackupSettingsView: View {
    @Bindable var session: AppSession
    let engine: BackupEngine
    @Binding var settings: BackupSettings
    let onDone: () -> Void

    @State private var access = PhotoLibraryScanner.access
    private var registrar: PushRegistrar { .shared }

    /// Says where the files land, in the terms the file tree uses — the same
    /// promise Synology makes on this screen, and one this app can keep now
    /// that uploads are written to human paths.
    private var destinationExplanation: String {
        let name = settings.targetSpace(in: session.spaces)?.name ?? "your personal space"
        return "Photos and videos are backed up to folders created under "
            + "/\(name)/MobileBackup/iPhone, named by the year and month they "
            + "were taken."
    }

    var body: some View {
        NavigationStack {
            Form {
                accessSection

                Section {
                    Toggle("Back Up This iPhone", isOn: $settings.enabled)
                } footer: {
                    Text("Photos and videos are copied to your NAS. Nothing is removed from this device.")
                }

                Section("Backup Rule") {
                    ForEach(BackupRule.allCases) { rule in
                        Button {
                            settings.rule = rule
                            // Only meaningful for the rule that draws a line
                            // under now; stale on the other two.
                            settings.futureCutoff = rule == .futureOnly ? Date() : nil
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(rule.title).foregroundStyle(.primary)
                                    Text(rule.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if settings.rule == rule {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    Picker("Backup Destination", selection: $settings.targetSpaceID) {
                        ForEach(session.spaces) { space in
                            Text(space.name).tag(Optional(space.id))
                        }
                    }
                } header: {
                    Text("Backup Path")
                } footer: {
                    Text(destinationExplanation)
                }

                Section("Upload Settings") {
                    Toggle("Wi-Fi Only", isOn: $settings.wifiOnly)
                    Toggle("Only While Charging", isOn: $settings.chargingOnly)
                    // Phrased as Synology phrases it. Stored the other way
                    // round, so the toggle reads inverted.
                    Toggle("Photos Only", isOn: Binding(
                        get: { !settings.includeVideos },
                        set: { settings.includeVideos = !$0 }
                    ))
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
