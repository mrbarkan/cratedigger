import SwiftUI

struct ViewSwitcherColumn: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 8) {
            DisplayModeButton()
            AppearanceCycleButton()
        }
    }
}

/// Single skeuomorphic button that cycles `Light → Dark → System` on tap,
/// replacing the previous three-segment LT / DK / AUTO selector. Uses the
/// shared `ChromeChassis` so it sits in the chassis like a hardware switch.
private struct AppearanceCycleButton: View {
    @Environment(\.carbon) private var theme
    @State private var mode: AppearanceMode = AppearanceCycleButton.currentMode()

    private static let cycle: [AppearanceMode] = [.system, .light, .dark]

    var body: some View {
        Button(action: advance) {
            HStack(spacing: 6) {
                Text(symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(symbolColor)
                Text(label)
                    .font(CarbonFont.mono(9, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(theme.ink2)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(ChromeChassis(theme: theme, cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help("Cycle appearance: System → Light → Dark")
        .accessibilityLabel(Text("Appearance: \(label)"))
        .accessibilityHint(Text("Tap to cycle"))
        .onReceive(NotificationCenter.default.publisher(for: AppearanceMode.didChangeNotification)) { _ in
            mode = AppearanceCycleButton.currentMode()
        }
    }

    private func advance() {
        let cycle = Self.cycle
        let idx = cycle.firstIndex(of: mode) ?? 0
        let next = cycle[(idx + 1) % cycle.count]
        mode = next
        UserDefaults.standard.set(next.rawValue, forKey: AppearanceMode.userDefaultsKey)
        NotificationCenter.default.post(name: AppearanceMode.didChangeNotification, object: nil)
    }

    private var label: String {
        switch mode {
        case .light:  return "LIGHT"
        case .dark:   return "DARK"
        case .system: return "AUTO"
        }
    }

    private var symbol: String {
        switch mode {
        case .light:  return "☀︎"
        case .dark:   return "☾"
        case .system: return "◐"
        }
    }

    private var symbolColor: Color {
        switch mode {
        case .light:  return theme.sun
        case .dark:   return theme.cyan
        case .system: return theme.orange
        }
    }

    private static func currentMode() -> AppearanceMode {
        let raw = UserDefaults.standard.string(forKey: AppearanceMode.userDefaultsKey)
            ?? AppearanceMode.system.rawValue
        return AppearanceMode(rawValue: raw) ?? .system
    }
}
