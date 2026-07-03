import AppKit
import SwiftUI

/// Hosts the launch splash (`SplashView`) in a small borderless, transparent
/// window floated above the main window while it comes up. The app delegate
/// shows it first thing in `applicationDidFinishLaunching`, then schedules
/// `fadeOutAndClose` for a fixed branding hold (`SplashView.displayDuration`)
/// — the fade is a timed cover, not a readiness signal; the main window keeps
/// loading underneath it either way.
final class SplashWindowController: NSWindowController {
    init() {
        let mode = AppearanceMode.currentConcrete
        let hosting = NSHostingController(rootView: SplashView(mode: mode))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.borderless]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.setContentSize(NSSize(width: 520, height: 340))
        window.center()
        window.appearance = mode.nsAppearance
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// After `delay`, fade the splash out over the main window and order it out.
    func fadeOutAndClose(after delay: TimeInterval, completion: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let window = self.window else {
                completion()
                return
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.45
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 0
            }, completionHandler: {
                window.orderOut(nil)
                completion()
            })
        }
    }
}
