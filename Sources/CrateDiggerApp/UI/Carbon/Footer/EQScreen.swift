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
            .frame(height: 12)   // fixed label-row height: all four footer pods share one text line

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
        SegmentGrid(columns: model.eqGains.map(segmentHeight), segments: segments)
    }
}
