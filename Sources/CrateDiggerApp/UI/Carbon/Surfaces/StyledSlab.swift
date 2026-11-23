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

/// What a press does to a key drawn with `StyledSlab`, per style: where it
/// moves, how much it squashes, and on which curve. Real Hardware has no
/// press here at all: its keys keep their own travel.
enum StyledPressRule {
    /// The press as a scale (about the key's centre) and an offset.
    struct Transform: Equatable {
        var scale: CGFloat = 1
        var x: CGFloat = 0
        var y: CGFloat = 0

        static let rest = Transform()
    }

    /// Which `CarbonMotion` curve carries the press.
    enum Curve: Equatable {
        /// `CarbonMotion.press`: a key going down, quick and without bounce.
        case press
        /// `CarbonMotion.softPress`: Soft Blocks' squash, a short spring.
        case softPress
        /// `CarbonMotion.reducedMovement`: the spring under Reduce Motion.
        case reducedMovement

        var animation: Animation {
            switch self {
            case .press: return CarbonMotion.press
            case .softPress: return CarbonMotion.softPress
            case .reducedMovement: return CarbonMotion.reducedMovement
            }
        }
    }

    /// Flat Hardware: the cap moves down by `depth` and covers its base.
    /// Sticker: the key moves by `depth` down and right, onto its shadow.
    /// Soft Blocks: the key squashes to 0.95 where it is.
    static func transform(style: InterfaceStyle, pressed: Bool, depth: CGFloat) -> Transform {
        guard pressed else { return .rest }
        switch style {
        case .hardware: return .rest
        case .flatHardware: return Transform(y: depth)
        case .sticker: return Transform(x: depth, y: depth)
        case .softBlocks: return Transform(scale: 0.95)
        }
    }

    /// Soft Blocks' spring is a movement, so Reduce Motion turns it into a
    /// quick ease (`CarbonMotion.movement`). The small offsets of Flat Hardware
    /// and Sticker are feedback, not movement, and keep the key press.
    static func curve(style: InterfaceStyle, reduceMotion: Bool) -> Curve? {
        switch style {
        case .hardware: return nil
        case .softBlocks: return reduceMotion ? .reducedMovement : .softPress
        case .flatHardware, .sticker: return .press
        }
    }
}

/// A key's press in a style other than Real Hardware (see `StyledPressRule`),
/// which passes the content through untouched.
///
/// Only the press animates. The transform follows a drawn copy of `pressed`
/// that changes inside its own `withAnimation`, so whatever else the click
/// changes in the label (a lamp lighting, a legend swapping) keeps its own
/// animation instead of riding the press curve, and the slab under the key
/// (which reads `\.styledPressed`) moves its shadow or base in step.
///
/// The transform moves the key's hit area with it. `StyledKeyButtonStyle` pins
/// its content shape outside the press; a caller using this modifier outside
/// that button style must pin its own `contentShape` after it, or a click near
/// a small key's edge ends outside the key and never fires.
struct StyledPress: ViewModifier {
    @Environment(\.interfaceStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let pressed: Bool
    var depth: CGFloat = 2.5
    /// `pressed` as currently drawn; follows `pressed` under the press curve.
    @State private var shownPressed: Bool

    init(pressed: Bool, depth: CGFloat = 2.5) {
        self.pressed = pressed
        self.depth = depth
        _shownPressed = State(initialValue: pressed)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let curve = StyledPressRule.curve(style: style, reduceMotion: reduceMotion) {
            let transform = StyledPressRule.transform(style: style, pressed: shownPressed, depth: depth)
            content
                .environment(\.styledPressed, shownPressed)
                .scaleEffect(transform.scale)
                .offset(x: transform.x, y: transform.y)
                .onChange(of: pressed) { newValue in
                    withAnimation(curve.animation) { shownPressed = newValue }
                }
        } else {
            content
        }
    }
}

/// The hover lift plus the style's press, for keys drawn with `StyledSlab`.
/// Only for a style other than Real Hardware; Real keys keep their own style.
///
/// The hit area is pinned to `hitShape` outside the press, so it is the same
/// in every style however the key moves.
struct StyledKeyButtonStyle: ButtonStyle {
    var depth: CGFloat = 2.5
    var hitShape = AnyShape(Rectangle())

    init(depth: CGFloat = 2.5, hitShape: AnyShape = AnyShape(Rectangle())) {
        self.depth = depth
        self.hitShape = hitShape
    }

    func makeBody(configuration: Configuration) -> some View {
        KeyBody(configuration: configuration, depth: depth, hitShape: hitShape)
    }

    private struct KeyBody: View {
        let configuration: Configuration
        let depth: CGFloat
        let hitShape: AnyShape
        @Environment(\.carbon) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .brightness(brightness)
                .modifier(StyledPress(pressed: configuration.isPressed, depth: depth))
                // After the press: the key moves, its hit area does not.
                .contentShape(hitShape)
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
