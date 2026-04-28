import SwiftUI

/// Wraps a sheet view with the carbon theme environment derived from the
/// current global AppearanceMode, so sheets honor the user's Light/Dark choice
/// instead of always rendering against the default theme.
struct ThemedSheetWrapper<Content: View>: View {
    @AppStorage(AppearanceMode.userDefaultsKey) private var rawMode: String = AppearanceMode.system.rawValue
    @ViewBuilder var content: () -> Content

    var body: some View {
        let mode = AppearanceMode(rawValue: rawMode) ?? .system
        content()
            .carbonThemed(mode: mode)
    }
}
