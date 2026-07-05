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

    // Canvas, not 72 diffed shape views: a meter pass is one draw-command emit,
    // so per-frame cost no longer scales with how busy the music is.
    private var lcd: some View {
        Canvas { context, size in
            let cols = bands.count
            guard cols > 0 else { return }
            let gap = 1.5
            let cellW = (size.width - CGFloat(cols - 1) * gap) / CGFloat(cols)
            let cellH = (size.height - CGFloat(segments - 1) * gap) / CGFloat(segments)

            var unlit = Path()
            var litBody = Path()
            var peak = Path()
            for col in 0..<cols {
                let lit = Int((min(max(bands[col], 0), 1) * Double(segments)).rounded())
                for rowFromTop in 0..<segments {
                    let seg = segments - rowFromTop      // 6 (top) ... 1 (bottom)
                    let rect = CGRect(
                        x: CGFloat(col) * (cellW + gap),
                        y: CGFloat(rowFromTop) * (cellH + gap),
                        width: cellW, height: cellH
                    )
                    let cell = Path(roundedRect: rect, cornerRadius: 0.5, style: .continuous)
                    if seg == lit, lit > 0 {
                        peak.addPath(cell)
                    } else if seg <= lit {
                        litBody.addPath(cell)
                    } else {
                        unlit.addPath(cell)
                    }
                }
            }

            context.fill(unlit, with: .color(segmentColor(lit: false, peak: false)))
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: Color(hex: 0xFF7A1F).opacity(0.6), radius: 2))
                layer.fill(litBody, with: .color(segmentColor(lit: true, peak: false)))
            }
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: Color(hex: 0xFF7A1F).opacity(0.9), radius: 3))
                layer.fill(peak, with: .color(segmentColor(lit: true, peak: true)))
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

/// The classic L/R VU bars — the SAME amber-LCD design as the vertical spectrum
/// (`LEDMeterPair`), just two **horizontal** bars (L and R levels) on the same
/// recessed brown LCD. Toggled via the "Simple horizontal VU" setting or by
/// clicking the meter.
struct HorizontalLEDMeter: View {
    @Environment(\.carbon) private var theme
    let leftLevel: Double
    let rightLevel: Double

    private let segments = 18

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
                Text("L / R")
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
        .accessibilityLabel("Stereo VU meter")
    }

    private var lcd: some View {
        VStack(spacing: 4) {
            bar(label: "L", level: leftLevel)
            bar(label: "R", level: rightLevel)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [Color(hex: 0x2C1502), Color(hex: 0x170A01), Color(hex: 0x0D0500)],
                        center: .center, startRadius: 2, endRadius: 90
                    )
                )
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.black.opacity(0.65), lineWidth: 1))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color(hex: 0xFF7A1F).opacity(0.10), lineWidth: 0.5).blur(radius: 0.5))
        )
    }

    // Canvas for the same reason as LEDMeterPair.lcd: one draw per pass
    // instead of 18 diffed shape views per bar.
    private func bar(label: String, level: Double) -> some View {
        let lit = Int((min(max(level, 0), 1) * Double(segments)).rounded())
        return HStack(spacing: 5) {
            Text(label)
                .font(CarbonFont.mono(6.5, weight: .bold))
                .foregroundStyle(Color(hex: 0xFF7A1F).opacity(0.85))
                .frame(width: 6, alignment: .leading)
            Canvas { context, size in
                let gap = 1.5
                let cellW = (size.width - CGFloat(segments - 1) * gap) / CGFloat(segments)
                var unlit = Path()
                var litBody = Path()
                var peak = Path()
                for i in 0..<segments {
                    let rect = CGRect(x: CGFloat(i) * (cellW + gap), y: 0,
                                      width: cellW, height: size.height)
                    let cell = Path(roundedRect: rect, cornerRadius: 0.5, style: .continuous)
                    if i < lit {
                        if i == lit - 1 { peak.addPath(cell) } else { litBody.addPath(cell) }
                    } else {
                        unlit.addPath(cell)
                    }
                }
                context.fill(unlit, with: .color(segmentColor(lit: false, peak: false)))
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: Color(hex: 0xFF7A1F).opacity(0.6), radius: 2))
                    layer.fill(litBody, with: .color(segmentColor(lit: true, peak: false)))
                }
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: Color(hex: 0xFF7A1F).opacity(0.9), radius: 3))
                    layer.fill(peak, with: .color(segmentColor(lit: true, peak: true)))
                }
            }
        }
    }

    private func segmentColor(lit: Bool, peak: Bool) -> Color {
        if peak { return Color(hex: 0xFFD7A0) }
        if lit { return Color(hex: 0xFF7A1F) }
        return Color(hex: 0xFF6A1A, opacity: 0.09)
    }
}
