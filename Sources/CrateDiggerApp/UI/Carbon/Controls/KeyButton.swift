import SwiftUI

enum KeyButtonStyle: Equatable {
    case normal
    case selected
    case glowingOrange
    case glowingFilled
    case disabled
}

/// The flat interface key: every non-transport button in the app (tabs, sheet
/// actions, toolbar keys). Deliberately **not** the silicone transport cap —
/// these are software controls, so they stay flat: one solid fill, a hairline
/// edge, no gradient, bevel or shadow.
///
/// It also owns the label's type. Callers pass bare `Text`/`Image` and get the
/// house face, size and tracking, so keys can't drift apart sheet by sheet.
struct KeyButton<Label: View>: View {
    @Environment(\.carbon) private var theme
    var style: KeyButtonStyle = .normal
    var clickVariant: ClickPlayer.Variant = .key
    var action: () -> Void = {}
    @ViewBuilder var label: () -> Label

    private static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 6, style: .continuous) }

    var body: some View {
        Button(action: {
            guard style != .disabled else { return }
            ClickPlayer.shared.play(clickVariant)
            action()
        }) {
            ZStack {
                background
                label()
                    .font(CarbonFont.mono(9, weight: .bold))
                    .tracking(1.2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)   // long titles shrink rather than wrap
                    .foregroundStyle(textColor)
                    .padding(.horizontal, 8)
            }
            .contentShape(Self.shape)
        }
        .buttonStyle(.carbonHover)
        .opacity(style == .disabled ? 0.42 : 1)
        .allowsHitTesting(style != .disabled)
    }

    @ViewBuilder
    private var background: some View {
        let shape = Self.shape
        switch style {
        case .normal, .disabled:
            shape.fill(theme.metal)   // opaque, not Material — see ChassisLayer
                 .overlay(shape.strokeBorder(theme.hair, lineWidth: 1))

        case .selected, .glowingFilled:
            shape.fill(theme.orange)

        case .glowingOrange:
            shape.fill(theme.orange.opacity(0.12))
                 .overlay(shape.strokeBorder(theme.orange.opacity(0.6), lineWidth: 1))
        }
    }

    private var textColor: Color {
        switch style {
        case .normal:        return theme.ink2
        case .selected:      return theme.selectionInk
        case .glowingOrange: return theme.orange
        case .glowingFilled: return theme.selectionInk
        case .disabled:      return theme.ink3
        }
    }
}
