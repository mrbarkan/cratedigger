import SwiftUI

/// Skeuomorphic single-button replacement for the labeled Now / Cnvrt / Scan
/// view-switcher. Tapping cycles through the visible OLED views in order; an
/// LED row underneath shows position. Plays the .firm click on each press.
struct DisplayModeButton: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    private static let cycle: [OLEDView] = [.nowPlaying, .conversion, .scan]

    var body: some View {
        Button(action: cycleToNext) {
            VStack(spacing: 4) {
                topLabel
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

    private var topLabel: some View {
        Text("DISPLAY")
            .font(CarbonFont.mono(7.5, weight: .bold))
            .tracking(2)
            .foregroundStyle(theme.ink3)
    }

    private var screen: some View {
        ZStack {
            // Recessed dark "LCD" panel
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x050504), Color(hex: 0x0E0E0C)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.6), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.5), radius: 1, y: 1)
            Text(currentLabel)
                .font(CarbonFont.mono(11, weight: .bold))
                .tracking(2.4)
                .foregroundStyle(screenColor)
                .shadow(color: screenColor.opacity(0.7), radius: 3)
        }
        .frame(height: 22)
    }

    private var ledStrip: some View {
        HStack(spacing: 5) {
            ForEach(Self.cycle.indices, id: \.self) { index in
                Circle()
                    .fill(model.oledView == Self.cycle[index] ? activeLED : Color.black.opacity(0.35))
                    .frame(width: 5, height: 5)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                    )
                    .shadow(
                        color: model.oledView == Self.cycle[index] ? activeLED.opacity(0.7) : .clear,
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
        }
    }

    private var screenColor: Color {
        switch model.oledView {
        case .conversion: return theme.orange
        case .scan:       return theme.cyan
        default:          return theme.sun
        }
    }

    private var activeLED: Color {
        switch model.oledView {
        case .conversion: return theme.orange
        case .scan:       return theme.cyan
        default:          return theme.sun
        }
    }

    @ViewBuilder
    private var chassis: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
                LinearGradient(
                    colors: theme.isDark
                        ? [Color(hex: 0x4A4A45), Color(hex: 0x1A1A18)]
                        : [theme.chassisHi, theme.chassisLo],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(theme.isDark ? 0.10 : 0.55), lineWidth: 0.6)
            )
            .overlay(
                // Bottom inner shadow for the "raised" feel
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.black.opacity(theme.isDark ? 0.35 : 0.15), lineWidth: 0.5)
                    .blur(radius: 0.5)
                    .mask(
                        LinearGradient(
                            colors: [Color.clear, Color.black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .shadow(color: Color.black.opacity(theme.isDark ? 0.55 : 0.18), radius: 2, y: 1)
    }
}
