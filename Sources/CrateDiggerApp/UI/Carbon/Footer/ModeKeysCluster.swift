import SwiftUI

struct ModeKeysCluster: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        HStack(spacing: 14) {
            verticalLabel("Modes")
            grid
        }
    }

    private var grid: some View {
        HStack(spacing: 8) {
            modeKey(label: "Shuffle", on: model.shuffleEnabled) {
                model.toggleShuffle()
            }
            modeKey(label: "Repeat", on: model.repeatMode != .off) {
                model.cycleRepeatMode()
            }
        }
    }

    private func modeKey(label: String, on: Bool = false, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        let style: KeyButtonStyle = disabled ? .disabled : (on ? .selected : .normal)
        return KeyButton(style: style, action: action) {
            Text(label.uppercased())
                .font(CarbonFont.mono(9, weight: .bold))
                .tracking(1.6)
        }
        .frame(width: 70, height: CarbonLayout.keyHeight)
    }

    private func verticalLabel(_ label: String) -> some View {
        Text(label.uppercased())
            .font(CarbonFont.mono(8.5, weight: .bold))
            .tracking(2.2)
            .foregroundStyle(theme.ink3)
            .rotationEffect(.degrees(-90))
            .fixedSize()
    }
}
