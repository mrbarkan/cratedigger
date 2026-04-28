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
        .alert(
            item: Binding(
                get: { model.appAlert },
                set: { model.appAlert = $0 }
            )
        ) { alert in
            if let actionTitle = alert.actionTitle, let action = alert.action {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text(actionTitle), action: action),
                    secondaryButton: .cancel(Text("OK"))
                )
            } else {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }
}
