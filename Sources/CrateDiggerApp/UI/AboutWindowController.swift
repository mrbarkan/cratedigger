import AppKit
import SwiftUI

/// Hosts the Carbon About faceplate (`CarbonAboutView`) in a fixed-size window.
/// The window chrome follows the app appearance; the SwiftUI content themes
/// itself via `@AppStorage`, so it tracks light/dark like the rest of the app.
final class AboutWindowController: NSWindowController {
    init() {
        // Resolve to a concrete light/dark so the SwiftUI theme and the window
        // materials agree (see CarbonAboutView.mode).
        let mode = AppearanceMode.currentConcrete
        let hosting = NSHostingController(rootView: CarbonAboutView(mode: mode))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.title = "About CrateDigger"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // Wide enough that the footer's links and credits share one line: the
        // credits never truncate, so anything narrower pushes the link onto a
        // second row.
        window.setContentSize(NSSize(width: 800, height: 470))
        window.center()
        window.appearance = mode.nsAppearance

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
