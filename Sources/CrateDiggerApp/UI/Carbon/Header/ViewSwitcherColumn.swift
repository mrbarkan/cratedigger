import SwiftUI

struct ViewSwitcherColumn: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 6) {
            ForEach(OLEDView.allCases.filter { $0 != .vu }, id: \.self) { view in
                ViewSwitchButton(view: view, isOn: model.oledView == view) {
                    model.oledView = view
                }
            }
            AppearanceModeToggle()
        }
    }
}

private struct ViewSwitchButton: View {
    @Environment(\.carbon) private var theme
    let view: OLEDView
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        KeyButton(style: isOn ? .selected : .normal, action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.black.opacity(0.25))
                        .frame(width: 6, height: 6)
                    if isOn {
                        Circle()
                            .fill(theme.orange)
                            .frame(width: 6, height: 6)
                            .shadow(color: theme.orange, radius: 4)
                    }
                }
                Text(view.label.uppercased())
                    .font(CarbonFont.mono(9, weight: .bold))
                    .tracking(1.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity)
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
