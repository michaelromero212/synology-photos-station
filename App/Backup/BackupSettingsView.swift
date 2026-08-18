#if os(iOS)
import FrameStationAPI
import FrameStationKit
import Foundation
import Photos
import SwiftUI

/// Backup preferences. Mirrors Synology's screen, with the two options it
/// lacks: charging-only, and choosing which space to back up into.
struct BackupSettings: Equatable {
    var enabled = false
    var rule: BackupRule = .resume
    /// When `futureOnly` started, so a run knows where the line was drawn.
    var futureCutoff: Date?
    var wifiOnly = true
    var chargingOnly = false
    var includeVideos = true
    var targetSpaceID: UUID?

    /// Always your own library, and never anyone else's.
    ///
    /// This used to honour `targetSpaceID`, so backup could be pointed at a
    /// shared space — which meant one setting, chosen once and then forgotten,
    /// could quietly publish an entire camera roll to the family. Backup runs
    /// unattended on everything the phone takes; the blast radius of getting
    /// that wrong is every private photo you own, and no amount of confirming
    /// at the time makes it safe a year later.
    ///
    /// Sharing deliberately still exists — that is what the picker and Move To
    /// are for. The difference is that those are decisions taken per photo,
    /// with the photos in front of you.
    ///
    /// `targetSpaceID` is left on the type rather than deleted so an existing
    /// stored preference deserialises; it is simply no longer consulted.
    func targetSpace(in spaces: [SpaceDTO]) -> SpaceDTO? {
        spaces.first { $0.kind == .personal }
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
            + "were taken.\n\nBackup only ever goes to your own library. To put "
            + "something in a shared space, choose it there — nothing reaches "
            + "the family by default."
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

                // Stated, not chosen. Backup has exactly one destination now —
                // see `BackupSettings.targetSpace`.
                Section {
                    // A plain row rather than `LabeledContent` holding a
                    // `Label`: that combination expands to fill the section and
                    // leaves a tall empty box under a single line of text.
                    HStack {
                        Text("Backup Destination")
                        Spacer(minLength: 12)
                        Image(systemName: "person")
                        Text(settings.targetSpace(in: session.spaces)?.name ?? "Personal Space")
                    }
                    .foregroundStyle(.primary)
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
                // Retires any destination a previous version stored. Nothing
                // reads it now, but leaving a shared space's id sitting in
                // preferences invites a future change to honour it again.
                if settings.targetSpaceID != nil {
                    settings.targetSpaceID = nil
                    settings.save()
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
