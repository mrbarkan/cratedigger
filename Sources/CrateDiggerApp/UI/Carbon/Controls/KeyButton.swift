import SwiftUI

enum KeyButtonStyle: Equatable {
    case normal
    case selected
    case glowingOrange
    case disabled
}

struct KeyButton<Label: View>: View {
    @Environment(\.carbon) private var theme
    var style: KeyButtonStyle = .normal
    var clickVariant: ClickPlayer.Variant = .key
    var action: () -> Void = {}
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: {
            guard style != .disabled else { return }
            ClickPlayer.shared.play(clickVariant)
            action()
        }) {
            ZStack {
                background
                label()
                    .foregroundStyle(textColor)
            }
        }
        .buttonStyle(.plain)
        .opacity(style == .disabled ? 0.42 : 1)
        .allowsHitTesting(style != .disabled)
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .normal, .disabled:
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: theme.isDark
                            ? [Color(hex: 0x3A3A37), Color(hex: 0x1A1A18)]
                            : [theme.chassisHi, theme.chassisLo],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(theme.isDark ? 0.06 : 0.5), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(theme.isDark ? 0.4 : 0.12), radius: 1, y: 1)

        case .selected:
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.ink)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.04), lineWidth: 0.5)
                )

        case .glowingOrange:
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x050504), Color(hex: 0x0E0E0C)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(theme.orange.opacity(0.5), lineWidth: 0.5)
                )
        }
    }

    private var textColor: Color {
        switch style {
        case .normal:        return theme.ink2
        case .selected:      return theme.isDark ? theme.orange : Color(hex: 0xF3F6EC)
        case .glowingOrange: return theme.orange
        case .disabled:      return theme.ink3
        }
    }
}
