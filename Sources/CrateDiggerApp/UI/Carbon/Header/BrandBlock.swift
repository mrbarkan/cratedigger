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
            HStack(spacing: 6) {
                LibButton(title: "LOAD FOLDER", systemImage: "folder") { model.openFolderViaPanel() }
                LibButton(title: "RESCAN", systemImage: "arrow.clockwise") { model.refreshLibrary() }
            }
            .padding(.top, 1)
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

/// Small metal-chrome control button shown under the brand stats
/// (Load Folder / Rescan) — mirrors the v6 `.lib-btn` row.
private struct LibButton: View {
    @Environment(\.carbon) private var theme
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var spinning = false

    var body: some View {
        Button(action: {
            ClickPlayer.shared.play(.key)
            if systemImage == "arrow.clockwise" {
                spinning = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { spinning = false }
            }
            action()
        }) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(spinning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: spinning)
                Text(title)
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1.4)
            }
            .foregroundStyle(theme.ink2)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(ChromeChassis(theme: theme, cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(title.capitalized)
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
