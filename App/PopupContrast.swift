#if os(iOS)
import SwiftUI
import UIKit

/// Menus, confirmation dialogs and alerts in the system's high-contrast style,
/// and everything else as the system has it.
///
/// The app is dark, and a dark menu is translucent: over a bright photo it
/// turns the photo's gray. The viewer's More menu over a white frame measured
/// 3.9 to 1, white text on (129, 126, 119), under the 4.5 text needs. Photos
/// measures exactly the same in dark mode over the same photo; it reads well in
/// the screenshot of it this was compared with because there it opens over
/// black, at 9 to 12. A
/// menu can't be given a background from SwiftUI, and darkening the screen
/// behind one hardly moves it, because the material evens out what's under
/// it: dimmed 35%, 4.0; dimmed 60%, 5.7, with the whole photo gone murky.
///
/// The high-contrast style is the one setting that does: a solid dark platter,
/// 8.6 to 1 over the same white frame, 9.0 for a dialog's title. It's what
/// Settings › Accessibility › Increase Contrast turns on. Menus and dialogs take
/// it from the *window*, not from the button that opened them (raised on the
/// button's own view controller, the menu didn't change), so the window gets
/// it, and the app's own screens are put back on the system's setting under it.
/// The bars and buttons drawn over photographs stay glass; only what pops up
/// changes.
///
/// A presented screen takes the window's style rather than its presenter's:
/// sheets come out slightly crisper, which is in the spirit of this, while a
/// full-screen photo page or a sheet that opens the viewer would turn its glass
/// solid black — those put themselves back with `standardContrast()`.
@MainActor
enum PopupContrast {
    /// What the person has asked for: high with Increase Contrast on, normal
    /// otherwise. Never overridden for them.
    static var system: UIAccessibilityContrast {
        UIAccessibility.isDarkerSystemColorsEnabled ? .high : .normal
    }

    static func install(on window: UIWindow) {
        window.traitOverrides.accessibilityContrast = .high
        window.rootViewController?.traitOverrides.accessibilityContrast = system
    }
}

extension View {
    /// Gives this window's popups the high-contrast style. Once, at the root of
    /// each window. See `PopupContrast`.
    func popupContrast() -> some View {
        background(ContrastAnchor(role: .window).allowsHitTesting(false))
    }

    /// Puts a presented screen with glass on it back on the system's contrast,
    /// so its glass looks as it does everywhere else. Popups opened from it
    /// keep the high-contrast style. At the root of the presented content.
    func standardContrast() -> some View {
        background(ContrastAnchor(role: .presentedScreen).allowsHitTesting(false))
    }
}

/// A view with no size whose only job is to reach the window, or the view
/// controller, it ends up in. SwiftUI offers no way to set a UIKit trait
/// override, so this sets it from inside.
private struct ContrastAnchor: UIViewRepresentable {
    enum Role { case window, presentedScreen }
    let role: Role

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.role = role
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) {}

    final class AnchorView: UIView {
        var role = Role.window
        private var observer: NSObjectProtocol?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            apply()
            // Increase Contrast switched on or off while the app is open.
            if observer == nil {
                observer = NotificationCenter.default.addObserver(
                    forName: UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        private func apply() {
            guard let window else { return }
            switch role {
            case .window:
                PopupContrast.install(on: window)
            case .presentedScreen:
                owningController?.traitOverrides.accessibilityContrast = PopupContrast.system
            }
        }

        /// The view controller this view is drawn by: for the root of a sheet
        /// or a full-screen cover, the one presenting its content.
        private var owningController: UIViewController? {
            var responder = next
            while let current = responder {
                if let controller = current as? UIViewController { return controller }
                responder = current.next
            }
            return nil
        }
    }
}
#endif
