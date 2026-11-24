import CrateDiggerCore
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
///
/// In a style other than Real Hardware the key is a `StyledSlab` and answers a
/// press as that style does; the frame, the hit area and which state lights
/// the key with the accent are the same in every style.
struct KeyButton<Label: View>: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    @Environment(\.interfaceStyle) private var interfaceStyle
    var style: KeyButtonStyle = .normal
    var clickVariant: ClickPlayer.Variant = .key
    var action: () -> Void = {}
    @ViewBuilder var label: () -> Label

    /// The key as drawn: the theme's corner, as the style rounds it.
    private var shape: RoundedRectangle {
        CarbonGeometry.styledShape(geometry.keyCornerRadius, for: interfaceStyle)
    }

    /// Where a click lands: the theme's own corner in every style, so a
    /// rounder style never trims the key's hit area.
    private var hitShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: geometry.keyCornerRadius, style: .continuous)
    }

    private static var tracking: CGFloat { 1.2 }

    var body: some View {
        let button = Button(action: {
            guard style != .disabled else { return }
            ClickPlayer.shared.play(clickVariant)
            action()
        }) {
            ZStack {
                background
                label()
                    .font(CarbonFont.mono(9, weight: .bold))
                    .tracking(Self.tracking)
                    // Tracking is added after every glyph, the last one too,
                    // so the label carries a trailing space of one tracking
                    // and sits left of centre. A matching leading inset
                    // balances it (most visible on a short word like RIP).
                    .padding(.leading, Self.tracking)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)   // long titles shrink rather than wrap
                    .foregroundStyle(textColor)
                    .padding(.horizontal, 8)
            }
            // A tab or toggle key changing hands: fill and ink cross over at
            // `state` speed rather than flickering. Colour only.
            .animation(CarbonMotion.state, value: style)
            .contentShape(hitShape)
        }
        if interfaceStyle == .hardware {
            button
                .buttonStyle(.carbonHover)
                .opacity(style == .disabled ? 0.42 : 1)
                .allowsHitTesting(style != .disabled)
        } else {
            button
                .buttonStyle(StyledKeyButtonStyle(depth: StyledKeyMetrics.depth, hitShape: AnyShape(hitShape)))
                .opacity(style == .disabled ? 0.42 : 1)
                .allowsHitTesting(style != .disabled)
        }
    }

    @ViewBuilder
    private var background: some View {
        let shape = shape
        switch style {
        case .normal, .disabled:
            KeyChrome()

        case .selected, .glowingFilled:
            // Lit with the accent in every style; only the finish changes.
            if interfaceStyle == .hardware {
                shape.fill(theme.orange)
            } else {
                StyledSlab(shape: shape, fill: theme.orange, hi: theme.orangeHi, lo: theme.orangeLo,
                           depth: StyledKeyMetrics.depth, outline: StyledKeyMetrics.outline)
            }

        case .glowingOrange:
            shape.fill(theme.orange.opacity(0.12))
                 .overlay(shape.strokeBorder(theme.orange.opacity(0.6), lineWidth: 1))
        }
    }

    private var textColor: Color {
        switch style {
        case .normal:        return theme.chassisInk
        case .selected:      return theme.accentInk
        case .glowingOrange: return theme.orange
        case .glowingFilled: return theme.accentInk
        case .disabled:      return theme.keyPrint(theme.ink3)
        }
    }
}

/// A flat key's measures in a style other than Real Hardware, shared by
/// `KeyButton` and `KeyChrome` so a menu dressed as a key matches the keys
/// beside it.
enum StyledKeyMetrics {
    /// The base band (Flat Hardware) or hard shadow (Sticker), and so how far
    /// a press moves the key.
    static let depth: CGFloat = 2
    /// Sticker's inner outline.
    static let outline: CGFloat = 1.5
}

/// A key's resting chrome on its own, for controls that can't *be* a
/// `KeyButton` — a `Menu` label, say — but have to look like one.
/// In a style other than Real Hardware it is the style's slab.
struct KeyChrome: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    @Environment(\.interfaceStyle) private var style
    @Environment(\.softSurfaces) private var softSurfaces

    var body: some View {
        if style == .hardware {
            let shape = RoundedRectangle(cornerRadius: geometry.keyCornerRadius, style: .continuous)
            shape.fill(theme.metal)   // opaque, not Material — see ChassisLayer
                 .overlay(shape.strokeBorder(theme.hair, lineWidth: 1))
        } else {
            StyledSlab(shape: CarbonGeometry.styledShape(geometry.keyCornerRadius, for: style),
                       fill: softSurfaces?.metal ?? theme.metal, hi: theme.metalHi, lo: theme.metalLo,
                       depth: StyledKeyMetrics.depth, outline: StyledKeyMetrics.outline)
        }
    }
}
