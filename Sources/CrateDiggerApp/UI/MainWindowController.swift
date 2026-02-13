import AppKit

final class MainWindowController: NSWindowController {
    private let mainViewController = MainViewController()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "CrateDigger"
        window.minSize = NSSize(width: 980, height: 620)
        window.contentViewController = mainViewController
        window.center()
        window.backgroundColor = ModernRetroTheme.surfaceBase
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func openFolder() {
        mainViewController.openFolder()
    }
}
