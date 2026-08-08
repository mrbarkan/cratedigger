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
            .frame(height: 12)   // fixed label-row height: all four footer pods share one text line

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
        SegmentGrid(
            columns: bands.map { Int((min(max($0, 0), 1) * Double(segments)).rounded()) },
            segments: segments
        )
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
            .frame(height: 12)   // fixed label-row height: all four footer pods share one text line

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
        .background(LCDScreen.well(theme))
    }

    // Canvas for the same reason as LEDMeterPair.lcd: one draw per pass
    // instead of 18 diffed shape views per bar.
    private func bar(label: String, level: Double) -> some View {
        let lit = Int((min(max(level, 0), 1) * Double(segments)).rounded())
        return HStack(spacing: 5) {
            Text(label)
                .font(CarbonFont.mono(6.5, weight: .bold))
                .foregroundStyle(theme.cyan.opacity(0.85))
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
                // Horizontal bars ramp left→right, exactly like the VOLUME fader.
                context.fill(unlit, with: LCDScreen.shading(LCDScreen.ramp(theme, opacity: 0.10),
                                                            size: size, vertical: false))
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: theme.orange.opacity(0.5), radius: 2))
                    layer.fill(litBody, with: LCDScreen.shading(LCDScreen.ramp(theme),
                                                                size: size, vertical: false))
                }
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: theme.orange.opacity(0.8), radius: 3))
                    layer.fill(peak, with: LCDScreen.shading(LCDScreen.peakRamp(theme),
                                                             size: size, vertical: false))
                }
            }
        }
    }
}
