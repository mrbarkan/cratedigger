import CrateDiggerCore
import SwiftUI

// The shared drawing of the three styles that are not Real Hardware: one slab
// (a key, a well, a panel), how a key answers a press, and a button style that
// puts the two together. Real Hardware never comes here: every primitive keeps
// its Real body verbatim and branches to these only for another style.

private struct StyledPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the key this slab belongs to is held down. Set by `StyledPress`,
    /// read by `StyledSlab`: the press moves the key, the slab moves the shadow
    /// or base it lands on.
    var styledPressed: Bool {
        get { self[StyledPressedKey.self] }
        set { self[StyledPressedKey.self] = newValue }
    }
}

/// One slab of the console in a style other than Real Hardware.
///
/// - Flat Hardware: a key is a lit top face on its own darker base, which shows
///   as a band below it; a well (`sunken`) is cut in, shaded under its top edge
///   and lit along its bottom one.
/// - Soft Blocks: the flat fill, nothing else. The caller passes Soft's
///   separated colour (`softSurfaces`); the slab never looks colours up.
/// - Sticker: the fill with a thick inner outline and a hard shadow offset down
///   and right, both in `stickerInk`.
///
/// Never build one for `.hardware`: the caller branches before it. It draws the
/// plain fill there and stops a DEBUG build, so a missed branch is loud.
struct StyledSlab<S: Shape>: View {
    @Environment(\.carbon) private var theme
    @Environment(\.interfaceStyle) private var style
    @Environment(\.styledPressed) private var pressed

    let shape: S
    let fill: Color
    /// Flat Hardware: the light over the top half of a key, the shade under a
    /// well's top edge. Defaults to `fill`.
    var hi: Color? = nil
    /// Flat Hardware: a key's base. Defaults to `fill`.
    var lo: Color? = nil
    /// Sticker: how far the hard shadow sits. Flat Hardware: how tall the base
    /// band under a key is. `StyledPress` moves the key by the same amount.
    var depth: CGFloat = 2.5
    /// A well or a panel is cut into the case, not stuck on it.
    var sunken = false
    /// Sticker: the inner outline's width.
    var outline: CGFloat = 2

    init(shape: S, fill: Color, hi: Color? = nil, lo: Color? = nil,
         depth: CGFloat = 2.5, sunken: Bool = false, outline: CGFloat = 2) {
        self.shape = shape
        self.fill = fill
        self.hi = hi
        self.lo = lo
        self.depth = depth
        self.sunken = sunken
        self.outline = outline
    }

    var body: some View {
        switch style {
        case .hardware:
            shape.fill(fill)
                .onAppear {
                    assertionFailure("StyledSlab built for Real Hardware: the caller must keep its Real body")
                }
        case .softBlocks:
            shape.fill(fill)
        case .sticker:
            sticker
        case .flatHardware:
            if sunken { flatWell } else { flatKey }
        }
    }

    private var sticker: some View {
        ZStack {
            shape.fill(theme.stickerInk)
                .offset(x: pressed ? 0 : depth, y: pressed ? 0 : depth)
            shape.fill(fill)
                // Twice the width, clipped to the shape: an inner outline, so
                // the slab keeps its frame.
                .overlay(shape.stroke(theme.stickerInk, lineWidth: outline * 2).clipShape(shape))
        }
    }

