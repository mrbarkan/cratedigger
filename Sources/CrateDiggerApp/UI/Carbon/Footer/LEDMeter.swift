import SwiftUI

/// Footer spectrum meter — a vertical amber LCD identical in style to the EQ
/// panel (`EQScreen`), but driven live by the FFT bands from the audio tap so
/// the columns move with the music (low → high, left → right). 184×64.
struct LEDMeterPair: View {
    @Environment(\.carbon) private var theme

    /// 0…1 per band, low frequencies first. Smoothed by `MeterDriver`.
    let bands: [Double]

    private let segments = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "waveform")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.ink3)
                Text("VU")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(theme.ink3)
                Spacer(minLength: 0)
                Text("20–20K")
                    .font(CarbonFont.mono(7, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(theme.ink4)
            }

            Spacer(minLength: 0)

            lcd.frame(height: 27)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 184, height: 64)
        .background(ChromeChassis(theme: theme, cornerRadius: 12))
        .accessibilityLabel("Audio spectrum")
    }

    private var lcd: some View {
        HStack(spacing: 1.5) {
            ForEach(bands.indices, id: \.self) { col in
                let lit = Int((min(max(bands[col], 0), 1) * Double(segments)).rounded())
                VStack(spacing: 1.5) {
                    ForEach(0..<segments, id: \.self) { rowFromTop in
                        let seg = segments - rowFromTop      // 6 (top) ... 1 (bottom)
                        let isLit = seg <= lit
                        let isPeak = seg == lit && lit > 0
                        RoundedRectangle(cornerRadius: 0.5, style: .continuous)
                            .fill(segmentColor(lit: isLit, peak: isPeak))
                            .shadow(
                                color: isLit ? Color(hex: 0xFF7A1F).opacity(isPeak ? 0.9 : 0.6) : .clear,
                                radius: isPeak ? 3 : 2
                            )
                    }
                }
            }
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

    private func segmentColor(lit: Bool, peak: Bool) -> Color {
        if peak { return Color(hex: 0xFFD7A0) }
        if lit { return Color(hex: 0xFF7A1F) }
        return Color(hex: 0xFF6A1A, opacity: 0.09)
    }
}

/// The classic horizontal L/R VU bars (segmented amber), offered as an
/// alternative to the vertical spectrum via the "Simple horizontal VU" setting.
struct HorizontalLEDMeter: View {
    @Environment(\.carbon) private var theme
    let leftLevel: Double
    let rightLevel: Double

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
            HorizontalSegmentRow(level: level)
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

private struct HorizontalSegmentRow: View {
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
