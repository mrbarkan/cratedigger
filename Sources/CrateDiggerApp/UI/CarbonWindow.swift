import AppKit
import CrateDiggerCore

/// The main window. A `.fullSizeContentView` chassis hides the real title bar, so
/// the header strip loses the one behaviour every Mac window has: double-click to
/// zoom. This puts it back — the header band acts as the title bar, honouring
/// Desktop & Dock → "Double-click a window's title bar to".
final class CarbonWindow: NSWindow {

    /// How far down from the top of the window the header strip reaches: the
    /// chassis top inset plus the header row, per the active theme's geometry.
    private var titleBandHeight: CGFloat {
        let geometry = ThemeRegistry.shared
            .resolvedTheme(for: PreferencesStore.shared.selectedThemeID)?.geometry ?? .standard
        return geometry.chassisInsetV + geometry.headerHeight
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 2, isHeaderBackgroundClick(event) {
            performTitleBarDoubleClickAction()
            return
        }
        super.sendEvent(event)
    }

    /// True when the click landed in the header band *and* on inert chassis rather
    /// than a control — `mouseDownCanMoveWindow` is the same test AppKit uses to
    /// decide whether a drag there moves the window, so buttons keep their clicks.
    private func isHeaderBackgroundClick(_ event: NSEvent) -> Bool {
        let point = event.locationInWindow
        guard frame.height - point.y <= titleBandHeight else { return false }
        // Nothing hit = the titlebar strip itself (traffic lights, status lamp).
        guard let hit = contentView?.hitTest(point) else { return true }
        return hit.mouseDownCanMoveWindow
    }

    private func performTitleBarDoubleClickAction() {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": performMiniaturize(nil)
        case "None":     break
        default:         zoom(nil)      // unset = Zoom, the system default
        }
    }
}
