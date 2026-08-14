import AppKit
import CrateDiggerCore
import SwiftUI

/// The THEME key's destination: appearance + installed skins, shown in the
/// inspector the way CNVRT shows the Patch Bay.
///
/// It replaced a blind cycle. Cycling was fine with two built-ins, but once a
/// theme could be authored in-app the list stopped being short or memorable —
/// you were pressing a key repeatedly to hunt for a skin you couldn't see
/// coming. A list you pick from directly is the same number of clicks at worst
/// and none of the guessing.
struct ThemePickerPane: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    @EnvironmentObject private var model: LibraryViewModel
    @ObservedObject private var registry = ThemeRegistry.shared

    @State private var appearance: AppearanceMode = AppearanceMode.current
    @State private var selectedThemeID: String? = PreferencesStore.shared.selectedThemeID
    /// The theme a pending delete is armed against; `nil` when none is.
    @State private var armedDeleteID: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    sectionLabel("Appearance")
                    HStack(spacing: 6) {
                        ForEach(AppearanceMode.allCases, id: \.rawValue) { mode in
                            KeyButton(
                                style: appearance == mode ? .selected : .normal,
                                action: { selectAppearance(mode) }
                            ) {
                                Text(mode.menuTitle.uppercased())
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: geometry.keyHeight)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)

                    appearanceNote

                    sectionLabel("Themes")
                    if registry.manifests.isEmpty {
                        Text("No themes installed.")
                            .font(CarbonFont.mono(9))
                            .foregroundStyle(theme.ink4)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(registry.manifests) { manifest in
                            themeRow(manifest)
                        }
                    }

                    warnings
                    actions
                }
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onReceive(NotificationCenter.default.publisher(for: PreferencesStore.themesDidChange)) { _ in
            selectedThemeID = PreferencesStore.shared.selectedThemeID
        }
        .onReceive(NotificationCenter.default.publisher(for: AppearanceMode.didChangeNotification)) { _ in
            appearance = AppearanceMode.current
        }
    }

    /// Appearance now applies *to* the selected theme rather than replacing it,
    /// which only means something for a theme carrying both looks. Saying so
    /// beats three keys that silently do nothing on a single-appearance theme.
    @ViewBuilder
    private var appearanceNote: some View {
        if let current = registry.manifest(for: selectedThemeID), !current.definition.isAdaptive {
            Text("\(current.definition.name) is \(current.definition.baseAppearance == .dark ? "dark" : "light")-only — Appearance applies to themes that carry both.")
                .font(CarbonFont.mono(8))
                .foregroundStyle(theme.ink4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.bottom, 2)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("THEME")
                .font(CarbonFont.mono(9.5, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(theme.ink2)
            Spacer(minLength: 0)
            Button(action: { model.showingThemePicker = false }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.ink3)
            }
            .buttonStyle(.carbonHover)
            .carbonTip("Close and go back to the inspector")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.08))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private func themeRow(_ manifest: ThemeManifest) -> some View {
        let isSelected = manifest.id == selectedThemeID
        let isBuiltIn = { if case .builtIn = manifest.origin { return true } else { return false } }()

        return Button(action: { selectTheme(manifest.id) }) {
            HStack(spacing: 9) {
                // A dot of the theme's own accent, so the list previews itself.
                Circle()
                    .fill(accent(of: manifest))
                    .frame(width: 9, height: 9)
                    .shadow(color: accent(of: manifest).opacity(0.7), radius: isSelected ? 3 : 0)

                VStack(alignment: .leading, spacing: 1) {
                    Text(manifest.definition.name)
                        .font(CarbonFont.sans(11, weight: isSelected ? .bold : .regular))
                        .foregroundStyle(isSelected ? theme.ink : theme.ink2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    HStack(spacing: 5) {
                        Text(isBuiltIn ? "DEFAULT" : "Installed")
                            .font(CarbonFont.mono(8, weight: isBuiltIn ? .bold : .regular))
                            .tracking(isBuiltIn ? 1.0 : 0)
                            .foregroundStyle(isBuiltIn ? theme.ink3 : theme.ink4)
                        if manifest.definition.isAdaptive {
                            // Worth calling out: it's the difference between a
                            // theme that follows Appearance and one that doesn't.
                            Text("· LIGHT + DARK")
                                .font(CarbonFont.mono(8))
                                .foregroundStyle(theme.ink4)
                        }
                    }
                }

                Spacer(minLength: 4)

                KeyButton(action: { edit(manifest) }) { Text("EDIT") }
                    .frame(width: 50, height: 20)
                    .carbonTip(isBuiltIn
                               ? "Open an editable copy of \(manifest.definition.name)"
                               : "Edit \(manifest.definition.name)")

                // Defaults ship inside the app: there's nothing of yours to
                // delete, and they'd reappear on the next scan regardless.
                if !isBuiltIn {
                    deleteButton(for: manifest)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(isSelected ? theme.orange.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.carbonHover)
    }

    /// The loader has always collected these — a malformed file, a duplicate
    /// id — but nothing ever showed them, so a theme could be skipped without
    /// a word. That's how a saved edit went missing: two files claiming one id,
    /// one of them silently dropped.
    @ViewBuilder
    private var warnings: some View {
        if !registry.loadWarnings.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                sectionLabel("Skipped Files")
                ForEach(Array(registry.loadWarnings.enumerated()), id: \.offset) { _, warning in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.sun)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.fileLabel(for: warning.sourceURL))
                                .font(CarbonFont.mono(8.5, weight: .bold))
                                .foregroundStyle(theme.ink2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(warning.message)
                                .font(CarbonFont.mono(8))
                                .foregroundStyle(theme.ink4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                }
            }
        }
    }

    /// Every bundle's manifest is called `theme.json`, so naming the file tells
    /// you nothing about which theme is at fault — the enclosing `.cdtheme`
    /// folder is the thing you'd actually go and find in Finder.
    static func fileLabel(for url: URL) -> String {
        url.lastPathComponent == "theme.json"
            ? url.deletingLastPathComponent().lastPathComponent
            : url.lastPathComponent
    }

    /// Two clicks, like the editor's layer copy: this removes the theme's files
    /// and there's no undo. Arming one disarms any other, so a stray click on
    /// the row below can't delete the wrong theme.
    private func deleteButton(for manifest: ThemeManifest) -> some View {
        let armed = armedDeleteID == manifest.id
        return KeyButton(
            style: armed ? .glowingOrange : .normal,
            action: {
                if armed {
                    registry.deleteTheme(manifest)
                    armedDeleteID = nil
                    selectedThemeID = PreferencesStore.shared.selectedThemeID
                } else {
                    armedDeleteID = manifest.id
                }
            }
        ) {
            Text(armed ? "SURE?" : "✕")
        }
        .frame(width: armed ? 54 : 28, height: 20)
        .carbonTip(armed
                   ? "Click again to delete \(manifest.definition.name) from your Themes folder."
                   : "Delete \(manifest.definition.name)")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            KeyButton(action: {
                registry.refresh()
                selectedThemeID = PreferencesStore.shared.selectedThemeID
            }) {
                Text("REFRESH")
            }
            .frame(maxWidth: .infinity)
            .frame(height: geometry.keyHeight)
            .carbonTip("Re-scan the Themes folder for skins dropped in while the app was running")

            KeyButton(action: revealInFinder) { Text("FOLDER") }
                .frame(maxWidth: .infinity)
                .frame(height: geometry.keyHeight)
                .carbonTip("Show the Themes folder in Finder")

            KeyButton(style: .glowingFilled, action: { model.showingThemeEditor = true }) {
                Text("EDITOR")
            }
            .frame(maxWidth: .infinity)
            .frame(height: geometry.keyHeight)
            .carbonTip("Open the theme editor on the current theme")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    /// The accent a theme renders with, resolved the same way the app resolves
    /// it — so the dot is the real color, not the file's raw token (which a
    /// theme inheriting its accent wouldn't even have).
    private func accent(of manifest: ThemeManifest) -> Color {
        let base: CarbonTheme = manifest.definition.baseAppearance == .dark ? .carbon : .linen
        return CarbonTheme(definition: manifest.definition, resolvedBase: base).orange
    }

    private func edit(_ manifest: ThemeManifest) {
        registry.beginEditing(manifest)
        model.showingThemeEditor = true
    }

    /// Sets light/dark/system *for the theme you're using*, keeping it
    /// selected.
    ///
    /// It used to clear the selection, because back when a theme was one fixed
    /// appearance, picking light or dark could only mean "stop using this
    /// skin". Now that a theme can carry both, appearance is a property of the
    /// theme you're on — so the selection stays put and the adaptive theme
    /// follows along.
    private func selectAppearance(_ mode: AppearanceMode) {
        appearance = mode
        UserDefaults.standard.set(mode.rawValue, forKey: AppearanceMode.userDefaultsKey)
        NotificationCenter.default.post(name: AppearanceMode.didChangeNotification, object: nil)
    }

    private func selectTheme(_ id: String) {
        PreferencesStore.shared.selectedThemeID = id
        selectedThemeID = id
    }

    private func revealInFinder() {
        guard let url = registry.userThemesDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(CarbonFont.mono(9, weight: .bold))
            .tracking(1.8)
            .foregroundStyle(theme.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }
}
