import SwiftUI

/// Footer EQ — a monochrome amber LCD (12 columns × 6 segments) showing the
/// current cosmetic `eqPreset` shape (CrateDigger v6 `.eq` panel).
struct EQScreen: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    private let segments = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.ink3)
                Text("EQ")
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
        .contentShape(Rectangle())
        .onTapGesture { model.showingEQEditor = true }
        .carbonTip("Open the equalizer")
        .accessibilityLabel("Equalizer — click to edit")
    }

    /// Map a band gain (dB, −12…+12) to lit-segment height (0…6, 3 = 0 dB).
    private func segmentHeight(_ gainDB: Double) -> Int {
        min(max(Int((((gainDB + 12) / 24) * Double(segments)).rounded()), 0), segments)
    }

    private var lcd: some View {
        let bands = model.eqGains.map(segmentHeight)
        return HStack(spacing: 1.5) {
            ForEach(bands.indices, id: \.self) { col in
                VStack(spacing: 1.5) {
                    ForEach(0..<segments, id: \.self) { rowFromTop in
                        let seg = segments - rowFromTop      // 6 (top) ... 1 (bottom)
                        let lit = seg <= bands[col]
                        let isPeak = seg == bands[col]
                        RoundedRectangle(cornerRadius: 0.5, style: .continuous)
                            .fill(segmentColor(lit: lit, peak: isPeak))
                            .shadow(
                                color: lit ? Color(hex: 0xFF7A1F).opacity(isPeak ? 0.9 : 0.6) : .clear,
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
