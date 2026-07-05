import SwiftUI

/// Single-button replacement for the labeled Now / Cnvrt / Scan view-switcher.
/// Tapping cycles through the visible OLED views in order; an LED row
/// underneath shows position. Plays the .firm click on each press.
struct DisplayModeButton: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    private static let cycle: [OLEDView] = [.nowPlaying, .conversion, .scan, .devices]

    var body: some View {
        Button(action: cycleToNext) {
            VStack(spacing: 5) {
                screen
                ledStrip
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(chassis)
        }
        .buttonStyle(.plain)
    }

    private func cycleToNext() {
        ClickPlayer.shared.play(.firm)
        let cycle = Self.cycle
        let current = cycle.firstIndex(of: model.oledView) ?? 0
        let next = cycle[(current + 1) % cycle.count]
        model.oledView = next
    }

    private var screen: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.well) // opaque, not Material — see ChassisLayer
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(theme.isDark ? 0.06 : 0.42),
                                    theme.well.opacity(theme.isDark ? 0.24 : 0.34)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(theme.isDark ? 0.12 : 0.62), lineWidth: 0.6)
                )
            HStack(spacing: 6) {
                Circle()
                    .fill(screenColor)
                    .frame(width: 5, height: 5)
                    .shadow(color: screenColor.opacity(0.55), radius: 4)
                Text(currentLabel)
                    .font(CarbonFont.mono(10.5, weight: .bold))
                    .tracking(2.2)
                    .foregroundStyle(screenColor)
            }
        }
        .frame(height: 24)
    }

    private var ledStrip: some View {
        HStack(spacing: 5) {
            ForEach(Self.cycle.indices, id: \.self) { index in
                Circle()
                    .fill(model.oledView == Self.cycle[index] ? screenColor : theme.ink4.opacity(0.32))
                    .frame(width: 5, height: 5)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                    )
                    .shadow(
                        color: model.oledView == Self.cycle[index] ? screenColor.opacity(0.7) : .clear,
                        radius: 3
                    )
            }
        }
        .padding(.bottom, 1)
    }

    private var currentLabel: String {
        switch model.oledView {
        case .nowPlaying: return "NOW"
        case .conversion: return "CNVRT"
        case .scan:       return "SCAN"
        case .vu:         return "VU"
        case .remoteSync: return "SYNC"
        case .cdRip:      return "CD-RIP"
        case .devices:    return "DEV"
        }
    }

    private var screenColor: Color {
        switch model.oledView {
        case .conversion: return theme.orange
        case .scan:       return theme.cyan
        case .remoteSync: return theme.indigo
        case .cdRip:      return theme.orange
        case .devices:    return theme.cyan
        default:          return theme.sun
        }
    }

    @ViewBuilder
    private var chassis: some View {
        ChromeChassis(theme: theme, cornerRadius: 7)
    }
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
