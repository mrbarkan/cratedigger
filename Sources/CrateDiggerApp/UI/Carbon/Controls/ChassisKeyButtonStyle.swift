import SwiftUI

/// The header's hardware keys: a chrome cap seated in a socket cut into the
/// chassis. The socket stays put; on press the cap travels into it, its
/// front face (`ChromeChassis`'s skirt) disappears below the rim and its
/// contact shadow collapses, so a click reads as a key going down rather than
/// a tile changing shade. Hover brightens, as `carbonHover` does.
///
/// The label sizes the key (the header grid hands its labels the whole cell);
/// the style only draws around it, so a fixed-size key stays fixed.
struct ChassisKeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        KeyBody(configuration: configuration)
    }

    private struct KeyBody: View {
        let configuration: Configuration
        @Environment(\.carbon) private var theme
        @Environment(\.carbonGeometry) private var geometry
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                // A disabled key is still a key: its legend dims, its cap and
                // socket stay solid. Fading the whole thing let the socket show
                // through the cap and turned it into a ghost.
                .opacity(isEnabled ? 1 : 0.38)
                .background(ChromeChassis(theme: theme, cornerRadius: geometry.keyCornerRadius,
                                          skirt: ChassisKeyMetrics.skirt, pressed: pressed))
                .brightness(brightness(pressed: pressed))
                .offset(y: pressed ? ChassisKeyMetrics.travel : 0)
                .padding(ChassisKeyMetrics.seat)
                .background(KeySocket(theme: theme, cornerRadius: geometry.keyCornerRadius + ChassisKeyMetrics.seat))
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.07), value: pressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 && isEnabled }
        }

        private func brightness(pressed: Bool) -> Double {
            if pressed { return theme.isDark ? -0.04 : -0.03 }
            if hovering { return theme.isDark ? 0.07 : 0.03 }
            return 0
        }
    }
}

enum ChassisKeyMetrics {
    /// The socket's lip around the cap.
    static let seat: CGFloat = 1.5
    /// The cap's front face, which a press pushes down into the socket.
    static let skirt: CGFloat = 2
    /// How far a pressed cap sinks.
    static let travel: CGFloat = 1
}

extension ButtonStyle where Self == ChassisKeyButtonStyle {
    static var chassisKey: ChassisKeyButtonStyle { ChassisKeyButtonStyle() }
}

/// The cut-out a key sits in, lit from above like the rest of the console:
/// its upper wall is in shadow (darker fill at the top, an inner shadow under
/// the top edge) and the panel's edge just below the cut catches the light.
/// That asymmetry is what makes it read as a hole rather than as an outline
/// drawn round the cap; a ring of one even colour reads as a border.
struct KeySocket: View {
    let theme: CarbonTheme
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(
                LinearGradient(
                    colors: [
                        theme.chassisLo.opacity(theme.isDark ? 1 : 0.95),
                        theme.chassisLo.opacity(theme.isDark ? 0.55 : 0.35)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            // Inner shadow along the top: a blurred stroke pushed down and
            // clipped to the recess.
            .overlay(
                shape
                    .stroke(Color.black.opacity(theme.isDark ? 0.5 : 0.28), lineWidth: 1.5)
                    .blur(radius: 1)
                    .offset(y: 0.75)
                    .mask(shape)
            )
            // The lit edge of the cut: a hairline of light peeking out below
            // the socket, on the panel rather than inside the hole, so the
            // cap's own contact shadow can't swallow it.
            .background(
                shape
                    .fill(Color.white.opacity(theme.isDark ? 0.11 : 0.95))
                    .offset(y: 0.5)
            )
    }
}
