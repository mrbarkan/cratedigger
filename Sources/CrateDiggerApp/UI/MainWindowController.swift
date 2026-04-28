import AppKit

final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let hostingController = CarbonHostingController()

    init() {
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WindowLayoutMode.workspace.targetSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        window.title = "CrateDigger"
        window.contentViewController = hostingController
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.isRestorable = false

        super.init(window: window)

        window.delegate = self
        applyAppearancePreference()
        applyWindowPlan(context: .initialLaunch, animated: false)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppearanceDidChange),
            name: AppearanceMode.didChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func openFolder() {
        // TODO(Phase 4): forward to LibraryViewModel.openFolder() once the view-model is wired in.
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

    @objc private func handleAppearanceDidChange() {
        applyAppearancePreference()
    }

    private func applyAppearancePreference() {
        guard let window else { return }
        let raw = UserDefaults.standard.string(forKey: AppearanceMode.userDefaultsKey)
        let mode = AppearanceMode(rawValue: raw ?? AppearanceMode.system.rawValue) ?? .system
        switch mode {
        case .light: window.appearance = NSAppearance(named: .aqua)
        case .dark:  window.appearance = NSAppearance(named: .darkAqua)
        case .system: window.appearance = nil
        }
    }

    private func applyWindowPlan(context: WindowFramePlanningContext, animated: Bool) {
        guard let window else { return }

        let visibleFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let plan = WindowFramePlanner.plan(
            visibleFrame: visibleFrame,
            currentFrame: window.frame,
            mode: .workspace,
            context: context
        )

        window.minSize = NSSize(width: plan.minimumSize.width, height: plan.minimumSize.height)
        window.setFrame(NSRect(origin: plan.frame.origin, size: plan.frame.size), display: true, animate: animated)
    }
}