    /// A chunky key: a lit top face sitting on its own darker base, which shows
    /// as a band below the cap. A press drops the cap onto the base.
    private var flatKey: some View {
        let top = hi ?? fill
        let base = lo ?? fill
        return ZStack {
            shape.fill(base)
                .overlay(shape.fill(Color.black.opacity(theme.isDark ? 0.38 : 0.16)))
                .offset(y: pressed ? 0 : depth)
                // The short contact shadow under the base; it tightens on a press.
                .shadow(color: Color.black.opacity(theme.isDark ? 0.45 : 0.16),
                        radius: pressed ? 0.5 : 1.2, y: pressed ? 0.5 : 1.5)
            // The highlight only lifts the top half of the cap, at half
            // strength: a full `hi` → `fill` ramp paled dark themes' keys
            // (Llama '97 dark) until their printed glyphs washed out.
            shape
                .fill(fill)
                .overlay(shape.fill(LinearGradient(colors: [top.opacity(0.5), top.opacity(0)],
                                                   startPoint: .top, endPoint: .center)))
                .overlay(
                    shape.stroke(
                        LinearGradient(colors: [Color.white.opacity(theme.isDark ? 0.22 : 0.85), .clear],
                                       startPoint: .top, endPoint: .center),
                        lineWidth: 2
                    )
                    .clipShape(shape)
                )
        }
    }

    /// A well cut into the case: shaded under its top edge, lit along its bottom.
    private var flatWell: some View {
        let bottom = lo ?? fill
        return shape
            .fill(LinearGradient(colors: [bottom, fill, fill], startPoint: .top, endPoint: .bottom))
            .overlay(
                shape.stroke(LinearGradient(colors: [Color.black.opacity(theme.isDark ? 0.55 : 0.28), .clear],
                                            startPoint: .top, endPoint: .center), lineWidth: 5)
                    .clipShape(shape)
            )
            .overlay(
                shape.stroke(LinearGradient(colors: [.clear, Color.white.opacity(theme.isDark ? 0.14 : 0.7)],
                                            startPoint: .center, endPoint: .bottom), lineWidth: 3)
                    .clipShape(shape)
            )
    }
}

/// How a key answers a press in each style other than Real Hardware, which
/// passes the content through untouched (its keys keep their own travel).
///
/// - Flat Hardware: the cap moves down by `depth` and covers its base.
/// - Soft Blocks: the key scales to 0.95 on `CarbonMotion.softPress`, a quick
///   ease under Reduce Motion.
/// - Sticker: the key moves by `depth` down and right, onto its shadow.
///
/// The offsets stay under Reduce Motion: they are feedback, not movement.
struct StyledPress: ViewModifier {
    @Environment(\.interfaceStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let pressed: Bool
    var depth: CGFloat = 2.5

    init(pressed: Bool, depth: CGFloat = 2.5) {
        self.pressed = pressed
        self.depth = depth
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if style == .hardware {
            content
        } else {
            content
                .environment(\.styledPressed, pressed)
                .scaleEffect(style == .softBlocks && pressed ? 0.95 : 1)
                .offset(x: style == .sticker && pressed ? depth : 0, y: offsetY)
                .animation(animation, value: pressed)
        }
    }

    private var offsetY: CGFloat {
        switch style {
        case .sticker, .flatHardware: return pressed ? depth : 0
        case .softBlocks, .hardware: return 0
        }
    }

    private var animation: Animation {
        style == .softBlocks
            ? CarbonMotion.movement(CarbonMotion.softPress, reduceMotion: reduceMotion)
            : CarbonMotion.press
    }
}

/// The hover lift plus the style's press, for keys drawn with `StyledSlab`.
/// Only for a style other than Real Hardware; Real keys keep their own style.
struct StyledKeyButtonStyle: ButtonStyle {
    var depth: CGFloat = 2.5

    init(depth: CGFloat = 2.5) {
        self.depth = depth
    }

    func makeBody(configuration: Configuration) -> some View {
        KeyBody(configuration: configuration, depth: depth)
    }

    private struct KeyBody: View {
        let configuration: Configuration
        let depth: CGFloat
        @Environment(\.carbon) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .brightness(brightness)
                .modifier(StyledPress(pressed: configuration.isPressed, depth: depth))
                .animation(CarbonMotion.hover, value: hovering)
                .onHover { hovering = $0 && isEnabled }
        }

        private var brightness: Double {
            if configuration.isPressed { return theme.isDark ? -0.05 : -0.04 }
            if hovering { return theme.isDark ? 0.07 : 0.03 }
            return 0
        }
    }
}
