import SwiftUI

/// Right-hand header column: the DISPLAY screen tile (OLED mode) plus three
/// settings buttons — VIEW / THEME / EQ — each showing a dot indicator row for
/// its current option, mirroring the CrateDigger v6 design.
struct ViewSwitcherColumn: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    @State private var appearance: AppearanceMode = ViewSwitcherColumn.currentAppearance()

    /// Order of the THEME dots: dark · light · auto.
    private static let themeOrder: [AppearanceMode] = [.dark, .light, .system]

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

            SwitchButton(
                name: "THEME",
                dotCount: Self.themeOrder.count,
                activeIndex: Self.themeOrder.firstIndex(of: appearance) ?? 0,
                tip: "THEME — cycle the appearance: dark · light · auto."
            ) {
                cycleTheme()
            }

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
    }

    private func cycleTheme() {
        ClickPlayer.shared.play(.key)
        let order = Self.themeOrder
        let idx = order.firstIndex(of: appearance) ?? 0
        let next = order[(idx + 1) % order.count]
        appearance = next
        UserDefaults.standard.set(next.rawValue, forKey: AppearanceMode.userDefaultsKey)
        NotificationCenter.default.post(name: AppearanceMode.didChangeNotification, object: nil)
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
