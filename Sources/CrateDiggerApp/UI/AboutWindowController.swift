import AppKit
import SwiftUI

/// Hosts the Carbon About faceplate (`CarbonAboutView`) in a fixed-size window.
/// The window chrome follows the app appearance; the SwiftUI content themes
/// itself via `@AppStorage`, so it tracks light/dark like the rest of the app.
final class AboutWindowController: NSWindowController {
    init() {
        let hosting = NSHostingController(rootView: CarbonAboutView())
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.title = "About CrateDigger"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 500))
        window.center()

        // Match the traffic-light buttons / chrome to the chosen appearance.
        let raw = UserDefaults.standard.string(forKey: AppearanceMode.userDefaultsKey)
            ?? AppearanceMode.system.rawValue
        switch AppearanceMode(rawValue: raw) ?? .system {
        case .light:  window.appearance = NSAppearance(named: .aqua)
        case .dark:   window.appearance = NSAppearance(named: .darkAqua)
        case .system: window.appearance = nil
        }

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
