import SwiftUI

struct BrandBlock: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        // Brand column: the name alone on the brand row, then a 2 × 4 grid of
        // icon keys. On the same grid as the switcher column opposite
        // (`HeaderKeyMetrics`): the row clears the traffic lights, and the
        // grid's four rows line up with that column's four keys, the last one
        // meeting the OLED's bottom edge.
        VStack(alignment: .leading, spacing: HeaderKeyMetrics.rowGap) {
            // The name gets the whole row. A theme can set any display face,
            // and a wide one could not share 156pt with keys even scaled down;
            // with the row to itself, scaling (`BrandLockup`'s contract) is
            // only ever a last resort.
            BrandLockup(typeSize: 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: HeaderKeyMetrics.brandRowHeight)

            // Icon-only, so every key carries its name in the tooltip and to
            // VoiceOver. Each column is one group read top to bottom, and it is
            // built column by column so VoiceOver reads it that way too. Left,
            // the library: the four wide keys this grid replaced, in their old
            // order, so a hand that knew them still finds them. Right, the
            // player and the app, most used first, Settings in the corner.
            // Every key fills its cell, so the two columns split the height
            // into the same four rows and stay level with each other.
            HStack(spacing: HeaderKeyMetrics.rowGap) {
                VStack(spacing: HeaderKeyMetrics.rowGap) {
                    LibButton(name: "Dig Crate", systemImage: "folder",
                              tip: "Dig Crate — scan a folder of audio. New tracks land in the Prep Crate.") {
                        model.openFolderViaPanel()
                    }
                    LibButton(name: "Rescan", systemImage: "arrow.clockwise", spinsOnPress: true,
                              tip: "Rescan — re-read your library folders (or the selected device) to pick up changes.") {
                        model.refreshLibrary()
                    }
                    LibButton(name: "Add to Crate", systemImage: "tray.and.arrow.down.fill",
                              tip: addToCrateTip, highlighted: canAddToCrate) {
                        model.addSelectionToCrate(crateName: model.targetCrateName)
                    }
                    LibButton(name: "Transfer To", systemImage: "arrow.up.forward.square",
                              tip: "Transfer the current selection to an external device") {
                        model.requestExternalDeviceTransfer()
                    }
                }
                VStack(spacing: HeaderKeyMetrics.rowGap) {
                    LibButton(name: "Go to Current Song", systemImage: "scope",
                              tip: "Go to Current Song (⌘L)") {
                        model.revealNowPlaying()
                    }
                    // The key style dims the legend; the key itself stays put.
                    .disabled(model.nowPlayingTrack == nil)
                    // rectangle.compress here, rectangle.expand on the compact
                    // player's art column: one switch, two ends.
                    LibButton(name: "Compact Player", systemImage: "rectangle.compress.vertical",
                              tip: "Compact player (⌥⇧⌘M)") {
                        // Same route as the menu item, so the window comes forward
                        // and the full-screen refusal applies.
                        NSApp.sendAction(Selector(("toggleCompactPlayer:")), to: nil, from: nil)
                    }
                    LibButton(name: "Mini Player", systemImage: "pip.enter", tip: "Mini player (⇧⌘M)") {
                        NotificationCenter.default.post(name: NSNotification.Name("CrateDiggerShowMiniPlayer"), object: nil)
                    }
                    LibButton(name: "Settings", systemImage: "gearshape", tip: "Settings (⌘,)") {
                        // Same route the ⌘, menu item takes — up the responder chain to AppDelegate.
                        NSApp.sendAction(Selector(("showPreferences:")), to: nil, from: nil)
                    }
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

/// An icon-only chassis key (`ChassisKeyButtonStyle`) that fills the grid cell
/// it is given. When
/// `highlighted` its icon lights up amber (ADD TO CRATE when a selection is
/// ready).
private struct LibButton: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    /// The key's name, for VoiceOver; the tooltip says more.
    let name: String
    let systemImage: String
    /// One turn of the icon on press (RESCAN).
    var spinsOnPress = false
    let tip: String
    var highlighted = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whole turns made so far. Counting up rather than flipping a flag means
    /// every press turns the icon forward once more: the old flag version ran
    /// a repeating spin, then on release animated 360 back to 0 and so
    /// unwound the arrow backwards.
    @State private var turns = 0

    /// One turn that picks up speed and coasts to a stop, like the record on
    /// the deck, rather than a constant-speed spin that starts and stops dead.
    /// Long enough to read as one deliberate turn, short enough to be over
    /// before the rescan it acknowledges has got going.
    private static let spinTurn: Animation = .easeInOut(duration: 0.7)

    var body: some View {
        Button(action: {
            ClickPlayer.shared.play(.key)
            // A turn is motion, so Reduce Motion skips it; the click and the
            // status LED still say the rescan started.
            if spinsOnPress, !reduceMotion { turns += 1 }
            action()
        }) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .rotationEffect(.degrees(Double(turns) * 360))
                // Keyed here, on the icon, rather than with `withAnimation`:
                // the key style's own press animation wraps this label, and
                // the release lands in the same update as the turn, so only
                // an animation inside it is sure to win.
                .animation(Self.spinTurn, value: turns)
                .foregroundStyle(highlighted ? theme.orange : theme.chassisInk)
                // A lit legend glows a little, like the lamps on the switcher
                // keys opposite. Emission, not depth, so a flat theme keeps it.
                .shadow(color: highlighted ? theme.orange.opacity(0.45) : .clear, radius: 3)
                // The legend is a lamp: quick to light, slower to die away.
                // Inside the key style for the same reason as the turn.
                .animation(highlighted ? CarbonMotion.state : CarbonMotion.lampOff, value: highlighted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Highlight lights the icon, not the chassis — the key reads
                // as ready without the whole key turning into a lamp.
                .contentShape(Rectangle())
        }
        .buttonStyle(.chassisKey)
        .carbonTip(tip)
        .accessibilityLabel(name)
    }
}
