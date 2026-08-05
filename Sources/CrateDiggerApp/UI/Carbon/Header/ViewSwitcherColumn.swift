import AppKit
import CrateDiggerCore
import SwiftUI

/// Right-hand header column: the DISPLAY screen tile (OLED mode) plus three
/// settings buttons — VIEW / THEME / EQ — each showing a dot indicator row for
/// its current option, mirroring the CrateDigger v6 design.
struct ViewSwitcherColumn: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    @ObservedObject private var themeRegistry = ThemeRegistry.shared
    @State private var appearance: AppearanceMode = ViewSwitcherColumn.currentAppearance()
    @State private var selectedThemeID: String? = PreferencesStore.shared.selectedThemeID

    var body: some View {
        VStack(spacing: 8) {
            DisplayModeButton()

            SwitchButton(
                name: "VIEW",
                dotCount: 2,
                activeIndex: model.showArtworkGallery ? 1 : 0,
                tip: "VIEW — switch the browser between the track list and the artwork gallery."
            ) {
                ClickPlayer.shared.play(.key)
                model.showArtworkGallery.toggle()
            }

            SwitchButton(
                name: "THEME",
                dotCount: 0,
                activeIndex: 0,
                dash: true,
                tip: "THEME — cycle appearance and installed themes. Manage them in CrateDigger ▸ Appearance."
            ) {
                cycleTheme()
            }

            SwitchButton(
                name: "EQ",
                dotCount: EQPreset.allCases.count + 1,   // + the CUSTOM lamp
                activeIndex: eqActiveIndex,
                tip: "EQ — cycle equalizer presets. The last LED lights when the curve is custom-edited."
            ) {
                ClickPlayer.shared.play(.key)
                model.cycleEQPreset()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppearanceMode.didChangeNotification)) { _ in
            appearance = ViewSwitcherColumn.currentAppearance()
        }
        .onReceive(NotificationCenter.default.publisher(for: PreferencesStore.themesDidChange)) { _ in
            selectedThemeID = PreferencesStore.shared.selectedThemeID
        }
    }

    /// EQ dot row position: the active preset, or the trailing CUSTOM lamp when
    /// the editor has dragged the curve away from the preset's shape.
    private var eqActiveIndex: Int {
        if model.eqGains != model.eqPreset.gainCurve() { return EQPreset.allCases.count }
        return EQPreset.allCases.firstIndex(of: model.eqPreset) ?? 0
    }

    /// THEME cycles one flat list — the three appearances, then every installed
    /// theme: dark → light → system → carbon → … → back to dark.
    private static let appearanceOrder: [AppearanceMode] = [.dark, .light, .system]

    /// Current position in that flat cycle (drives the dot row too). A selected
    /// theme that's since been uninstalled falls back to the appearance slot.
    private var themeCycleIndex: Int {
        if let id = selectedThemeID,
           let i = themeRegistry.manifests.firstIndex(where: { $0.id == id }) {
            return Self.appearanceOrder.count + i
        }
        return Self.appearanceOrder.firstIndex(of: appearance) ?? 0
    }

    /// One press = next option, named on the OLED readout. Re-scans the Themes
    /// folder first so a freshly dropped theme joins the cycle without a
    /// separate Refresh.
    private func cycleTheme() {
        themeRegistry.refresh()
        let manifests = themeRegistry.manifests
        let next = (themeCycleIndex + 1) % (Self.appearanceOrder.count + manifests.count)
        if next < Self.appearanceOrder.count {
            let mode = Self.appearanceOrder[next]
            selectAppearance(mode)
            model.showOLEDNotice(mode.menuTitle.uppercased())
        } else {
            let manifest = manifests[next - Self.appearanceOrder.count]
            selectTheme(manifest.id)
            model.showOLEDNotice(manifest.definition.name.uppercased())
        }
    }

    /// Picking an appearance (dark/light/system) clears any installed-theme
    /// override — same as picking "off" on a skin switcher.
    private func selectAppearance(_ mode: AppearanceMode) {
        ClickPlayer.shared.play(.key)
        appearance = mode
        UserDefaults.standard.set(mode.rawValue, forKey: AppearanceMode.userDefaultsKey)
        NotificationCenter.default.post(name: AppearanceMode.didChangeNotification, object: nil)
        PreferencesStore.shared.selectedThemeID = nil
        selectedThemeID = nil
    }

    private func selectTheme(_ id: String) {
        ClickPlayer.shared.play(.key)
        PreferencesStore.shared.selectedThemeID = id
        selectedThemeID = id
    }

    private static func currentAppearance() -> AppearanceMode {
        let raw = UserDefaults.standard.string(forKey: AppearanceMode.userDefaultsKey)
            ?? AppearanceMode.system.rawValue
        return AppearanceMode(rawValue: raw) ?? .system
    }
}

