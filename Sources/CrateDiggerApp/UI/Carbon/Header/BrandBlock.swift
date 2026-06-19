import SwiftUI

struct BrandBlock: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                BrandMark(size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("CrateDigger")
                        .font(CarbonFont.sans(18, weight: .semibold))
                        .foregroundStyle(theme.ink)
                    Text("CD-01 · Library Mgr.")
                        .font(CarbonFont.mono(8.5, weight: .medium))
                        .tracking(2)
                        .foregroundStyle(theme.ink3)
                        .textCase(.uppercase)
                }
            }
            HStack(spacing: 10) {
                statLabel(value: "\(model.index.allTracks.count)", suffix: "RECS")
                statLabel(value: gigabytesString(bytes: model.index.totalSizeBytes), suffix: nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statLabel(value: String, suffix: String?) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(CarbonFont.mono(8.5, weight: .semibold))
                .foregroundStyle(theme.ink)
            if let suffix {
                Text(suffix)
                    .font(CarbonFont.mono(8.5, weight: .medium))
                    .foregroundStyle(theme.ink3)
            }
        }
        .tracking(1.8)
        .textCase(.uppercase)
    }

    private func gigabytesString(bytes: Int64) -> String {
        guard bytes > 0 else { return "0 GB" }
        let gb = Double(bytes) / 1_000_000_000
        if gb < 1 {
            let mb = Double(bytes) / 1_000_000
            return String(format: "%.1f MB", mb)
        }
        return String(format: "%.1f GB", gb)
    }
}

struct BrandMark: View {
    @Environment(\.carbon) private var theme
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: theme.isDark
                            ? [theme.metalHi, theme.metal, theme.metalLo, theme.chassisDeep]
                            : [.white, theme.chassisHi, theme.well, theme.chassisDeep],
                        center: UnitPoint(x: 0.35, y: 0.30),
                        startRadius: 0,
                        endRadius: size * 0.6
                    )
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.black.opacity(theme.isDark ? 0.4 : 0.12), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(theme.isDark ? 0.5 : 0.12), radius: 2, y: 2)

            Circle()
                .fill(theme.isDark ? Color(hex: 0x050504) : theme.ink)
                .padding(size * 0.13)

            Circle()
                .fill(theme.orange)
                .frame(width: size * 0.13, height: size * 0.13)
                .shadow(color: theme.orange.opacity(theme.isDark ? 0.70 : 0.35), radius: 5)
        }
        .frame(width: size, height: size)
    }
}
