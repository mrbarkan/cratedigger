import SwiftUI

struct CarbonRootView: View {
    @AppStorage(AppearanceMode.userDefaultsKey) private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @ObservedObject var model: LibraryViewModel

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
    }
}
