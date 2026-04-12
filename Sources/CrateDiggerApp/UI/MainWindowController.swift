import AppKit

final class MainWindowController: NSWindowController, NSWindowDelegate {
    private enum WindowLayout {
        static let preferredFrameSize = NSSize(width: 1240, height: 780)
        static let minimumFrameSize = NSSize(width: 940, height: 620)
        static let screenMargin: CGFloat = 28
        static let preferredInset: CGFloat = 56
    }

    private let mainViewController = MainViewController()

    init() {
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WindowLayout.preferredFrameSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        window.title = "CrateDigger"
        window.contentViewController = mainViewController
        window.backgroundColor = ModernRetroTheme.surfaceBase
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true

        super.init(window: window)

        window.delegate = self
        applyResponsiveSizing(centered: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func openFolder() {
        mainViewController.openFolder()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        applyResponsiveSizing(centered: false)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        applyResponsiveSizing(centered: false)
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        applyResponsiveSizing(centered: false)
    }

    private func applyResponsiveSizing(centered: Bool) {
        guard let window else { return }

        let visibleFrame = Self.visibleFrame(for: window)
        let maxFrameSize = NSSize(
            width: max(WindowLayout.minimumFrameSize.width, visibleFrame.width - (WindowLayout.screenMargin * 2)),
            height: max(WindowLayout.minimumFrameSize.height, visibleFrame.height - (WindowLayout.screenMargin * 2))
        )

        let adaptiveMinSize = NSSize(
            width: min(WindowLayout.minimumFrameSize.width, max(760, visibleFrame.width - (WindowLayout.screenMargin * 2))),
            height: min(WindowLayout.minimumFrameSize.height, max(540, visibleFrame.height - (WindowLayout.screenMargin * 2)))
        )
        window.minSize = adaptiveMinSize

        var frame = window.frame
        let preferredWidth = min(WindowLayout.preferredFrameSize.width, max(WindowLayout.minimumFrameSize.width, visibleFrame.width - (WindowLayout.preferredInset * 2)))
        let preferredHeight = min(WindowLayout.preferredFrameSize.height, max(WindowLayout.minimumFrameSize.height, visibleFrame.height - (WindowLayout.preferredInset * 2)))

        frame.size.width = min(max(frame.width, adaptiveMinSize.width), maxFrameSize.width)
        frame.size.height = min(max(frame.height, adaptiveMinSize.height), maxFrameSize.height)

        if centered && (frame.width > preferredWidth || frame.height > preferredHeight) {
            frame.size = NSSize(width: preferredWidth, height: preferredHeight)
        }

        frame.origin = Self.clampedOrigin(for: frame, in: visibleFrame, centered: centered)
        window.setFrame(frame, display: true, animate: false)
    }

    private static func visibleFrame(for window: NSWindow) -> NSRect {
        window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private static func clampedOrigin(for frame: NSRect, in visibleFrame: NSRect, centered: Bool) -> NSPoint {
        if centered {
            return NSPoint(
                x: visibleFrame.midX - (frame.width / 2),
                y: visibleFrame.midY - (frame.height / 2)
            )
        }

        let maxX = visibleFrame.maxX - frame.width
        let maxY = visibleFrame.maxY - frame.height
        return NSPoint(
            x: min(max(frame.origin.x, visibleFrame.minX), maxX),
            y: min(max(frame.origin.y, visibleFrame.minY), maxY)
        )
    }
}
