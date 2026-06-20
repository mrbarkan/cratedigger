import SwiftUI

/// Footer VU-meter panel (CrateDigger v6 `.meterpair`): header + L/R level bars
/// + a dB tick scale, sized to match the other footer panels (184×64).
struct LEDMeterPair: View {
    @Environment(\.carbon) private var theme
    let leftLevel: Double
    let rightLevel: Double

    // dB ticks and their horizontal position (0...1) along the bar.
    private static let ticks: [(label: String, pos: Double, zero: Bool)] = [
        ("-20", 0.03, false), ("-12", 0.25, false), ("-6", 0.46, false),
        ("-3", 0.63, false), ("0", 0.80, true), ("+3", 0.98, false)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "waveform")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.ink3)
                Text("VU METER")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(theme.ink3)
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 3) {
                channel(label: "L", level: leftLevel)
                channel(label: "R", level: rightLevel)
            }

            scale
                .padding(.leading, 13)
                .padding(.top, 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 184, height: 64)
        .background(ChromeChassis(theme: theme, cornerRadius: 12))
    }

    private func channel(label: String, level: Double) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(CarbonFont.mono(7.5, weight: .bold))
                .foregroundStyle(theme.ink3)
                .frame(width: 7, alignment: .leading)
            LevelBar(level: level)
        }
    }

    private var scale: some View {
        GeometryReader { proxy in
            let w = max(proxy.size.width, 1)
            ForEach(Self.ticks.indices, id: \.self) { i in
                let t = Self.ticks[i]
                VStack(spacing: 1) {
                    Rectangle()
                        .fill((t.zero ? theme.orange : theme.ink4).opacity(t.zero ? 0.9 : 0.6))
                        .frame(width: 1, height: 2)
                    Text(t.label)
                        .font(CarbonFont.mono(6.5, weight: .bold))
                        .foregroundStyle(t.zero ? theme.orange : theme.ink4)
                        .fixedSize()
                }
                .position(x: t.pos * w, y: 5)
            }
        }
        .frame(height: 10)
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
        .frame(height: 5)
    }
}
