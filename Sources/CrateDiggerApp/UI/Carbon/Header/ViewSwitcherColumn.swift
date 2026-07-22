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

            ThemeSwitchButton(
                appearance: appearance,
                selectedThemeID: selectedThemeID,
                manifests: themeRegistry.manifests,
                onSelectAppearance: selectAppearance,
                onSelectTheme: selectTheme,
                onRefresh: { themeRegistry.refresh() },
                onShowThemesFolder: showThemesFolderInFinder
            )

            SwitchButton(
                name: "EQ",
                dotCount: EQPreset.allCases.count,
                activeIndex: EQPreset.allCases.firstIndex(of: model.eqPreset) ?? 0,
                tip: "EQ — choose an equalizer preset."
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

    private func showThemesFolderInFinder() {
        guard let url = themeRegistry.userThemesDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func currentAppearance() -> AppearanceMode {
        let raw = UserDefaults.standard.string(forKey: AppearanceMode.userDefaultsKey)
            ?? AppearanceMode.system.rawValue
        return AppearanceMode(rawValue: raw) ?? .system
    }
}

/// A header settings button: left-aligned name + right-aligned dot indicators.
private struct SwitchButton: View {
    @Environment(\.carbon) private var theme
    let name: String
    let dotCount: Int
    let activeIndex: Int
    var tip: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(name)
                    .font(CarbonFont.mono(8.5, weight: .bold))
                    .tracking(1.3)
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    ForEach(0..<dotCount, id: \.self) { i in
                        Circle()
                            .fill(i == activeIndex ? theme.orange : theme.ink4.opacity(0.4))
                            .frame(width: 5, height: 5)
                            .shadow(color: i == activeIndex ? theme.orange.opacity(0.7) : .clear, radius: 2.5)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(ChromeChassis(theme: theme, cornerRadius: 6))
        }
        .buttonStyle(.carbonHover)
        .carbonTip(tip ?? "\(name): tap to change")
    }
}

/// The THEME button: same footprint as `SwitchButton`, but opens a menu
/// listing the three built-in appearances plus every installed theme
/// (bundled + dropped into the Themes folder), instead of just cycling.
/// Picking a specific theme shows a single lit dot ("custom skin active");
/// picking an appearance shows the familiar dark·light·auto three dots.
private struct ThemeSwitchButton: View {
    @Environment(\.carbon) private var theme
    let appearance: AppearanceMode
    let selectedThemeID: String?
    let manifests: [ThemeManifest]
    let onSelectAppearance: (AppearanceMode) -> Void
    let onSelectTheme: (String) -> Void
    let onRefresh: () -> Void
    let onShowThemesFolder: () -> Void

    private static let appearanceOrder: [AppearanceMode] = [.dark, .light, .system]

    var body: some View {
        Menu {
            ForEach(Self.appearanceOrder, id: \.self) { mode in
                Button {
                    onSelectAppearance(mode)
                } label: {
                    if selectedThemeID == nil && mode == appearance {
                        Label(mode.menuTitle, systemImage: "checkmark")
                    } else {
                        Text(mode.menuTitle)
                    }
                }
            }

            if !manifests.isEmpty {
                Divider()
                ForEach(manifests) { manifest in
                    Button {
                        onSelectTheme(manifest.id)
                    } label: {
                        if selectedThemeID == manifest.id {
                            Label(manifest.definition.name, systemImage: "checkmark")
                        } else {
                            Text(manifest.definition.name)
                        }
                    }
                }
            }

            Divider()
            Button("Refresh Themes", action: onRefresh)
            Button("Show Themes Folder…", action: onShowThemesFolder)
        } label: {
            // Deliberately empty: macOS flattens Menu labels (backgrounds and
            // frames get dropped — the "THEME became plain text" regression),
            // so the hardware chrome is drawn by the SwitchButton UNDER this
            // transparent menu, via the background below.
            Color.clear.contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(height: 28)
        .background(
            SwitchButton(
                name: "THEME",
                dotCount: dotCount,
                activeIndex: activeIndex,
                action: {}
            )
            .allowsHitTesting(false)   // clicks belong to the Menu on top
        )
        .carbonTip("THEME — pick an appearance, or an installed theme.")
    }

    private var dotCount: Int {
        selectedThemeID == nil ? Self.appearanceOrder.count : 1
    }

    private var activeIndex: Int {
        guard selectedThemeID == nil else { return 0 }
        return Self.appearanceOrder.firstIndex(of: appearance) ?? 0
    }
}
