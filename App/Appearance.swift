import SwiftUI

/// Light, dark, or whatever the device is set to.
///
/// Dark by default, and that's a decision about photographs rather than about
/// taste: a light chrome throws its own brightness at everything next to it, and
/// on a wall of thumbnails the eye reads the interface before it reads the
/// pictures. Both reference apps land on dark for the same reason. The system
/// option is here because some people genuinely want their whole device to
/// match, and taking that away is not an improvement.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Match Device"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// `nil` hands the decision back to the system — which is what lets "Match
    /// Device" follow a sunset switch without the app knowing anything about it.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    static let `default`: AppAppearance = .dark

    /// One key, read by the app that applies it and by the row that sets it.
    static let storageKey = "appearance"
}

/// The picker, wherever settings are shown.
///
/// Its own view because three platforms present it in three different places
/// and none of them should be re-deriving the labels.
struct AppearancePicker: View {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.default

    var body: some View {
        Picker(selection: $appearance) {
            ForEach(AppAppearance.allCases) { option in
                Label(option.title, systemImage: option.symbol).tag(option)
            }
        } label: {
            Label("Appearance", systemImage: appearance.symbol)
        }
    }
}
