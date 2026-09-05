import AppKit
import SwiftUI

/// Borderless, floating window that hosts the mini player over the desktop.
/// Shares the app's `LibraryViewModel`; `onExpand` returns to the full app.
final class MiniPlayerWindowController: NSWindowController {
    init(model: LibraryViewModel, onExpand: @escaping () -> Void) {
        // Assigned after `super.init` so the closure can reach `self`.
        var resize: (CGSize) -> Void = { _ in }
        let hosting = NSHostingController(rootView: MiniPlayerView(
            model: model,
            onExpand: onExpand,
            onSizeChange: { size in resize(size) }
        ))

        let window = MiniPlayerWindow(contentViewController: hosting)
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
        let size = (fitting.width > 100 && fitting.height > 60)
            ? fitting : NSSize(width: 272, height: 168)
        window.setContentSize(size)
        positionTopRight()

        resize = { [weak self] size in self?.fit(to: size) }
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

    /// Follow the content when the panel opens or closes, keeping the top-left
    /// corner where it is. AppKit anchors a resize at the bottom-left, which
    /// would make a panel that opens *downward* shove the whole player up the
    /// screen instead.
    private func fit(to size: CGSize) {
        guard let window, size.width > 0, size.height > 0 else { return }
        let current = window.frame
        guard abs(current.height - size.height) > 0.5 || abs(current.width - size.width) > 0.5 else { return }
        let frame = NSRect(
            x: current.minX,
            y: current.maxY - size.height,
            width: size.width,
            height: size.height
        )
        window.setFrame(frame, display: true, animate: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A borderless window that can still take the keyboard, so Escape closes the
/// panel and Space reaches the transport while the player is in front.
private final class MiniPlayerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
