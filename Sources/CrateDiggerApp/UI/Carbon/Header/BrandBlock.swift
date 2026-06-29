import SwiftUI

struct BrandBlock: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                ActivityLight(active: model.isWorking)
                Text("CrateDigger")
                    .font(CarbonFont.sans(18, weight: .semibold))
                    .foregroundStyle(theme.ink)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    LibButton(title: "DIG CRATE", systemImage: "folder",
                              tip: "Dig Crate — scan a folder of audio. New tracks land in the Prep Crate.") { model.openFolderViaPanel() }
                    LibButton(title: "RESCAN", systemImage: "arrow.clockwise",
                              tip: "Rescan — re-read your library folders (or the selected device) to pick up changes.") { model.refreshLibrary() }
                    LibButton(title: "", systemImage: "pip.enter",
                              tip: "Open the mini player") {
                        NotificationCenter.default.post(name: NSNotification.Name("CrateDiggerShowMiniPlayer"), object: nil)
                    }
                }
                HStack(spacing: 8) {
                    LibButton(title: "ADD TO CRATE", systemImage: "tray.and.arrow.down.fill",
                              tip: addToCrateTip, highlighted: canAddToCrate) {
                        model.addSelectionToCrate(crateName: model.targetCrateName)
                    }
                    LibButton(title: "TRANSFER TO", systemImage: "arrow.up.forward.square",
                              tip: "Transfer the current selection to an external device") {
                        model.requestExternalDeviceTransfer()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canAddToCrate: Bool {
        !model.selectedTracksForCrateAdd().isEmpty
    }

    private var addToCrateTip: String {
        let count = model.selectedTracksForCrateAdd().count
        return count == 0
            ? "Select albums or tracks (⌘-click for several), then add them to a crate"
            : "Add \(count) track\(count == 1 ? "" : "s") to \(model.targetCrateName)"
    }
}

/// A small blue "drive access" light: steady-dim when idle, pulsing while the
/// app is scanning or converting.
private struct ActivityLight: View {
    let active: Bool
    @State private var pulsing = false

    private let blue = Color(hex: 0x3BA7FF)

    var body: some View {
        Circle()
            .fill(blue)
            .frame(width: 11, height: 11)
            .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
            .opacity(active ? (pulsing ? 1.0 : 0.4) : 0.5)
            .shadow(color: blue.opacity(active && pulsing ? 0.9 : 0.22),
                    radius: active && pulsing ? 6 : 2)
            .onAppear { syncPulse() }
            .onChange(of: active) { _ in syncPulse() }
            .accessibilityLabel(active ? "Working" : "Idle")
    }

    private func syncPulse() {
        if active {
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { pulsing = true }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { pulsing = false }
        }
    }
}

/// Small metal-chrome control button for the header button group. When
/// `highlighted` it lights up amber (used by ADD TO CRATE when a selection is
/// ready). An empty `title` renders icon-only.
private struct LibButton: View {
    @Environment(\.carbon) private var theme
    let title: String
    let systemImage: String
    var tip: String? = nil
    var highlighted: Bool = false
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
            HStack(spacing: title.isEmpty ? 0 : 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(spinning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: spinning)
                if !title.isEmpty {
                    Text(title)
                        .font(CarbonFont.mono(8, weight: .bold))
                        .tracking(1.4)
                }
            }
            .foregroundStyle(highlighted ? theme.orange : theme.ink2)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                ZStack {
                    ChromeChassis(theme: theme, cornerRadius: 6)
                    if highlighted {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.orange.opacity(0.14))
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(theme.orange.opacity(0.55), lineWidth: 1)
                    }
                }
            )
            .shadow(color: highlighted ? theme.orange.opacity(0.35) : .clear, radius: 5)
        }
        .buttonStyle(.plain)
        .carbonTip(tip ?? title.capitalized)
        .animation(.easeInOut(duration: 0.18), value: highlighted)
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
