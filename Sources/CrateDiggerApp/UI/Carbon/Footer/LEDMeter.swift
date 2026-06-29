import SwiftUI

/// Footer VU-meter panel — a monochrome amber LCD matching the EQ panel
/// (`EQScreen`): header + L/R **segmented** level rows on a recessed brown LCD,
/// plus a dB tick scale. Sized to the other footer panels (184×64).
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

            lcd

            scale
                .padding(.leading, 13)
                .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 184, height: 64)
        .background(ChromeChassis(theme: theme, cornerRadius: 12))
    }

    // The recessed LCD well: same brown radial gradient + amber rim as the EQ.
    private var lcd: some View {
        VStack(spacing: 3) {
            channel(label: "L", level: leftLevel)
            channel(label: "R", level: rightLevel)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [Color(hex: 0x2C1502), Color(hex: 0x170A01), Color(hex: 0x0D0500)],
                        center: .center,
                        startRadius: 2,
                        endRadius: 90
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.black.opacity(0.65), lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color(hex: 0xFF7A1F).opacity(0.10), lineWidth: 0.5)
                        .blur(radius: 0.5)
                )
        )
    }

    private func channel(label: String, level: Double) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(CarbonFont.mono(6.5, weight: .bold))
                .foregroundStyle(Color(hex: 0xFF7A1F).opacity(0.85))
                .frame(width: 6, alignment: .leading)
            SegmentRow(level: level)
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

/// One channel's level as a horizontal row of lit/unlit amber segments — the
/// VU equivalent of EQScreen's vertical bars. Brightest cell marks the peak.
private struct SegmentRow: View {
    let level: Double
    private let segments = 14

    var body: some View {
        let clamped = min(max(level, 0), 1)
        let litCount = Int((clamped * Double(segments)).rounded())
        return HStack(spacing: 1.5) {
            ForEach(0..<segments, id: \.self) { i in
                let lit = i < litCount
                let isPeak = lit && i == litCount - 1
                RoundedRectangle(cornerRadius: 0.5, style: .continuous)
                    .fill(segmentColor(lit: lit, peak: isPeak))
                    .frame(maxWidth: .infinity)
                    .shadow(
                        color: lit ? Color(hex: 0xFF7A1F).opacity(isPeak ? 0.9 : 0.6) : .clear,
                        radius: isPeak ? 3 : 2
                    )
            }
        }
        .frame(height: 5)
    }

    private func segmentColor(lit: Bool, peak: Bool) -> Color {
        if peak { return Color(hex: 0xFFD7A0) }
        if lit { return Color(hex: 0xFF7A1F) }
        return Color(hex: 0xFF6A1A, opacity: 0.09)
    }
}
