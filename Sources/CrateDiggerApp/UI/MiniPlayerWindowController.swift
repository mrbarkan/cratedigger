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
        positionBottomRight()
    }

    /// Default the player to the bottom-right of the active screen.
    private func positionBottomRight() {
        guard let window, let screen = NSScreen.main else { return }
        let size = window.frame.size
        let visible = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 24,
                                      y: visible.minY + 24))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
