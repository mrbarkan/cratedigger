import AppKit
import SwiftUI

/// Borderless, floating window that hosts the mini player over the desktop.
/// Shares the app's `LibraryViewModel`; `onExpand` returns to the full app.
final class MiniPlayerWindowController: NSWindowController {
    init(model: LibraryViewModel, onExpand: @escaping () -> Void) {
        let hosting = NSHostingController(rootView: MiniPlayerView(model: model, onExpand: onExpand))

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.borderless]
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true                 // system shadow follows the rounded panel
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        super.init(window: window)

        // Size to the SwiftUI content (the window's auto-size can be stale at
        // init — which made it land off-screen), then place it top-right.
        let fitting = hosting.view.fittingSize
        let size = (fitting.width > 100 && fitting.height > 100)
            ? fitting : NSSize(width: 272, height: 464)
        window.setContentSize(size)
        positionTopRight()
    }

    /// Default the player to the top-right of the active screen.
    func positionTopRight() {
        guard let window else { return }
        let screen = window.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 24,
                                      y: visible.maxY - size.height - 24))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
