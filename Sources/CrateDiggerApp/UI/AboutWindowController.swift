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
    private let designedByLabel = NSTextField(labelWithString: "Designed by Mr.Barkan")
    private let developedByLabel = NSTextField(labelWithString: "Developed By Codex")
    private let supportButton = NSButton(title: "Buy Me a Coffee", target: nil, action: nil)

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = ModernRetroTheme.surfaceBase.cgColor

        titleLabel.font = NSFont.systemFont(ofSize: 28, weight: .semibold)
        designedByLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        developedByLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        titleLabel.textColor = ModernRetroTheme.textPrimary
        designedByLabel.textColor = ModernRetroTheme.textSecondary
        developedByLabel.textColor = ModernRetroTheme.textSecondary

        supportButton.target = self
        supportButton.action = #selector(openPatreon)
        ModernRetroTheme.styleSecondaryButton(supportButton)

        let stack = NSStackView(views: [titleLabel, designedByLabel, developedByLabel, supportButton])
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
        ModernRetroTheme.updateButtonLayers(supportButton)
    }

    @objc private func openPatreon() {
        guard let url = URL(string: "https://patreon.com/imnot_here") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
