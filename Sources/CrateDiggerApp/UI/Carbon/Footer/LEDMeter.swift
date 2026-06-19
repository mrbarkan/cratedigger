import SwiftUI

struct LEDMeterPair: View {
    @Environment(\.carbon) private var theme
    let leftLevel: Double
    let rightLevel: Double

    var body: some View {
        VStack(spacing: 6) {
            channel(label: "L", level: leftLevel)
            channel(label: "R", level: rightLevel)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 88)
        .background(ChromeChassis(theme: theme, cornerRadius: 10))
    }

    private func channel(label: String, level: Double) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(CarbonFont.mono(8, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(theme.ink3)
                .frame(width: 8, alignment: .leading)
            LevelBar(level: level)
        }
    }
}

private struct LevelBar: View {
    @Environment(\.carbon) private var theme
    let level: Double

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(theme.isDark ? 0.34 : 0.10))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [theme.cyan, theme.sun, theme.orange],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width * min(max(level, 0), 1))
                    .shadow(color: theme.cyanGlow.opacity(theme.isDark ? 0.36 : 0.18), radius: 4)
            }
        }
        .frame(height: 6)
    }
}
