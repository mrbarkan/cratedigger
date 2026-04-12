import AppKit

final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let mainViewController = MainViewController()
    private var layoutMode: WindowLayoutMode = .emptyCompact
    private var hasPromotedToWorkspace = false

    init() {
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WindowLayoutMode.emptyCompact.targetSize),
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
        window.isRestorable = false

        super.init(window: window)

        mainViewController.onFirstLoadedLibrary = { [weak self] in
            self?.promoteToWorkspaceIfNeeded()
        }

        window.delegate = self
        mainViewController.applyWindowLayoutMode(layoutMode)
        applyWindowPlan(context: .initialLaunch, animated: false)
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
        applyWindowPlan(context: .initialLaunch, animated: false)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        applyWindowPlan(context: .clampToVisibleFrame, animated: false)
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        applyWindowPlan(context: .clampToVisibleFrame, animated: false)
    }

    private func promoteToWorkspaceIfNeeded() {
        guard !hasPromotedToWorkspace else { return }
        hasPromotedToWorkspace = true
        layoutMode = .workspace
        mainViewController.applyWindowLayoutMode(.workspace)
        applyWindowPlan(context: .layoutTransition, animated: true)
    }

    private func applyWindowPlan(context: WindowFramePlanningContext, animated: Bool) {
        guard let window else { return }

        let visibleFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let plan = WindowFramePlanner.plan(
            visibleFrame: visibleFrame,
            currentFrame: window.frame,
            mode: layoutMode,
            context: context
        )

        window.minSize = NSSize(width: plan.minimumSize.width, height: plan.minimumSize.height)
        window.setFrame(NSRect(origin: plan.frame.origin, size: plan.frame.size), display: true, animate: animated)
    }
}
