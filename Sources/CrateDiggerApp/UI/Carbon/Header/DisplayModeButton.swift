import SwiftUI

/// Every OLED screen owns one accent color, shared by the annunciator on the
/// glass and the display-toggle light strip so the two always agree. All seven
/// are distinct — the lamp color alone identifies the screen.
extension OLEDView {
    func accent(_ theme: CarbonTheme) -> Color {
        switch self {
        case .nowPlaying: return theme.sun        // yellow
        case .vu:         return theme.cyanGlow   // icy teal
        case .conversion: return theme.orange
        case .scan:       return theme.cyan
        case .remoteSync: return theme.indigo
        case .cdRip:      return theme.red
        case .devices:    return theme.orangeHi   // salmon
        }
    }
}

/// The display toggle: a thin strip of light in a hardware button — no text.
/// Tapping cycles through the visible OLED views; the strip's glow color is the
/// same accent the OLED uses for the active screen (NOW sun, CNVRT orange,
/// SCAN cyan…), so the lamp itself says which screen you're on. Same 28-pt
/// footprint as the VIEW/THEME/EQ buttons below it. Plays .firm on each press.
struct DisplayModeButton: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    private static let cycle: [OLEDView] = [.nowPlaying, .vu, .conversion, .scan, .devices]

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
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(ChromeChassis(theme: theme, cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.carbonHover)
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
        case .vu:         return "RTA"
        case .remoteSync: return "SYNC"
        case .cdRip:      return "CD-RIP"
        case .devices:    return "DEV"
        }
    }

    /// The shared per-screen accent — same color the OLED annunciator lights.
    private var screenColor: Color { model.oledView.accent(theme) }
}

/// Shared glass-chrome treatment used by compact control surfaces.
struct ChromeChassis: View {
    let theme: CarbonTheme
    var cornerRadius: CGFloat = 7

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape
            .fill(theme.metal) // opaque, not Material — see ChassisLayer
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [
                            theme.metalHi.opacity(theme.isDark ? 0.42 : 0.68),
                            theme.metal.opacity(theme.isDark ? 0.34 : 0.46),
                            theme.metalLo.opacity(theme.isDark ? 0.42 : 0.38)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
            .overlay(
                shape.strokeBorder(Color.white.opacity(theme.isDark ? 0.16 : 0.70), lineWidth: 0.7)
            )
            .overlay(
                shape
                    .strokeBorder(Color.black.opacity(theme.isDark ? 0.34 : 0.10), lineWidth: 0.5)
                    .blur(radius: 0.5)
                    .mask(
                        LinearGradient(
                            colors: [Color.clear, Color.black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .shadow(color: Color.black.opacity(theme.isDark ? 0.48 : 0.14), radius: 5, y: 2)
    }
}
