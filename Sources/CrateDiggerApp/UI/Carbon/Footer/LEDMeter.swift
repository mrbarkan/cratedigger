import SwiftUI

struct LEDMeterPair: View {
    @Environment(\.carbon) private var theme
    let leftLevel: Double
    let rightLevel: Double

    var body: some View {
        HStack(spacing: 6) {
            channel(label: "L", level: leftLevel)
            channel(label: "R", level: rightLevel)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.black.opacity(theme.isDark ? 0.6 : 0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.white.opacity(theme.isDark ? 0.04 : 0.4), lineWidth: 0.5)
                )
        )
    }

    private func channel(label: String, level: Double) -> some View {
        VStack(spacing: 4) {
            LEDLadder(level: level)
            Text(label)
                .font(CarbonFont.mono(8, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(Color.white.opacity(0.7))
        }
    }
}

private struct LEDLadder: View {
    @Environment(\.carbon) private var theme
    let level: Double
    let segments: Int = 10

    var body: some View {
        VStack(spacing: 1.5) {
            ForEach(0..<segments, id: \.self) { i in
                segment(index: i)
            }
        }
    }

    private func segment(index: Int) -> some View {
        let inverted = (segments - 1) - index
        let threshold = Double(inverted) / Double(segments - 1)
        let isLit = level >= threshold
        let color: Color = {
            if !isLit { return Color.white.opacity(0.10) }
            if inverted == segments - 1 { return theme.orange }
            if inverted >= segments - 4 { return theme.sun }
            return theme.cyan
        }()

        let glow: Color = {
            if !isLit { return .clear }
            if inverted == segments - 1 { return theme.orange.opacity(0.7) }
            if inverted >= segments - 4 { return theme.sun.opacity(0.6) }
            return theme.cyanGlow.opacity(0.6)
        }()

        return RoundedRectangle(cornerRadius: 0.5, style: .continuous)
            .fill(color)
            .frame(width: 10, height: 4)
            .overlay(
                RoundedRectangle(cornerRadius: 0.5, style: .continuous)
                    .stroke(Color.black.opacity(isLit ? 0.0 : 0.5), lineWidth: 0.5)
                    .blendMode(.multiply)
            )
            .shadow(color: glow, radius: 2)
    }
}