/// A header settings button: left-aligned name + right-aligned dot indicators
/// (or, with `dash`, a dash LED that lights on each press — THEME's cycle has
/// no fixed option count, so the lamp acknowledges the click instead).
private struct SwitchButton: View {
    @Environment(\.carbon) private var theme
    let name: String
    let dotCount: Int
    let activeIndex: Int
    var dash = false
    var tip: String? = nil
    let action: () -> Void

    @State private var dashLit = false

    // The column is a fixed 110pt (`CarbonLayout.viewSwitchWidth`), so the two
    // halves of the button get an explicit share each rather than competing for
    // it. Letting them negotiate produced both failure modes in turn: a lamp row
    // wide enough to push THEME's button past the column, then a budget small
    // enough that "VIEW" and "THEME" truncated to "V…" and "T…".
    //
    //   8 + 42 (label) + 4 (gap) + 44 (lamps) + 8 = 106, inside 110.
    private static let labelWidth: CGFloat = 42
    private static let lampBudget: CGFloat = 44
    private static let horizontalPadding: CGFloat = 8

    /// Lamps shrink to stay inside the budget rather than widening the button.
    private var dotSize: CGFloat {
        guard dotCount > 0 else { return 5 }
        let spacingTotal = dotSpacing * CGFloat(max(0, dotCount - 1))
        return min(5, max(3, (Self.lampBudget - spacingTotal) / CGFloat(dotCount)))
    }

    private var dotSpacing: CGFloat { dotCount > 4 ? 2.5 : 3 }

    /// The lamps sit against the trailing edge of their share, so all three
    /// buttons' indicators line up regardless of what they contain.

    var body: some View {
        Button(action: fire) {
            HStack(spacing: 4) {
                Text(name)
                    .font(CarbonFont.mono(8.5, weight: .bold))
                    .tracking(1.3)
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
                    // Scales down a hair rather than truncating to "T…" if a
                    // label ever outgrows its share.
                    .minimumScaleFactor(0.8)
                    .frame(width: Self.labelWidth, alignment: .leading)
                Spacer(minLength: 0)
                if dotCount > 0 {
                    HStack(spacing: dotSpacing) {
                        ForEach(0..<dotCount, id: \.self) { i in
                            Circle()
                                .fill(i == activeIndex ? theme.orange : theme.ink4.opacity(0.4))
                                .frame(width: dotSize, height: dotSize)
                                .shadow(color: i == activeIndex ? theme.orange.opacity(0.7) : .clear, radius: 2.5)
                        }
                    }
                    .frame(width: Self.lampBudget, alignment: .trailing)
                }
                if dash {
                    Capsule(style: .continuous)
                        .fill(dashLit ? theme.orange : theme.ink4.opacity(0.4))
                        .frame(width: 14, height: 4)
                        .shadow(color: dashLit ? theme.orange.opacity(0.7) : .clear, radius: 3)
                        // Same budget as the lamp rows, so THEME's trailing edge
                        // lines up with VIEW's and EQ's.
                        .frame(width: Self.lampBudget, alignment: .trailing)
                }
            }
            .padding(.horizontal, Self.horizontalPadding)
            .frame(maxWidth: .infinity)
            .frame(height: SwitcherButtonMetrics.height)
            .background(ChromeChassis(theme: theme, cornerRadius: SwitcherButtonMetrics.cornerRadius))
        }
        .buttonStyle(.carbonHover)
        .carbonTip(tip ?? "\(name): tap to change")
    }

    private func fire() {
        if dash {
            dashLit = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.easeOut(duration: 0.4)) { dashLit = false }
            }
        }
        action()
    }
}
