import SwiftUI

struct ViewSwitcherColumn: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 8) {
            DisplayModeButton()
            AppearanceModeToggle()
        }
    }
}

private struct AppearanceModeToggle: View {
    @Environment(\.carbon) private var theme
    @State private var mode: AppearanceMode = AppearanceModeToggle.currentMode()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(AppearanceMode.allCases, id: \.self) { option in
                segment(for: option)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppearanceMode.didChangeNotification)) { _ in
            mode = AppearanceModeToggle.currentMode()
        }
    }

    @ViewBuilder
    private func segment(for option: AppearanceMode) -> some View {
        let isOn = (option == mode)
        KeyButton(style: isOn ? .selected : .normal, action: { select(option) }) {
            Text(label(for: option))
                .font(CarbonFont.mono(8.5, weight: .bold))
                .tracking(1.4)
        }
        .frame(maxWidth: .infinity)
    }

    private func label(for option: AppearanceMode) -> String {
        switch option {
        case .light:  return "LT"
        case .dark:   return "DK"
        case .system: return "AUTO"
        }
    }

    private func select(_ option: AppearanceMode) {
        guard option != mode else { return }
        mode = option
        UserDefaults.standard.set(option.rawValue, forKey: AppearanceMode.userDefaultsKey)
        NotificationCenter.default.post(name: AppearanceMode.didChangeNotification, object: nil)
    }

    private static func currentMode() -> AppearanceMode {
        let raw = UserDefaults.standard.string(forKey: AppearanceMode.userDefaultsKey)
            ?? AppearanceMode.system.rawValue
        return AppearanceMode(rawValue: raw) ?? .system
    }
}
