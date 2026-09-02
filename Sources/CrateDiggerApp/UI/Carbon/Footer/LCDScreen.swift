import SwiftUI

/// Shared anatomy for the three footer LCDs (EQ, spectrum VU, L/R VU).
///
/// Their lit segments run the **same cyan → meter-high ramp as the VOLUME
/// fader**, so every lit element in the footer comes from one palette. The
/// high end is `meterHot`, the accent unless a theme says otherwise, so a
/// theme with a black accent keeps meters that light up. The well itself
/// stays a near-black hardware LCD (like
/// the patch-bay steel: a material, not a theme colour) with a faint wash of
/// the theme's cyan so it still shifts between themes.
enum LCDScreen {
    /// Low → high across the meter's own axis, matching the fader's travel.
    static func ramp(_ theme: CarbonTheme, opacity: Double = 1) -> Gradient {
        Gradient(colors: [theme.cyan.opacity(opacity), theme.meterHot.opacity(opacity)])
    }

    /// The brightened ramp used for the leading/peak segment.
    static func peakRamp(_ theme: CarbonTheme) -> Gradient {
        Gradient(colors: [theme.cyanGlow, theme.meterHotHi])
    }

    /// Shading for a segment path inside a Canvas of `size`. `vertical` ramps
    /// bottom→top (spectrum, EQ); otherwise left→right (L/R bars).
    static func shading(_ gradient: Gradient, size: CGSize, vertical: Bool) -> GraphicsContext.Shading {
        .linearGradient(
            gradient,
            startPoint: vertical ? CGPoint(x: 0, y: size.height) : .zero,
            endPoint: vertical ? .zero : CGPoint(x: size.width, y: 0)
        )
    }

    /// The recessed well every LCD sits in.
    static func well(_ theme: CarbonTheme) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return shape
            .fill(
                RadialGradient(
                    colors: [Color(hex: 0x0F1A1E), Color(hex: 0x080F12), Color(hex: 0x04080A)],
                    center: .center, startRadius: 2, endRadius: 90
                )
            )
            .overlay(shape.fill(theme.cyan.opacity(0.05)))
            .overlay(shape.stroke(Color.black.opacity(0.65), lineWidth: 1))
            .overlay(shape.stroke(theme.cyan.opacity(0.12), lineWidth: 0.5).blur(radius: 0.5))
    }
}

/// The 12 × 6 segment grid shared by the EQ panel and the spectrum VU: one
/// Canvas draw per pass instead of 72 diffed shape views, with each column's
/// lit height given in segments.
struct SegmentGrid: View {
    @Environment(\.carbon) private var theme
    /// Lit segment count per column, low frequencies first.
    let columns: [Int]
    var segments: Int = 6

    var body: some View {
        Canvas { context, size in
            guard !columns.isEmpty else { return }
            let gap = 1.5
            let cellW = (size.width - CGFloat(columns.count - 1) * gap) / CGFloat(columns.count)
            let cellH = (size.height - CGFloat(segments - 1) * gap) / CGFloat(segments)

            var unlit = Path()
            var litBody = Path()
            var peak = Path()
            for (col, lit) in columns.enumerated() {
                for rowFromTop in 0..<segments {
                    let seg = segments - rowFromTop      // 6 (top) ... 1 (bottom)
                    let rect = CGRect(x: CGFloat(col) * (cellW + gap),
                                      y: CGFloat(rowFromTop) * (cellH + gap),
                                      width: cellW, height: cellH)
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

            context.fill(unlit, with: LCDScreen.shading(LCDScreen.ramp(theme, opacity: 0.10),
                                                        size: size, vertical: true))
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: theme.meterHot.opacity(0.5), radius: 2))
                layer.fill(litBody, with: LCDScreen.shading(LCDScreen.ramp(theme),
                                                            size: size, vertical: true))
            }
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: theme.meterHot.opacity(0.8), radius: 3))
                layer.fill(peak, with: LCDScreen.shading(LCDScreen.peakRamp(theme),
                                                         size: size, vertical: true))
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(LCDScreen.well(theme))
    }
}
