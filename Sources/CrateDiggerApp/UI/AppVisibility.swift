import AppKit
import Combine

/// Whether any of the app's windows is actually on screen.
///
/// The disc animator and the VU meters exist to move pixels, and they run at
/// 60 and 30 frames a second to do it. With every window occluded — another
/// app full-screen in front, the deck hidden, the Mini Player behind something
/// — those pixels are never drawn, so the timers are pure heat. Both halt on
/// this and pick up where they left off. Playback, metering and the audio tap
/// are untouched: those are about sound, not pixels.
///
/// App-level rather than per-window on purpose. The deck and the Mini Player
/// are separate windows showing the same spinning disc, so either one being
/// visible means the animation still matters, and `NSApplication`'s own
/// occlusion state answers exactly that with one observer instead of one per
/// window.
@MainActor
final class AppVisibility: ObservableObject {
    static let shared = AppVisibility()

    /// True while at least one window is on screen.
    @Published private(set) var isVisible = true

    private var observers: [NSObjectProtocol] = []

    private init() {
        // Both, deliberately. The app-level notification carries the answer we
        // want but fires just before the window state settles, so the
        // window-level one is what confirms it.
        for name in [NSApplication.didChangeOcclusionStateNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            )
        }
        refresh()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func refresh() {
        // Before the first window exists there is nothing to occlude, and
        // `occlusionState` reports "not visible". Latching that would freeze
        // both animators for the whole session, because the change
        // notification that would clear it never comes — nothing changed.
        guard let app = NSApp, !app.windows.isEmpty else {
            if !isVisible { isVisible = true }
            return
        }
        let visible = app.occlusionState.contains(.visible)
        if visible != isVisible { isVisible = visible }
    }
}
