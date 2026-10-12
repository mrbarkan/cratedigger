import SwiftUI

/// The Carbon replacement for `.plain`: identical layout and hit-testing, plus
/// universal mouse-over feedback so every control reads as clickable — a small
/// backlight lift on hover (direction flips with the theme so it shows on both
/// dark chassis and light linen) and a press dip.
///
/// Works on any label — LED keys, text links, icon tiles — because it only
/// adjusts brightness; controls with richer bespoke hover states simply
/// compose with it.
struct CarbonHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        @Environment(\.carbon) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .brightness(brightness)
                // The lift follows the cursor. The press dip is not animated:
                // an animation keyed on `isPressed` here would wrap the whole
                // label, so whatever a click changes on release (a row's
                // selection, a tab's lamp) would ride the 0.07 s press curve
                // instead of its own.
                .animation(CarbonMotion.hover, value: hovering)
                .onHover { hovering = $0 && isEnabled }
        }

        private var brightness: Double {
            if configuration.isPressed { return theme.isDark ? -0.05 : 0.05 }
            if hovering { return theme.isDark ? 0.09 : -0.06 }
            return 0
        }
    }
}

extension ButtonStyle where Self == CarbonHoverButtonStyle {
    static var carbonHover: CarbonHoverButtonStyle { CarbonHoverButtonStyle() }
}
