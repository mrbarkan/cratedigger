import SwiftUI

struct CarbonRootView: View {
    @AppStorage(AppearanceMode.userDefaultsKey) private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @ObservedObject var model: LibraryViewModel
    @State private var dropHint: PrepCrateDropHint? = nil

    private var mode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    var body: some View {
        ChassisLayer {
            VStack(spacing: CarbonLayout.chassisRowGap) {
                HeaderShell()
                    .frame(height: CarbonLayout.headerHeight)
                MainShell()
                    .frame(maxHeight: .infinity)
                FooterShell()
                    .frame(height: CarbonLayout.footerHeight)
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
