import SwiftUI

struct BrandBlock: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        // Brand column: brand-row (name → settings cog + mini-player pip at
        // far right), then four full-width library keys. On the same grid as
        // the switcher column opposite (`HeaderKeyMetrics`): the row clears the
        // traffic lights, and the keys stretch so the last one meets the
        // OLED's bottom edge.
        VStack(alignment: .leading, spacing: HeaderKeyMetrics.rowGap) {
            HStack(spacing: 8) {
                // The brand column is a fixed width, but a theme can set any
                // display face — a wider one wrapped "CrateDigger" onto two
                // lines and pushed the cog and pip out of the row. Scaling down
                // is the right failure: the name stays whole and the row keeps
                // its height. Same contract `KeyButton` already applies to
                // every other themed label, and `BrandLockup` carries it.
                //
                // 11pt is what the shipped face fits beside both pips in a
                // 156pt column. Widening `brandWidth` would buy a step, at the
                // OLED's expense — not worth it for one point.
                BrandLockup(typeSize: 11)
                Spacer(minLength: 0)
                LibButton(style: .pip, title: "", systemImage: "gearshape",
                          tip: "Settings") {
                    // Same route the ⌘, menu item takes — up the responder chain to AppDelegate.
                    NSApp.sendAction(Selector(("showPreferences:")), to: nil, from: nil)
                }
                LibButton(style: .pip, title: "", systemImage: "pip.enter",
                          tip: "Open the mini player") {
                    NotificationCenter.default.post(name: NSNotification.Name("CrateDiggerShowMiniPlayer"), object: nil)
                }
            }
            .frame(height: HeaderKeyMetrics.brandRowHeight)

            VStack(alignment: .leading, spacing: HeaderKeyMetrics.rowGap) {
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
        .padding(.top, HeaderKeyMetrics.topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

/// Small metal-chrome control button. `.wide` fills its column left-aligned
/// and takes the row height the header grid hands it (the 4-row library
/// column); `.pip` is a compact 20pt icon-only chip (the mini-player button on
/// the brand row). When `highlighted` it lights up amber (ADD TO CRATE when a
/// selection is ready).
private enum LibButtonStyle { case normal, wide, pip }

private struct LibButton: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    var style: LibButtonStyle = .normal
    let title: String
    let systemImage: String
    var tip: String? = nil
    var highlighted: Bool = false
    let action: () -> Void

    @State private var spinning = false

    private var height: CGFloat? { style == .wide ? nil : (style == .pip ? 20 : 24) }
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
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(highlighted ? theme.orange : theme.ink2)
            .padding(.horizontal, horizPad)
            .frame(maxWidth: style == .wide ? .infinity : nil,
                   alignment: .leading)
            .frame(height: height)
            .frame(maxHeight: style == .wide ? .infinity : nil)
            // Highlight lights the *label*, not the chassis — the button reads
            // as ready without the whole key turning into a lamp.
            .background(ChromeChassis(theme: theme, cornerRadius: geometry.keyCornerRadius))
        }
        .buttonStyle(.carbonHover)
        .carbonTip(tip ?? title.capitalized)
        .animation(.easeInOut(duration: 0.18), value: highlighted)
    }
}
