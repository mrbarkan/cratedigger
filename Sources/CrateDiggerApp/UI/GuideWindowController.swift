import AppKit
import SwiftUI

/// Hosts the in-app guide (`CarbonGuideView`) in a resizable window. Chrome
/// follows the app appearance; the content themes itself to match.
final class GuideWindowController: NSWindowController {
    init() {
        let mode = Self.resolvedAppearance()
        let hosting = NSHostingController(rootView: CarbonGuideView(mode: mode))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "CrateDigger Guide"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 660, height: 620))
        window.center()
        window.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
        super.init(window: window)
    }

    private static func resolvedAppearance() -> AppearanceMode {
        let raw = UserDefaults.standard.string(forKey: AppearanceMode.userDefaultsKey)
            ?? AppearanceMode.system.rawValue
        switch AppearanceMode(rawValue: raw) ?? .system {
        case .light: return .light
        case .dark:  return .dark
        case .system:
            let match = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            return match == .darkAqua ? .dark : .light
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
