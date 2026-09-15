import FrameStationAPI
import SwiftUI

/// How videos behave once one finishes.
///
/// This replaced a "Play All Videos" slideshow mode. The mode was the wrong
/// shape for what people actually do: nobody decides in advance to watch a
/// day's clips, they tap the first one and then want the next. So the choice
/// moved out of a menu you have to find and into a preference that changes
/// what the ordinary tap does.
///
/// On by default, because continuing is what the birthday-party case wants —
/// four clips from one afternoon, watched end to end without going back to the
/// grid between each. Off is for someone who opened one video on purpose and
/// doesn't want to be handed another.
enum PlaybackSettings {
    private static let autoPlayKey = "playback.autoPlayNextVideo"

    static var autoPlayNextVideo: Bool {
        get { UserDefaults.standard.object(forKey: autoPlayKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoPlayKey) }
    }

    // MARK: - Video quality

    private static let qualityKey = "playback.videoQuality"

    static var videoQuality: VideoQualityPreference {
        get {
            UserDefaults.standard.string(forKey: qualityKey)
                .flatMap(VideoQualityPreference.init(rawValue:)) ?? .auto
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: qualityKey) }
    }

    /// What to actually ask the server for, given the network underfoot.
    ///
    /// The original is a 4K clip at roughly 51 Mbps. A home network carries that
    /// comfortably; a cellular link does not, and the buffer can never get ahead
    /// of playback — which is a video that stalls every few seconds rather than
    /// one that looks slightly softer. So `auto` follows the connection, which
    /// is what almost everyone wants and why it is the default.
    static func resolvedQuality(isExpensive: Bool) -> PlaybackQuality {
        switch videoQuality {
        case .original: return .original
        case .dataSaver: return .mobile
        case .auto: return isExpensive ? .mobile : .original
        }
    }
}

/// The user-facing choice. Distinct from `PlaybackQuality`, which is the wire
/// value: `auto` is a rule, not a representation, and the server never sees it.
enum VideoQualityPreference: String, CaseIterable, Identifiable {
    case auto
    case original
    case dataSaver

    var id: String { rawValue }

    /// Synology's wording, deliberately. Someone coming from Photos should not
    /// have to work out that our "Data Saver" is their "Speed first" — the
    /// choice is the same choice, so it reads the same.
    ///
    /// The case names and their `rawValue`s stay as they were: those are what is
    /// written to preferences, and renaming them would quietly reset the setting
    /// for anyone who had already chosen one.
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .original: return "Quality first"
        case .dataSaver: return "Speed first"
        }
    }

    var detail: String {
        switch self {
        case .auto:
            return "Full quality on Wi-Fi, and a smaller version on cellular so it doesn't stall."
        case .original:
            return "Always the file exactly as recorded. On cellular this may pause to buffer."
        case .dataSaver:
            return "Always the smaller version. Audio is unchanged — only the picture is reduced."
        }
    }
}

/// The toggle, in More.
struct AutoPlayToggle: View {
    @State private var autoPlay = PlaybackSettings.autoPlayNextVideo

    var body: some View {
        Toggle(isOn: $autoPlay) {
            Label("Auto Play Next Video", systemImage: "play.square.stack")
        }
        .onChange(of: autoPlay) { _, new in
            PlaybackSettings.autoPlayNextVideo = new
        }
    }
}

/// The quality picker, beside it.
struct VideoQualityPicker: View {
    @State private var choice = PlaybackSettings.videoQuality

    var body: some View {
        Picker(selection: $choice) {
            ForEach(VideoQualityPreference.allCases) { option in
                Text(option.title).tag(option)
            }
        } label: {
            Label("Playback Quality", systemImage: "slider.horizontal.3")
        }
        .onChange(of: choice) { _, new in
            PlaybackSettings.videoQuality = new
        }

        Text(choice.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
