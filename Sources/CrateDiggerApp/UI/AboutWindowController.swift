import AppKit

final class AboutWindowController: NSWindowController {
    init() {
        let viewController = AboutViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About CrateDigger"
        window.isReleasedWhenClosed = false
        window.contentViewController = viewController

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class AboutViewController: NSViewController {
    private let titleLabel = NSTextField(labelWithString: "CrateDigger")
    private let taglineLabel = NSTextField(labelWithString: "Scan, inspect, preview, and convert music libraries.")
    private let creditsLabel = NSTextField(labelWithString: "Built with Swift, AppKit, and FFmpeg tooling.")
    private let versionLabel = NSTextField(labelWithString: "")

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = ModernRetroTheme.surfaceBase.cgColor

        titleLabel.font = NSFont.systemFont(ofSize: 28, weight: .semibold)
        taglineLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        creditsLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        versionLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = ModernRetroTheme.textPrimary
        taglineLabel.textColor = ModernRetroTheme.textPrimary
        creditsLabel.textColor = ModernRetroTheme.textSecondary
        versionLabel.textColor = ModernRetroTheme.textSecondary
        versionLabel.stringValue = versionString()

        let stack = NSStackView(views: [titleLabel, taglineLabel, creditsLabel, versionLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
    }

    private func versionString() -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(version) (\(build))"
    }
}
