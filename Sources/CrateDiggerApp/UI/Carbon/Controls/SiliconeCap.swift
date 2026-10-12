import SwiftUI

/// The moulded **silicone elastomer** finish shared by every transport control:
/// a matte rubber cap with the symbol printed *under* its surface, the way an
/// LED keypad is made. Rubber diffuses light rather than reflecting it, so
/// there is no specular line and no highlight ring — the only edge is the
/// contact shadow where the cap sits in the chassis.
///
/// `lit` puts an LED behind the cap: the glow blooms from the middle and never
/// reaches full saturation at the rim, because the light has rubber to get
/// through. That LED is `transportLamp`, not the accent — a theme can recolour
/// the transport without dragging the meters and the POSITION bar with it.
///
/// The lamp behaves like the console's other lamps: it comes up quickly and
/// dies away a little slower (`CarbonMotion.state` / `.lampOff`), so pausing
/// reads as the light going out rather than a cut. Only light changes, so
/// Reduce Motion leaves it alone.
struct SiliconeCap<S: Shape, Imprint: View>: View {
    @Environment(\.carbon) private var theme
    /// Held down by `SiliconeKeyButtonStyle`: the contact shadow pulls in
    /// under the cap as it sinks into the chassis.
    @Environment(\.siliconeKeyPressed) private var pressed
    let shape: S
    var lit: Bool = false
    /// Scales the contact shadow: 1 is the footer's; the mini player's smaller
    /// caps sit closer to the card and cast less.
    var shadowScale: CGFloat = 1
    @ViewBuilder var imprint: () -> Imprint

    var body: some View {
        GeometryReader { geo in
            let r = max(geo.size.width, geo.size.height) * 0.62

            shape
                .fill(
                    RadialGradient(colors: [theme.metalHi, theme.metal, theme.metalLo],
                                   center: UnitPoint(x: 0.5, y: 0.34),
                                   startRadius: 1, endRadius: r)
                )
                // Always in the tree, faded by opacity, so the LED can warm up
                // and decay instead of popping in and out with the view.
                .overlay {
                    shape.fill(
                        RadialGradient(colors: [theme.transportLampHi.opacity(0.92),
                                                theme.transportLamp.opacity(0.74),
                                                theme.transportLampLo.opacity(0.46)],
                                       center: UnitPoint(x: 0.5, y: 0.42),
                                       startRadius: 1, endRadius: r * 0.94)
                    )
                    .opacity(lit ? 1 : 0)
                }
                // Flat print laid under the surface — no bevel, no engraved lip.
                // A hair of blur is the silicone between it and your eye.
                .overlay {
                    imprint()
                        .foregroundStyle(lit ? Color.black.opacity(0.34) : theme.chassisInk.opacity(0.82))
                        .blur(radius: 0.4)
                }
                // Broad, soft sheen — last, so it passes over the print the way
                // it would over real ink.
                .overlay {
                    shape
                        .fill(LinearGradient(colors: [.white.opacity(theme.isDark ? 0.10 : 0.22), .clear],
                                             startPoint: .top, endPoint: .center))
                        .padding(1)
                }
                .depthShadow(color: Color.black.opacity((theme.isDark ? 0.5 : 0.22) * shadowScale),
                             radius: (pressed ? 4 : 7) * shadowScale,
                             y: (pressed ? 1.5 : 4) * shadowScale)
                .shadow(color: theme.transportLamp.opacity(lit ? 0.22 : 0), radius: 11)
                .animation(lit ? CarbonMotion.state : CarbonMotion.lampOff, value: lit)
                // Rubber is smooth: the console's grain stops at the cap's edge.
                .grainFree(shape: shape)
        }
    }
}

// MARK: - The key around the cap

private struct SiliconeKeyPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the silicone key holding this cap is down. Set by
    /// `SiliconeKeyButtonStyle`; a cap drawn outside one is never pressed.
    var siliconeKeyPressed: Bool {
        get { self[SiliconeKeyPressedKey.self] }
        set { self[SiliconeKeyPressedKey.self] = newValue }
    }
}

/// The transport's button style: `carbonHover`'s brightness, plus the travel a
/// rubber key has. The cap sinks a point and its contact shadow pulls in under
/// it, the way the header's chassis keys go down into their sockets, so the
/// two kinds of key on the console both answer a press with a press.
///
/// Travel is one point at `CarbonMotion.press` speed: feedback, over in a
/// frame or two, so it stays on under Reduce Motion like the chassis keys'.
struct SiliconeKeyButtonStyle: ButtonStyle {
    /// How far a pressed cap sinks: the chassis keys' travel.
    static var travel: CGFloat { ChassisKeyMetrics.travel }

    /// The key's outline, which is also where it takes clicks: the round PLAY
    /// dome must not answer in its frame's square corners.
    var hitShape = AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

    func makeBody(configuration: Configuration) -> some View {
        KeyBody(configuration: configuration, hitShape: hitShape)
    }

    private struct KeyBody: View {
        let configuration: Configuration
        let hitShape: AnyShape
        @Environment(\.carbon) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .environment(\.siliconeKeyPressed, pressed)
                .brightness(brightness(pressed: pressed))
                .offset(y: pressed ? SiliconeKeyButtonStyle.travel : 0)
                // The hit area stays where the key is at rest, so the travel
                // can never walk a release off the key's edge.
                .contentShape(hitShape)
                .animation(CarbonMotion.press, value: pressed)
                .animation(CarbonMotion.hover, value: hovering)
                .onHover { hovering = $0 && isEnabled }
        }

        /// The same lift and dip as `carbonHover`, so swapping a transport key
        /// to this style changes its travel and nothing else.
        private func brightness(pressed: Bool) -> Double {
            if pressed { return theme.isDark ? -0.05 : 0.05 }
            if hovering { return theme.isDark ? 0.09 : -0.06 }
            return 0
        }
    }
}

extension ButtonStyle where Self == SiliconeKeyButtonStyle {
    static var siliconeKey: SiliconeKeyButtonStyle { SiliconeKeyButtonStyle() }

    /// A silicone key whose outline is not the transport caps' rounded square.
    static func siliconeKey<S: Shape>(shape: S) -> SiliconeKeyButtonStyle {
        SiliconeKeyButtonStyle(hitShape: AnyShape(shape))
    }
}
