import SwiftUI

/// The moulded **silicone elastomer** finish shared by every transport control:
/// a matte rubber cap with the symbol printed *under* its surface, the way an
/// LED keypad is made. Rubber diffuses light rather than reflecting it, so
/// there is no specular line and no highlight ring — the only edge is the
/// contact shadow where the cap sits in the chassis.
///
/// `lit` puts an LED behind the cap: the glow blooms from the middle and never
/// reaches full saturation at the rim, because the light has rubber to get
/// through.
struct SiliconeCap<S: Shape, Imprint: View>: View {
    @Environment(\.carbon) private var theme
    let shape: S
    var lit: Bool = false
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
                .overlay {
                    if lit {
                        shape.fill(
                            RadialGradient(colors: [theme.orangeHi.opacity(0.92),
                                                    theme.orange.opacity(0.74),
                                                    theme.orangeLo.opacity(0.46)],
                                           center: UnitPoint(x: 0.5, y: 0.42),
                                           startRadius: 1, endRadius: r * 0.94)
                        )
                    }
                }
                // Flat print laid under the surface — no bevel, no engraved lip.
                // A hair of blur is the silicone between it and your eye.
                .overlay {
                    imprint()
                        .foregroundStyle(lit ? Color.black.opacity(0.34) : theme.ink2.opacity(0.82))
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
                .depthShadow(color: Color.black.opacity(theme.isDark ? 0.5 : 0.22), radius: 7, y: 4)
                .shadow(color: theme.orange.opacity(lit ? 0.22 : 0), radius: 11)
        }
    }
}
