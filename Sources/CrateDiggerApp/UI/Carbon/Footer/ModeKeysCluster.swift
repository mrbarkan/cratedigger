import SwiftUI

struct ModeKeysCluster: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        grid
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
}
