import SwiftUI

/// Every OLED screen owns one lamp color, shared by the annunciator on the
/// glass and the display-toggle light strip so the two always agree. All are
/// distinct — the lamp color alone identifies the screen.
///
/// Each is a theme token of its own (`lampNow`, `lampConvert`, …) that falls
/// back to the accent it has always borrowed, so a theme can recolor one lamp
/// without dragging every other use of that accent along with it.
extension OLEDView {
    func accent(_ theme: CarbonTheme) -> Color {
        switch self {
        case .nowPlaying: return theme.lampNow        // yellow
        case .conversion: return theme.lampConvert
        case .scan:       return theme.lampScan
        case .remoteSync: return theme.lampSync
        case .dub:      return theme.lampCD
        case .devices:    return theme.lampDevices    // salmon
        case .search:     return theme.lampSearch     // teal glow
        case .stats:      return theme.lampStats
        }
    }
}

/// One grid for both header columns: a brand row on top, then the keys, each
/// column filling the header so its last key lands on the OLED's bottom edge.
/// The keys take the height that leaves — the same in both columns, since
/// both stack the same rows — so the library keys and the switcher keys read
/// as identical physical parts, and a theme's `headerHeight` scales them.
enum HeaderKeyMetrics {
    /// Clears the traffic lights, which sit on the brand column's top edge.
    static let topInset: CGFloat = 18
    static let brandRowHeight: CGFloat = 20
    static let rowGap: CGFloat = 6
}

/// The display toggle: a thin strip of light in a hardware button — no text.
/// Tapping cycles through the visible OLED views; the strip's glow color is the
/// same accent the OLED uses for the active screen (NOW sun, CNVRT orange,
/// SCAN cyan…), so the lamp itself says which screen you're on. Same footprint
/// as the VIEW/THEME/EQ buttons below it. Plays .firm on each press.
struct DisplayModeButton: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    @EnvironmentObject private var model: LibraryViewModel

    static let cycle: [OLEDView] = [.nowPlaying, .conversion, .scan, .dub, .devices, .stats]

    var body: some View {
        Button(action: cycleToNext) {
            Capsule(style: .continuous)
                .fill(screenColor)
                .frame(height: 5)
                .shadow(color: screenColor.opacity(0.75), radius: 4)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.black.opacity(theme.isDark ? 0.5 : 0.15), lineWidth: 0.5)
                )
                // The strip is a lamp in the key, not a segment on the glass:
                // it changes colour at lamp speed while the OLED beside it
                // snaps to the new screen.
                .animation(CarbonMotion.state, value: model.oledView)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.chassisKey)
        .carbonTip("DISPLAY — \(currentLabel). Click to cycle the OLED screen; the strip glows in the active screen's color.")
    }

    private func cycleToNext() {
        ClickPlayer.shared.play(.firm)
        let cycle = Self.cycle
        let current = cycle.firstIndex(of: model.oledView) ?? 0
        model.oledView = cycle[(current + 1) % cycle.count]
    }

    private var currentLabel: String {
        switch model.oledView {
        case .nowPlaying: return "NOW"
        case .conversion: return "CNVRT"
        case .scan:       return "SCAN"
        case .remoteSync: return "SYNC"
        case .dub:      return "DUB"
        case .devices:    return "DEV"
        case .search:     return "SRCH"
        case .stats:      return "STATS"
        }
    }

    /// The shared per-screen accent — same color the OLED annunciator lights.
    private var screenColor: Color { model.oledView.accent(theme) }
}

/// Shared glass-chrome treatment used by compact control surfaces.
///
/// A cap lit from above: brighter at the top, a highlight on the top edge and
/// shade on the bottom one, and a tight contact shadow that says it rests on
/// the surface. (A wide soft drop shadow, which this used to cast, reads as
/// a tile hovering over the panel.)
///
/// `skirt` and `pressed` are for `ChassisKeyButtonStyle`. The skirt is the
/// cap's front face, a darker band along the bottom under a lit top edge:
/// it is what gives a key height, where a gradient alone gives a tile. A
/// pressed cap is down in its socket, so the skirt hides, the shadow
/// collapses and the top light dims. Both default to the flat chip the
/// other callers draw.
struct ChromeChassis: View {
    let theme: CarbonTheme
    var cornerRadius: CGFloat = 7
    var skirt: CGFloat = 0
    var pressed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape
            .fill(theme.metal) // opaque, not Material — see ChassisLayer
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [
                            theme.metalHi.opacity(theme.isDark ? (pressed ? 0.24 : 0.40) : (pressed ? 0.45 : 0.70)),
                            theme.metal.opacity(theme.isDark ? 0.30 : 0.40),
                            theme.metalLo.opacity(theme.isDark ? 0.46 : 0.42)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            )
            .overlay {
                if skirt > 0 {
                    skirtBand(shape)
                }
            }
            // Top edge catches the light.
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(theme.isDark ? 0.20 : (pressed ? 0.55 : 0.90)), .clear],
                        startPoint: .top,
                        endPoint: .center
                    ),
                    lineWidth: 0.8
                )
            )
            // Bottom edge falls into shade.
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.clear, Color.black.opacity(theme.isDark ? 0.45 : 0.16)],
                        startPoint: .center,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
            )
            .depthShadow(
                color: Color.black.opacity(theme.isDark ? 0.55 : (pressed ? 0.10 : 0.20)),
                radius: pressed ? 0.3 : 0.8,
                y: pressed ? 0.3 : 1
            )
    }

    /// The front face: the bottom `skirt` points of the cap, shaded, with a
    /// hairline of light where the top face turns down into it.
    private func skirtBand(_ shape: RoundedRectangle) -> some View {
        let depth = pressed ? skirt * 0.25 : skirt
        return ZStack {
            shape
                .fill(theme.metalLo.opacity(theme.isDark ? 0.8 : 0.32))
                .mask(alignment: .bottom) {
                    Rectangle().frame(height: depth)
                }
            shape
                .fill(Color.white.opacity(theme.isDark ? 0.10 : 0.55))
                .mask(alignment: .bottom) {
                    Rectangle().frame(height: 0.5).padding(.bottom, depth)
                }
        }
    }
}
