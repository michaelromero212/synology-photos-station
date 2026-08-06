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

/// The app icon, drawn rather than imported.
///
/// The sign-in screen used a bare `square.on.square` tinted with `.tint` — and
/// with no AccentColor asset that resolved to system blue on iOS and to
/// whatever the user had set on macOS. So the first thing anyone saw after
/// tapping a red icon was a blue mark on a plain background: the same app,
/// twice, in two liveries.
///
/// Redrawn here from the same three colours `Scripts/GenerateIcon.swift` uses
/// for the plate, so the sign-in screen reads as the icon enlarged. Drawn in
/// SwiftUI rather than shipped as a PNG so it stays crisp at any size and picks
/// up the same shape the system will mask.
struct AppMark: View {
    var size: CGFloat = 88

    /// Matches the icon's gradient. Changing one without the other is the
    /// drift this view exists to prevent — see the palette in GenerateIcon.
    private static let plate = LinearGradient(
        colors: [
            Color(.sRGB, red: 74 / 255, green: 12 / 255, blue: 24 / 255),
            Color(.sRGB, red: 214 / 255, green: 40 / 255, blue: 57 / 255),
            Color(.sRGB, red: 247 / 255, green: 96 / 255, blue: 92 / 255),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(Self.plate)
            .frame(width: size, height: size)
            .overlay {
                // Two offset frames, the same mark the icon carries: a photo
                // behind a photo, which is what a library is.
                ZStack {
                    frame(scale: 0.46).offset(x: -size * 0.07, y: -size * 0.07)
                    frame(scale: 0.46)
                        .offset(x: size * 0.07, y: size * 0.07)
                        .background(
                            RoundedRectangle(cornerRadius: size * 0.07, style: .continuous)
                                .fill(.white.opacity(0.14))
                                .frame(width: size * 0.46, height: size * 0.46)
                                .offset(x: size * 0.07, y: size * 0.07)
                        )
                }
            }
            .shadow(color: .black.opacity(0.28), radius: size * 0.09, y: size * 0.04)
            .accessibilityLabel("FrameStation")
    }

    private func frame(scale: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.07, style: .continuous)
            .strokeBorder(.white.opacity(0.92), lineWidth: max(size * 0.028, 1))
            .frame(width: size * scale, height: size * scale)
    }
}
