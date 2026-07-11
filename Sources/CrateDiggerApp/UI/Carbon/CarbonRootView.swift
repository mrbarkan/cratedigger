import CrateDiggerCore
import SwiftUI

struct CarbonRootView: View {
    @AppStorage(AppearanceMode.userDefaultsKey) private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @ObservedObject var model: LibraryViewModel
    @ObservedObject private var themeRegistry = ThemeRegistry.shared
    @State private var dropHint: PrepCrateDropHint? = nil

    private var mode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    /// Resolved the same way `CarbonThemed` resolves it — `body` sits
    /// *outside* the environment scope `.carbonThemed(mode:)` establishes for
    /// its child below (a view's own `@Environment` reads reflect what its
    /// parent set, never what it sets for its own descendants), so reading
    /// `@Environment(\.carbonGeometry)` here would silently stay at the
    /// default regardless of the active theme.
    private var geometry: CarbonGeometry {
        themeRegistry.resolvedTheme(for: PreferencesStore.shared.selectedThemeID)?.geometry ?? .standard
    }

    var body: some View {
        ChassisLayer {
            VStack(spacing: geometry.chassisRowGap) {
                HeaderShell()
                    .frame(height: geometry.headerHeight)
                MainShell()
                    .frame(maxHeight: .infinity)
                FooterShell()
                    .frame(height: geometry.footerHeight)
            }
        }
        .environmentObject(model)
        .carbonThemed(mode: mode)
        // Whole-window Finder drop → straight into the Prep Crate, with a HUD
        // naming the destination while the drag hovers (and calling out
        // payloads that aren't records). Inner drop targets (crate/playlist
        // rows) sit deeper in the hierarchy and keep taking precedence.
        .onDrop(of: [.fileURL], delegate: PrepCrateDropDelegate(hint: $dropHint, model: model))
        .overlay(PrepCrateDropOverlay(hint: dropHint).carbonThemed(mode: mode))
        .sheet(
            item: Binding(
                get: { model.appAlert },
                set: { model.appAlert = $0 }
            )
        ) { alert in
            // Re-apply the theme so the sheet's own environment carries the
            // Carbon palette and appearance, independent of propagation.
            CarbonAlertView(alert: alert)
                .carbonThemed(mode: mode)
        }
    }
}
