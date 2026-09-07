import AppKit
import SwiftUI

/// Borderless, floating window that hosts the mini player over the desktop.
/// Shares the app's `LibraryViewModel`; `onExpand` returns to the full app.
final class MiniPlayerWindowController: NSWindowController {
    init(model: LibraryViewModel, onExpand: @escaping () -> Void) {
        // Assigned after `super.init` so the closure can reach `self`.
        var panelChanged: (Bool) -> Void = { _ in }
        let hosting = NSHostingController(rootView: MiniPlayerView(
            model: model,
            onExpand: onExpand,
            onPanelChange: { open in panelChanged(open) }
        ))
        // The controller would otherwise resize the window itself whenever
        // the content's ideal size changed, anchored at the bottom-left like
        // every AppKit resize. One driver only: `fit(panelOpen:)`.
        hosting.sizingOptions = []

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

        window.setContentSize(NSSize(width: MiniPlayerView.width, height: MiniPlayerView.height(panelOpen: false)))
        positionTopRight()

        panelChanged = { [weak self] open in self?.fit(panelOpen: open) }
    }

    /// Animate the window to the height the view says it needs, keeping the
    /// top-left corner where it is. AppKit anchors a resize at the bottom-left,
    /// which would make a drawer that opens *downward* shove the whole player
    /// up the screen instead. The drawer inside follows the moving edge.
    private func fit(panelOpen: Bool) {
        guard let window else { return }
        let height = MiniPlayerView.height(panelOpen: panelOpen)
        let current = window.frame
        guard abs(current.height - height) > 0.5 else { return }
        let frame = NSRect(x: current.minX, y: current.maxY - height, width: MiniPlayerView.width, height: height)
        // Before the window is on screen (the first-run "nothing playing"
        // open) there is nothing to animate.
        window.setFrame(frame, display: true, animate: window.isVisible)
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

/// A borderless window that can still take the keyboard, so Escape closes the
/// panel and Space reaches the transport while the player is in front.
private final class MiniPlayerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
