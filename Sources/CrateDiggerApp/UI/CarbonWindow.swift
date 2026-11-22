import AppKit

/// What a double-click on the window's titlebar strip should do: the pure
/// half of `CarbonWindow`, so the decision is tested without a window.
enum TitlebarDoubleClick {
    enum Action: Equatable {
        case zoom
        case minimize
        case nothing
    }

    /// The `NSGlobalDomain` key behind Desktop & Dock ▸ "Double-click a
    /// window's title bar to".
    static let settingKey = "AppleActionOnDoubleClick"

    /// Maps the system setting onto an action. Unset is the system default,
    /// and "Maximize" and "Fill" both mean the biggest window, which is zoom
    /// here: zoom is what expands the compact player (`windowShouldZoom`).
    /// An unknown value zooms too, so a future option never reads as "off".
    static func action(forSetting setting: String?) -> Action {
        switch setting {
        case "Minimize": return .minimize
        case "None": return .nothing
        default: return .zoom
        }
    }

    /// True when a click at `pointY` (window coordinates, origin at the
    /// bottom) lands in the titlebar strip: the band above
    /// `contentLayoutMaxY`, the strip the traffic lights sit in.
    static func isInTitlebarStrip(pointY: CGFloat, windowHeight: CGFloat, contentLayoutMaxY: CGFloat) -> Bool {
        contentLayoutMaxY < windowHeight && pointY >= contentLayoutMaxY && pointY <= windowHeight
    }
}

/// The main window. Its content is full-size, so the SwiftUI hosting view
/// lies under the titlebar strip, and on macOS 27 a double-click there is
/// delivered to that view and goes nowhere (measured on 27.2: the click
/// arrives with `clickCount == 2`, AppKit never zooms and
/// `windowShouldZoom` is never asked). This gives the strip its
/// double-click back, honouring the Desktop & Dock setting.
///
/// Only the real titlebar strip counts, not the whole header band: an
/// earlier version covered the header and zoomed the window when a header
/// key was pressed twice.
final class CarbonWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 2, isTitlebarBackgroundClick(event) {
            performTitlebarDoubleClickAction()
            return
        }
        super.sendEvent(event)
    }

    /// True when the click landed in the titlebar strip and on something
    /// that would drag the window, not on a control. The traffic lights, the
    /// status LED and anything behind a `WindowDragGuard` answer false to
    /// `mouseDownCanMoveWindow` and keep their clicks.
    private func isTitlebarBackgroundClick(_ event: NSEvent) -> Bool {
        let point = event.locationInWindow
        guard TitlebarDoubleClick.isInTitlebarStrip(
            pointY: point.y, windowHeight: frame.height, contentLayoutMaxY: contentLayoutRect.maxY
        ) else { return false }
        // Hit-tested from the frame view, so titlebar views are included.
        guard let frameView = contentView?.superview,
              let hit = frameView.hitTest(frameView.convert(point, from: nil)) else { return true }
        return hit.mouseDownCanMoveWindow
    }

    private func performTitlebarDoubleClickAction() {
        let setting = UserDefaults.standard.string(forKey: TitlebarDoubleClick.settingKey)
        switch TitlebarDoubleClick.action(forSetting: setting) {
        case .zoom: zoom(nil)
        case .minimize: miniaturize(nil)
        case .nothing: break
        }
    }
}
