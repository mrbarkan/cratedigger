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
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        switch style {
        case .normal, .disabled:
            shape
                .fill(.ultraThinMaterial)
                .overlay(
                    shape.fill(
                        LinearGradient(
                            colors: [
                                theme.metalHi.opacity(theme.isDark ? 0.34 : 0.68),
                                theme.metal.opacity(theme.isDark ? 0.28 : 0.44),
                                theme.metalLo.opacity(theme.isDark ? 0.38 : 0.32)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
                .overlay(
                    shape.strokeBorder(Color.white.opacity(theme.isDark ? 0.14 : 0.66), lineWidth: 0.7)
                )
                .shadow(color: Color.black.opacity(theme.isDark ? 0.42 : 0.12), radius: 4, y: 2)

        case .selected:
            shape
                .fill(
                    LinearGradient(
                        colors: [theme.orangeHi, theme.orange, theme.orangeLo],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    shape.stroke(Color.white.opacity(0.34), lineWidth: 0.7)
                )
                .shadow(color: theme.orange.opacity(0.35), radius: 12, y: 0)

        case .glowingOrange:
            shape
                .fill(
                    LinearGradient(
                        colors: [theme.wellDeep, theme.metalDeep],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    shape.stroke(theme.orange.opacity(0.55), lineWidth: 0.7)
                )
                .shadow(color: theme.orange.opacity(0.35), radius: 10)
        }
    }

    private var textColor: Color {
        switch style {
        case .normal:        return theme.ink2
        case .selected:      return theme.selectionInk
        case .glowingOrange: return theme.orange
        case .disabled:      return theme.ink3
        }
    }
}
