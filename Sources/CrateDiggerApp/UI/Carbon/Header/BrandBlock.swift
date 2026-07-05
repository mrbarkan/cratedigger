import SwiftUI

struct BrandBlock: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        // v10 brand column: brand-row (name → drive LED → mini-player pip at
        // far right), then a 4-row full-width library-button column.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("CrateDigger")
                    .font(CarbonFont.sans(14, weight: .semibold))
                    .foregroundStyle(theme.ink)
                ActivityLight(active: model.isWorking)
                Spacer(minLength: 0)
                LibButton(style: .pip, title: "", systemImage: "pip.enter",
                          tip: "Open the mini player") {
                    NotificationCenter.default.post(name: NSNotification.Name("CrateDiggerShowMiniPlayer"), object: nil)
                }
            }
            .padding(.top, 7)   // clear the traffic lights

            VStack(alignment: .leading, spacing: 6) {
                LibButton(style: .wide, title: "DIG CRATE", systemImage: "folder",
                          tip: "Dig Crate — scan a folder of audio. New tracks land in the Prep Crate.") { model.openFolderViaPanel() }
                LibButton(style: .wide, title: "RESCAN", systemImage: "arrow.clockwise",
                          tip: "Rescan — re-read your library folders (or the selected device) to pick up changes.") { model.refreshLibrary() }
                LibButton(style: .wide, title: "ADD TO CRATE", systemImage: "tray.and.arrow.down.fill",
                          tip: addToCrateTip, highlighted: canAddToCrate) {
                    model.addSelectionToCrate(crateName: model.targetCrateName)
                }
                LibButton(style: .wide, title: "TRANSFER TO", systemImage: "arrow.up.forward.square",
                          tip: "Transfer the current selection to an external device") {
                    model.requestExternalDeviceTransfer()
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

/// A small blue "drive access" LED: steady-dim when idle; while the app is
/// working it flickers *irregularly* like a real disk-access light — mostly-on
/// with ragged gaps (~70% duty, re-rolled every 40–170ms), snapping hard (0.04s)
/// rather than pulsing on a smooth sine.
private struct ActivityLight: View {
    let active: Bool
    @State private var on = false
    @State private var ticker: Task<Void, Never>? = nil

    private let blue = Color(hex: 0x3BA7FF)

    var body: some View {
        Circle()
            .fill(blue)
            .frame(width: 11, height: 11)
            .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
            // Dark when idle; only lights (and flickers) while the app is working.
            .opacity(active ? (on ? 1.0 : 0.5) : 0.12)
            .shadow(color: (active && on) ? blue.opacity(0.95) : .clear, radius: (active && on) ? 7 : 0)
            .animation(.linear(duration: 0.04), value: on)
            .animation(.easeOut(duration: 0.15), value: active)
            .onAppear { restart() }
            .onChange(of: active) { _ in restart() }
            .onDisappear { ticker?.cancel() }
            .accessibilityLabel(active ? "Disk access" : "Idle")
    }

    private func restart() {
        ticker?.cancel()
        guard active else { on = false; return }
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                on = Double.random(in: 0...1) > 0.3          // ~70% duty
                let ms = 40 + Int.random(in: 0...130)        // 40–170ms
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            }
        }
    }
}

/// Small metal-chrome control button. `.wide` fills its column left-aligned
/// (the 4-row library column); `.pip` is a compact 20pt icon-only chip (the
/// mini-player button on the brand row). When `highlighted` it lights up amber
/// (ADD TO CRATE when a selection is ready).
private enum LibButtonStyle { case normal, wide, pip }

private struct LibButton: View {
    @Environment(\.carbon) private var theme
    var style: LibButtonStyle = .normal
    let title: String
    let systemImage: String
    var tip: String? = nil
    var highlighted: Bool = false
    let action: () -> Void

    @State private var spinning = false

    private var height: CGFloat { style == .pip ? 20 : 24 }
    private var horizPad: CGFloat { style == .pip ? 6 : 9 }

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
            .padding(.horizontal, horizPad)
            .frame(maxWidth: style == .wide ? .infinity : nil,
                   alignment: .leading)
            .frame(height: height)
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
        .buttonStyle(.carbonHover)
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
