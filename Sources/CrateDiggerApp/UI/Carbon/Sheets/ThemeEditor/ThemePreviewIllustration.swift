import CrateDiggerCore
import SwiftUI

// The theme editor's illustrated preview: the full window, the mini player and
// the compact player drawn as a simplified picture of today's console ("Real
// Hardware"), in a theme's real colours and fonts, so a Simple draft can be
// seen before it is applied. It does not embed the real views: they need
// `LibraryViewModel`, and a snapshot of them flattens the shell materials.
//
// Every shape is tagged with the job (`ThemeJob`) whose colour paints it, so
// hovering a palette swatch or a job name can light those parts and dim the
// rest (`previewJob`). The drawing reads the theme, the highlight and the
// interface style the illustration is shown in (`\.interfaceStyle`): the case,
// the panels, the keys and the caps take that style's finish in miniature, as
// the real primitives do, and the display glass and the album art, which are
// content, never change. Real Hardware draws exactly as it always has.
//
// Where the illustration shows a theme that is not the open draft (Simple's
// candidate, a snapshot of a sample), the caller sets that theme's style on it.
//
// Sizes are fixed, in points: full window 600 × 400, mini 200 × 350, compact
// 470 × 150. Show it at 1:1. The album art is planned for the size it is drawn
// at and the display's backing scale, so scaling the illustration would put
// the cover screen's grid between device pixels.

/// Which screens the illustration draws.
enum PreviewScreen: CaseIterable, Hashable {
    case fullWindow, mini, compact
}

struct ThemePreviewIllustration: View {
    @Environment(\.interfaceStyle) private var style
    let theme: CarbonTheme
    /// The theme's font roles (`"display"`, `"mono"`, `"sans"`). nil draws the
    /// active theme's, which is right for Advanced, whose draft *is* the
    /// active theme; Simple passes its draft's flattened `fonts` (an empty
    /// dictionary for the shipped faces), since the app keeps the saved
    /// theme's fonts until Apply.
    let fonts: [String: ThemeFont]?
    let highlighted: Set<ThemeJob>
    let screens: Set<PreviewScreen>

    init(theme: CarbonTheme,
         fonts: [String: ThemeFont]? = nil,
         highlighted: Set<ThemeJob> = [],
         screens: Set<PreviewScreen> = Set(PreviewScreen.allCases)) {
        self.theme = theme
        self.fonts = fonts
        self.highlighted = highlighted
        self.screens = screens
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if screens.contains(.fullWindow) || screens.contains(.mini) {
                HStack(alignment: .bottom, spacing: 16) {
                    if screens.contains(.fullWindow) {
                        captioned("Full window") { PreviewFullWindow() }
                    }
                    if screens.contains(.mini) {
                        captioned("Mini player") { PreviewMiniPlayer() }
                    }
                }
            }
            if screens.contains(.compact) {
                captioned("Compact player") { PreviewCompactPlayer() }
            }
        }
        .environment(\.carbon, theme)
        // Soft Blocks' fills separated for this theme, not the app's: nil
        // (no colour maths) under every other style.
        .environment(\.softSurfaces, InterfaceStyleDelivery.softSurfaces(for: style, theme: theme))
        .environment(\.themePreviewHighlight, highlighted)
        .environment(\.themePreviewFonts, ThemePreviewFonts(overrides: fonts))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Theme preview")
        .accessibilityValue(accessibilityDescription)
    }

    private func captioned<Content: View>(_ caption: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var accessibilityDescription: String {
        let names = PreviewScreen.allCases.filter(screens.contains).map { screen -> String in
            switch screen {
            case .fullWindow: return "full window"
            case .mini: return "mini player"
            case .compact: return "compact player"
            }
        }
        guard !highlighted.isEmpty else { return names.joined(separator: ", ") }
        let jobs = ThemeJob.allCases.filter(highlighted.contains).map(\.label).joined(separator: ", ")
        return names.joined(separator: ", ") + "; showing " + jobs
    }

    /// Renders every cover picture the illustration draws for `theme` at
    /// `scale`, blocking. The view renders them itself off the main thread;
    /// this is for callers that need them ready before the first frame (a
    /// one-shot `ImageRenderer` never runs the view's tasks).
    static func prepareCovers(for theme: CarbonTheme, scale: CGFloat) {
        for (side, screen) in [(PreviewFullWindow.coverSide, false),
                               (PreviewMiniPlayer.artSide, true),
                               (PreviewCompactPlayer.artSide, true)] {
            let request = ThemePreviewCoverStore.Request(theme: theme, side: side, scale: scale)
            let spec = screen ? CoverScreenSpec(theme: theme, side: side, scale: scale) : nil
            _ = ThemePreviewCoverStore.picture(for: request, spec: spec)
        }
    }
}

// MARK: - Job tags

extension View {
    /// Tags a shape with the job whose colour paints it: dimmed to 0.16 while
    /// some job is highlighted and this is not one of them.
    func previewJob(_ job: ThemeJob, highlighted: Set<ThemeJob>) -> some View {
        let dimmed = !highlighted.isEmpty && !highlighted.contains(job)
        return opacity(dimmed ? 0.16 : 1)
            .animation(CarbonMotion.hover, value: dimmed)
    }

    /// `previewJob(_:highlighted:)` with the highlight the illustration put in
    /// the environment.
    func previewJob(_ job: ThemeJob) -> some View {
        modifier(PreviewJobTag(job: job))
    }

    /// Album art, which no job paints: dimmed whenever any job is highlighted.
    func previewArt() -> some View {
        modifier(PreviewArtTag())
    }
}

private struct PreviewJobTag: ViewModifier {
    @Environment(\.themePreviewHighlight) private var highlighted
    let job: ThemeJob

    func body(content: Content) -> some View {
        content.previewJob(job, highlighted: highlighted)
    }
}

private struct PreviewArtTag: ViewModifier {
    @Environment(\.themePreviewHighlight) private var highlighted

    func body(content: Content) -> some View {
        let dimmed = !highlighted.isEmpty
        content
            .opacity(dimmed ? 0.16 : 1)
            .animation(CarbonMotion.hover, value: dimmed)
    }
}

private struct ThemePreviewHighlightKey: EnvironmentKey {
    static let defaultValue: Set<ThemeJob> = []
}

private struct ThemePreviewFontsKey: EnvironmentKey {
    static let defaultValue = ThemePreviewFonts(overrides: nil)
}

extension EnvironmentValues {
    /// The jobs the illustration is showing; empty shows every part at full.
    var themePreviewHighlight: Set<ThemeJob> {
        get { self[ThemePreviewHighlightKey.self] }
        set { self[ThemePreviewHighlightKey.self] = newValue }
    }

    fileprivate var themePreviewFonts: ThemePreviewFonts {
        get { self[ThemePreviewFontsKey.self] }
        set { self[ThemePreviewFontsKey.self] = newValue }
    }
}

// MARK: - Fonts

/// `CarbonFont`'s faces for a given set of font roles rather than the active
/// theme's, so the preview can show a draft's fonts while the app keeps the
/// saved theme's. The same rule as `CarbonFont`: a named face for the weight
/// is drawn as is, otherwise the base face with the weight synthesised. Fixed
/// sizes, since an illustration does not follow Dynamic Type.
struct ThemePreviewFonts {
    let overrides: [String: ThemeFont]?

    private func override(_ role: String) -> ThemeFont? {
        (overrides ?? ActiveThemeFonts.overrides)[role]
    }

    private func themed(_ font: ThemeFont, _ size: CGFloat, _ weight: Font.Weight) -> Font {
        let themeWeight = weight.themeWeight
        let custom = Font.custom(font.resolvedFace(for: themeWeight), fixedSize: size)
        return font.face(for: themeWeight) != nil ? custom : custom.weight(weight)
    }

    func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let font = override("display") { return themed(font, size, weight) }
        return Font.custom(CarbonFont.displayFamily, fixedSize: size).weight(weight)
    }

    func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let font = override("mono") { return themed(font, size, weight) }
        switch weight {
        case .bold, .heavy, .black: return Font.custom(CarbonFont.monoBold, fixedSize: size)
        case .semibold:             return Font.custom(CarbonFont.monoSemibold, fixedSize: size)
        case .medium:               return Font.custom(CarbonFont.monoMedium, fixedSize: size)
        default:                    return Font.custom(CarbonFont.monoFamily, fixedSize: size).weight(weight)
        }
    }

    func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let font = override("sans") { return themed(font, size, weight) }
        switch weight {
        case .black, .heavy: return Font.custom(CarbonFont.sansExtraBold, fixedSize: size)
        case .bold:          return Font.custom(CarbonFont.sansBold, fixedSize: size)
        case .semibold:      return Font.custom(CarbonFont.sansSemibold, fixedSize: size)
        case .medium:        return Font.custom(CarbonFont.sansMedium, fixedSize: size)
        default:             return Font.custom(CarbonFont.sansFamily, fixedSize: size).weight(weight)
        }
    }
}

// MARK: - What the screens show

/// The starter album, whose cover is the sample art.
private enum PreviewTrack {
    static let title = "DIGGIN'"
    static let artist = "CRATEDIGGER"
    static let album = "THE CRATEDIGGER MANUAL"
    static let subtitle = "CRATEDIGGER · THE CRATEDIGGER MANUAL · 2026"
    static let time = "00:42"
    static let total = "03:15"
    static let progress: CGFloat = 0.22
}

// MARK: - Placement

private extension View {
    /// Places the view in a rectangle of its parent board (a top-leading
    /// `ZStack` of fixed size), in the board's own points.
    /// `clipped` cuts the content at the rectangle, for type that a theme's
    /// font may set wider or taller than the shipped one.
    func at(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
            alignment: Alignment = .center, clipped: Bool = false) -> some View {
        frame(width: width, height: height, alignment: alignment)
            .modifier(ClipsWhen(on: clipped))
            .position(x: x + width / 2, y: y + height / 2)
    }

    func at(_ rect: CGRect, alignment: Alignment = .center) -> some View {
        at(rect.minX, rect.minY, rect.width, rect.height, alignment: alignment)
    }
}

private struct ClipsWhen: ViewModifier {
    let on: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if on { content.clipped() } else { content }
    }
}

/// A fixed-size drawing surface whose children place themselves with `at`.
private struct Board<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            content()
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }
}

private extension CarbonTheme {
    /// What the display draws with: the theme, or its single-phosphor version
    /// for a monochrome panel, as `OLEDDisplay` does.
    var previewGlass: CarbonTheme { oledMonochrome ? monochromeGlass : self }

    /// The job of an accent drawn on the glass. A monochrome panel has
    /// already collapsed it onto the phosphor, which is screen text.
    var glassAccentJob: ThemeJob { oledMonochrome ? .screenText : .accent }
}

/// The styles' finish at the illustration's size, about half the console's
/// (`StyledKeyMetrics`, `RecessedWell`, `SiliconeCap`, the case's outline): a
/// key's base band or hard shadow, a well's, a cap's, and Sticker's outlines.
/// Real Hardware reads none of these.
private enum PreviewStyleMetrics {
    static let keyDepth: CGFloat = 1.25
    static let keyOutline: CGFloat = 1
    static let wellDepth: CGFloat = 1.5
    static let wellOutline: CGFloat = 1
    static let capDepth: CGFloat = 1.5
    static let capOutline: CGFloat = 1
    /// The mini player's seek knob, smaller than any key.
    static let knobDepth: CGFloat = 1
    static let knobOutline: CGFloat = 0.75
    static let caseOutline: CGFloat = 1.5
}

// MARK: - Parts

/// One line of type, never wrapped.
private struct PreviewType: View {
    let text: String
    let font: Font
    let color: Color
    var tracking: CGFloat = 0

    init(_ text: String, _ font: Font, _ color: Color, tracking: CGFloat = 0) {
        self.text = text
        self.font = font
        self.color = color
        self.tracking = tracking
    }

    var body: some View {
        Text(text)
            .font(font)
            .tracking(tracking)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }
}

/// A line of text in a list, drawn as a rounded bar.
private struct PreviewBar: View {
    let color: Color

    var body: some View {
        Capsule(style: .continuous).fill(color)
    }
}

/// The case: the chassis colour with its diagonal light, a highlight along
/// the top and a shadow line along the bottom, and the shell material as a
/// flat tint.
private struct PreviewChassis: View {
    @Environment(\.carbon) private var theme
    @Environment(\.interfaceStyle) private var style
    let cornerRadius: CGFloat

    @ViewBuilder
    var body: some View {
        if style == .hardware {
            realCase
        } else {
            styledCase
        }
    }

    private var realCase: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape
            .fill(theme.chassis)
            .overlay(shape.fill(LinearGradient(
                colors: [theme.chassisHi.opacity(theme.isDark ? 0.28 : 0.54),
                         theme.chassis.opacity(theme.isDark ? 0.30 : 0.44),
                         theme.chassisLo.opacity(theme.isDark ? 0.36 : 0.34)],
                startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(shape.fill(materialTint))
            .overlay(shape.strokeBorder(LinearGradient(
                stops: [.init(color: theme.chassisHi, location: 0),
                        .init(color: theme.chassisHi.opacity(0), location: 0.10),
                        .init(color: theme.chassisLo.opacity(0), location: 0.90),
                        .init(color: theme.chassisLo, location: 1)],
                startPoint: .top, endPoint: .bottom), lineWidth: 1.2))
            .depthShadow(color: .black.opacity(theme.isDark ? 0.45 : 0.18), radius: 8, y: 4)
            .previewJob(.frame)
    }

    /// `StyledCasePlate` in miniature: Sticker's inked edge, Flat Hardware's
    /// top-lit ramp with a light lip and a shaded foot, Soft Blocks' plain
    /// fill. The material's wash sits under the edges; the corner is the
    /// case's own, as in the console.
    private var styledCase: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let lip = PreviewStyleMetrics.caseOutline
        return ZStack {
            if style == .flatHardware {
                shape.fill(LinearGradient(colors: [theme.chassisHi, theme.chassis, theme.chassisLo],
                                          startPoint: .top, endPoint: .bottom))
            } else {
                shape.fill(theme.chassis)
            }
            shape.fill(materialTint)
            if style == .sticker {
                shape.strokeBorder(theme.stickerInk, lineWidth: lip)
            } else if style == .flatHardware {
                shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(theme.isDark ? 0.25 : 0.9), .clear],
                                                  startPoint: .top, endPoint: .center), lineWidth: lip)
                shape.strokeBorder(LinearGradient(colors: [.clear, Color.black.opacity(theme.isDark ? 0.5 : 0.22)],
                                                  startPoint: .center, endPoint: .bottom), lineWidth: lip * 1.7)
            }
        }
        .depthShadow(color: .black.opacity(theme.isDark ? 0.45 : 0.18), radius: 8, y: 4)
        .previewJob(.frame)
    }

    /// The shell material as a flat wash only: the real textures are drawn
    /// with blend modes a snapshot cannot carry, and at this size their
    /// strokes would only read as noise. Metal and plastic catch a little
    /// light; the weave and the grain darken.
    private var materialTint: Color {
        guard let material = theme.shellMaterial else { return .clear }
        let strength = theme.shellMaterialStrength
        switch material {
        case .plastic: return Color.white.opacity(strength * 0.8)
        case .brushed: return Color.white.opacity(strength * 0.9)
        case .blasted: return Color.white.opacity(strength * 0.6)
        case .weave:   return Color.black.opacity(strength * 0.6)
        case .grain:   return Color.black.opacity(strength * 0.3)
        }
    }
}

/// A recessed well: the well colour falling to `wellDeep`, its upper inner
/// edge in `wellDeep`'s shadow.
private struct PreviewWell: View {
    @Environment(\.carbon) private var theme
    @Environment(\.interfaceStyle) private var style
    @Environment(\.softSurfaces) private var softSurfaces
    let cornerRadius: CGFloat

    @ViewBuilder
    var body: some View {
        if style == .hardware {
            realWell
        } else {
            // `RecessedWell`'s slab, cut into the case.
            StyledSlab(shape: CarbonGeometry.styledShape(cornerRadius, for: style),
                       fill: softSurfaces?.well ?? theme.well, hi: theme.well, lo: theme.wellDeep,
                       depth: PreviewStyleMetrics.wellDepth, sunken: true, outline: PreviewStyleMetrics.wellOutline)
                .previewJob(.panels)
        }
    }

    private var realWell: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape
            .fill(theme.well)
            .overlay(shape.fill(LinearGradient(
                colors: [theme.well.opacity(theme.isDark ? 0.42 : 0.58), theme.wellDeep.opacity(0.42)],
                startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(shape.stroke(theme.wellDeep, lineWidth: 2.5).blur(radius: 0.8).offset(y: 1).mask(shape))
            .overlay(shape.strokeBorder(LinearGradient(
                colors: [Color.black.opacity(theme.isDark ? 0.40 : 0.12),
                         theme.hair.opacity(theme.isDark ? 0.5 : 0.6),
                         Color.white.opacity(theme.isDark ? 0.10 : 0.70)],
                startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
            .previewJob(.panels)
    }
}

/// A paper panel: a sheet set into the case.
private struct PreviewPaper: View {
    @Environment(\.carbon) private var theme
    @Environment(\.interfaceStyle) private var style
    @Environment(\.softSurfaces) private var softSurfaces
    let cornerRadius: CGFloat

    @ViewBuilder
    var body: some View {
        if style == .hardware {
            realPaper
        } else {
            // `PaperPanel`'s slab: cut into the case, no cast shadow.
            StyledSlab(shape: CarbonGeometry.styledShape(cornerRadius, for: style),
                       fill: softSurfaces?.paper ?? theme.paper, hi: theme.paper, lo: theme.paper2,
                       depth: PreviewStyleMetrics.wellDepth, sunken: true, outline: PreviewStyleMetrics.wellOutline)
                .previewJob(.panels)
        }
    }

    private var realPaper: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape
            .fill(theme.paper)
            .overlay(shape.fill(LinearGradient(
                colors: [theme.paper.opacity(theme.isDark ? 0.62 : 0.78),
                         theme.paper2.opacity(theme.isDark ? 0.54 : 0.68)],
                startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(shape.strokeBorder(LinearGradient(
                colors: [Color.white.opacity(theme.isDark ? 0.16 : 0.86),
                         theme.hair.opacity(theme.isDark ? 0.58 : 0.70),
                         Color.black.opacity(theme.isDark ? 0.42 : 0.07)],
                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75))
            .depthShadow(color: .black.opacity(theme.isDark ? 0.45 : 0.12), radius: 6, y: 3)
            .previewJob(.panels)
    }
}

/// A chassis key: a metal face with a lit top edge and a shaded bottom one,
/// its legend as a bar of `chassisInk`, and an optional lamp.
private struct PreviewKey: View {
    @Environment(\.carbon) private var theme
    @Environment(\.interfaceStyle) private var style
    @Environment(\.softSurfaces) private var softSurfaces
    var cornerRadius: CGFloat = 3.5
    /// The legend's length as a share of the key's width; 0 for none.
    var legend: CGFloat = 0.5
    var lamp: Color?
    /// Where the legend starts: centred, or after a lamp or icon at the left.
    var centred: Bool = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        GeometryReader { proxy in
            let size = proxy.size
            let legendHeight = max(2, min(3, size.height * 0.2))
            let legendWidth = size.width * legend
            ZStack(alignment: .topLeading) {
                if style == .hardware {
                shape
                    .fill(theme.metalLo)
                    .offset(y: 1)
                    .previewJob(.frame)
                shape
                    .fill(theme.metal)
                    .overlay(shape.fill(LinearGradient(
                        colors: [theme.metalHi.opacity(theme.isDark ? 0.40 : 0.70),
                                 theme.metal.opacity(theme.isDark ? 0.30 : 0.40),
                                 theme.metalLo.opacity(theme.isDark ? 0.46 : 0.42)],
                        startPoint: .top, endPoint: .bottom)))
                    .overlay(shape.strokeBorder(LinearGradient(
                        stops: [.init(color: theme.metalHi, location: 0),
                                .init(color: theme.metalHi.opacity(0), location: 0.4),
                                .init(color: theme.metalLo.opacity(0), location: 0.6),
                                .init(color: theme.metalLo, location: 1)],
                        startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
                    .previewJob(.frame)
                } else {
                    // `KeyChrome`'s slab, rounded as the style rounds keys.
                    StyledSlab(shape: CarbonGeometry.styledShape(cornerRadius, for: style),
                               fill: softSurfaces?.metal ?? theme.metal, hi: theme.metalHi, lo: theme.metalLo,
                               depth: PreviewStyleMetrics.keyDepth, outline: PreviewStyleMetrics.keyOutline)
                        .previewJob(.frame)
                }
                if let lamp {
                    Circle()
                        .fill(lamp)
                        .shadow(color: lamp.opacity(0.7), radius: 1.5)
                        .at(5, size.height / 2 - 1.5, 3, 3)
                        .previewJob(.accent)
                }
                if legend > 0 {
                    let x = centred ? (size.width - legendWidth) / 2 : (lamp == nil ? 6 : 11)
                    PreviewBar(color: theme.chassisInk.opacity(0.85))
                        .at(x, (size.height - legendHeight) / 2, legendWidth, legendHeight)
                        .previewJob(.text)
                }
            }
        }
    }
}

/// A silicone transport cap: rubber over metal, the legend printed under its
/// surface, and the transport lamp behind it when lit.
private struct PreviewCap<S: InsettableShape>: View {
    @Environment(\.carbon) private var theme
    @Environment(\.interfaceStyle) private var style
    @Environment(\.softSurfaces) private var softSurfaces
    let shape: S
    let side: CGFloat
    let symbol: String
    var glyph: CGFloat
    var lit: Bool = false

    var body: some View {
        let radius = side * 0.62
        ZStack {
            if style == .hardware {
            shape
                .fill(RadialGradient(colors: [theme.metalHi, theme.metal, theme.metalLo],
                                     center: UnitPoint(x: 0.5, y: 0.34), startRadius: 0.5, endRadius: radius))
                .depthShadow(color: .black.opacity(theme.isDark ? 0.5 : 0.22), radius: 3, y: 2)
                .previewJob(.frame)
            if lit {
                shape
                    .fill(RadialGradient(colors: [theme.transportLampHi.opacity(0.92),
                                                  theme.transportLamp.opacity(0.74),
                                                  theme.transportLampLo.opacity(0.46)],
                                         center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0.5,
                                         endRadius: radius * 0.94))
                    .shadow(color: theme.transportLamp.opacity(0.3), radius: 5)
                    .previewJob(.accent)
            }
            } else {
                styledCap
            }
            Image(systemName: symbol)
                .font(.system(size: glyph, weight: .semibold))
                .foregroundStyle(lit ? Color.black.opacity(0.34) : theme.chassisInk.opacity(0.82))
                .previewJob(lit ? .accent : .text)
            if style == .hardware {
            shape
                .inset(by: 0.5)
                .fill(LinearGradient(colors: [.white.opacity(theme.isDark ? 0.10 : 0.22), .clear],
                                     startPoint: .top, endPoint: .center))
                .previewJob(.frame)
            }
        }
        .frame(width: side, height: side)
    }

    /// `SiliconeCap`'s styled cap: unlit the theme's metal, lit the transport
    /// lamp is the whole cap. Only Flat Hardware keeps the lamp's halo.
    /// The cap keeps its own shape in every style, as the console's does.
    private var styledCap: some View {
        StyledSlab(shape: shape,
                   fill: lit ? theme.transportLamp : (softSurfaces?.metal ?? theme.metal),
                   hi: lit ? theme.transportLampHi : theme.metalHi,
                   lo: lit ? theme.transportLampLo : theme.metalLo,
                   depth: PreviewStyleMetrics.capDepth, outline: PreviewStyleMetrics.capOutline)
            .shadow(color: theme.transportLamp.opacity(lit && style == .flatHardware ? 0.3 : 0), radius: 5)
            .previewJob(lit ? .accent : .frame)
    }
}

/// The display glass: the surface, its inner stroke and the raking shade.
private struct PreviewGlass: View {
    @Environment(\.carbon) private var theme
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(theme.oledSurface)
            .overlay(shape.strokeBorder(theme.oledStrokeInner, lineWidth: 1.5))
            .overlay(LinearGradient(colors: [Color.white.opacity(theme.isDark ? 0.04 : 0.08), .clear,
                                             theme.oledSurfaceShade],
                                    startPoint: .topLeading, endPoint: .bottomTrailing).clipShape(shape))
            .overlay(shape.strokeBorder(Color.white.opacity(theme.isDark ? 0.08 : 0.22), lineWidth: 0.5))
            .contentShadow(color: .black.opacity(0.45), radius: 3, y: 2)
            .previewJob(.glass)
    }
}

/// The brand lockup: the crate glyph and the name in the display face.
private struct PreviewBrand: View {
    @Environment(\.carbon) private var theme
    @Environment(\.themePreviewFonts) private var fonts
    let typeSize: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: typeSize * 0.35) {
            ZStack {
                BrandGlyph(ink: theme.ink, accent: .clear).previewJob(.text)
                BrandGlyph(ink: .clear, accent: theme.orange).previewJob(.accent)
            }
            .frame(width: typeSize * 1.1, height: typeSize * 1.1)
            // Shrinks rather than runs into the keys beside it, as the real
            // lockup does, when a theme's display face is wide.
            Text("CrateDigger")
                .font(fonts.display(typeSize))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .previewJob(.text)
        }
    }
}

// MARK: - The NOW screen

/// The display on its NOW screen, as the full window and the compact player
/// show it: the annunciator rail, the title and the time under it, the LED
/// matrix hung off the fourth cell, and the cell rail with the position line.
private struct PreviewNowScreen: View {
    @Environment(\.carbon) private var theme
    @Environment(\.themePreviewFonts) private var fonts
    let width: CGFloat
    let height: CGFloat

    private static let padH: CGFloat = 10
    private static let railHeight: CGFloat = 21
    private static let cornerRadius: CGFloat = 8

    var body: some View {
        let glass = theme.previewGlass
        let innerWidth = width - 2 * Self.padH
        let railTop = height - 4 - Self.railHeight
        let matrixLeading = Self.padH + Self.textLeading(ofColumn: 3, in: innerWidth)
        Board(width: width, height: height) {
            PreviewGlass(cornerRadius: Self.cornerRadius).at(0, 0, width, height)
            annunciators(glass).at(Self.padH, 4, innerWidth, 9, alignment: .trailing)
            // The titles top-left and the time reading under them, in one
            // column so a theme's taller type pushes the reading down rather
            // than over it; cut at the matrix's gutter, as the real pane is.
            // Each line is held to its type size, not its font's line box: a
            // pixel face's box is half again as tall and pushed the time
            // reading off the glass.
            VStack(alignment: .leading, spacing: 2) {
                PreviewType(PreviewTrack.title, fonts.display(23, weight: .thin), glass.oledForeground,
                            tracking: -0.2)
                    .frame(height: 25, alignment: .leading)
                PreviewType(PreviewTrack.subtitle, fonts.mono(5, weight: .semibold),
                            glass.oledForegroundMuted, tracking: 0.9)
                    .frame(height: 6, alignment: .leading)
                Spacer(minLength: 1)
                HStack(spacing: 3) {
                    PreviewType(PreviewTrack.time, fonts.mono(6, weight: .bold), glass.oledForeground)
                    PreviewType("/ " + PreviewTrack.total, fonts.mono(6, weight: .bold),
                                glass.oledForeground.opacity(0.4))
                }
            }
            .previewJob(.screenText)
            .at(Self.padH, 13, matrixLeading - Self.padH - 8, railTop - 15, alignment: .topLeading,
                clipped: true)
            PreviewMatrix(glass: glass)
                .at(matrixLeading, 17, width - Self.padH - matrixLeading, railTop - 21)
            cells(glass).at(Self.padH, railTop, innerWidth, Self.railHeight)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
    }

    /// The screen names along the top, NOW lit.
    private func annunciators(_ glass: CarbonTheme) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(["NOW", "CNVRT", "SCAN", "SYNC", "CD", "DEV"].enumerated()), id: \.offset) { index, name in
                let lit = index == 0
                HStack(spacing: 1.5) {
                    Circle()
                        .fill(lit ? glass.lampNow : glass.oledForeground.opacity(0.22))
                        .frame(width: 2.2, height: 2.2)
                    PreviewType(name, fonts.mono(4.5, weight: .bold),
                                lit ? glass.lampNow : glass.oledForeground.opacity(0.28), tracking: 0.6)
                }
            }
        }
        .previewJob(.screenText)
    }

    private struct Cell {
        let key: String
        let value: String
        let sub: String
    }

    private static let cellData = [
        Cell(key: "TRACK", value: "01 / 12", sub: "12 TOTAL"),
        Cell(key: "FORMAT", value: "FLAC", sub: "LOSSLESS"),
        Cell(key: "BITRATE", value: "912 kbps", sub: "VARIABLE"),
        Cell(key: "SAMPLE", value: "44.1 kHz", sub: "16-BIT"),
        Cell(key: "SIZE", value: "22.4 MB", sub: "FILE SIZE"),
    ]

    private static let cellPadding: CGFloat = 5

    /// Where a cell's text starts, as `OLEDCells.textLeading` works it out.
    static func textLeading(ofColumn index: Int, in width: CGFloat) -> CGFloat {
        guard index > 0 else { return 0 }
        let cellWidth = (width - CGFloat(Self.cellData.count - 1)) / CGFloat(Self.cellData.count)
        return CGFloat(index) * (cellWidth + 1) + cellPadding
    }

    private func cells(_ glass: CarbonTheme) -> some View {
        ZStack(alignment: .topLeading) {
            // The position line along the rail's top edge, filled as it plays.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(glass.oledForeground.opacity(0.12)).previewJob(.screenText)
                    Rectangle().fill(glass.orange)
                        .frame(width: proxy.size.width * PreviewTrack.progress)
                        .shadow(color: glass.orange.opacity(0.6), radius: 1.5)
                        .previewJob(theme.glassAccentJob)
                }
            }
            .frame(height: 0.75)
            HStack(spacing: 0) {
                ForEach(Array(Self.cellData.enumerated()), id: \.offset) { index, cell in
                    if index > 0 {
                        Rectangle().fill(glass.oledForeground.opacity(0.12)).frame(width: 1)
                            .padding(.vertical, 3)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        PreviewType(cell.key, fonts.mono(4, weight: .semibold),
                                    glass.oledForeground.opacity(0.45), tracking: 0.8)
                            .frame(height: 4.5, alignment: .leading)
                        PreviewType(cell.value, fonts.mono(7, weight: .bold), glass.oledForeground,
                                    tracking: 0.2)
                            .frame(height: 8, alignment: .leading)
                        PreviewType(cell.sub, fonts.mono(4, weight: .semibold),
                                    glass.oledForeground.opacity(0.55), tracking: 0.6)
                            .frame(height: 4.5, alignment: .leading)
                    }
                    .padding(.leading, index > 0 ? Self.cellPadding : 0)
                    .padding(.top, 3)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .clipped()
                }
            }
            .previewJob(.screenText)
        }
    }
}

/// The NOW screen's 12 × 6 LED matrix on one frame of its Vertical VU: two
/// halves mirrored from the edges, the loud tops in Meter High.
private struct PreviewMatrix: View {
    let glass: CarbonTheme

    /// Lit segments per column, left to right.
    private static let levels = [4, 6, 5, 3, 2, 1, 1, 2, 3, 5, 6, 4]

    var body: some View {
        GeometryReader { proxy in
            let layout = MatrixLayout(size: proxy.size, columns: 12, rows: 6)
            ZStack(alignment: .topLeading) {
                ForEach(0..<12, id: \.self) { column in
                    ForEach(0..<6, id: \.self) { row in
                        let rect = layout.rect(column: column, row: row)
                        let level = Self.levels[column]
                        let lit = row < level
                        let hot = lit && row >= 4
                        RoundedRectangle(cornerRadius: min(1, rect.height * 0.3), style: .continuous)
                            .fill(lit ? (hot ? glass.meterHot : glass.cyan) : glass.oledForeground.opacity(0.07))
                            .shadow(color: lit ? (hot ? glass.meterHot : glass.cyan).opacity(0.5) : .clear,
                                    radius: 1.2)
                            .at(rect)
                    }
                }
            }
        }
        .previewJob(.screenText)
    }
}

// MARK: - The footer

/// The bottom shelf in today's order: POSITION, the transport (three keys
/// either side of the PLAY dome), VOLUME.
private struct PreviewFooter: View {
    @Environment(\.carbon) private var theme
    @Environment(\.interfaceStyle) private var style
    @Environment(\.themePreviewFonts) private var fonts
    let width: CGFloat
    let height: CGFloat
    let keySide: CGFloat
    let domeSide: CGFloat
    let keySpacing: CGFloat
    let padding: CGFloat

    var body: some View {
        let transportWidth = 6 * keySide + domeSide + 6 * keySpacing
        let podWidth = max(0, (width - transportWidth - 4 * padding) / 2)
        let podHeight = min(height - 12, 32)
        let podY = (height - podHeight) / 2
        Board(width: width, height: height) {
            shelf.at(0, 0, width, height)
            pod("POSITION", fill: nil).at(padding, podY, podWidth, podHeight)
            transport.at(2 * padding + podWidth, 0, transportWidth, height)
            pod("VOLUME", fill: 0.62).at(width - padding - podWidth, podY, podWidth, podHeight)
        }
    }

    @ViewBuilder
    private var shelf: some View {
        if style == .hardware {
            realShelf
        } else {
            // `FooterShell`'s shelf: the case's own colour, cut in like a well.
            StyledSlab(shape: CarbonGeometry.styledShape(6, for: style),
                       fill: theme.chassis, hi: theme.chassis, lo: theme.chassisLo,
                       depth: PreviewStyleMetrics.wellDepth, sunken: true, outline: PreviewStyleMetrics.wellOutline)
                .previewJob(.frame)
        }
    }

    private var realShelf: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return shape
            .fill(theme.chassis)
            .overlay(shape.fill(LinearGradient(
                colors: [theme.chassisHi.opacity(theme.isDark ? 0.24 : 0.42),
                         theme.chassis.opacity(theme.isDark ? 0.26 : 0.34),
                         theme.chassisLo.opacity(theme.isDark ? 0.34 : 0.26)],
                startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(shape.strokeBorder(Color.white.opacity(theme.isDark ? 0.12 : 0.62), lineWidth: 0.75))
            .previewJob(.frame)
    }

    private var transport: some View {
        let key = RoundedRectangle(cornerRadius: keySide * 0.26, style: .continuous)
        let glyph = keySide * 0.4
        return HStack(spacing: keySpacing) {
            PreviewCap(shape: key, side: keySide, symbol: "shuffle", glyph: glyph)
            PreviewCap(shape: key, side: keySide, symbol: "backward.end.fill", glyph: glyph)
            PreviewCap(shape: key, side: keySide, symbol: "gobackward.10", glyph: glyph)
            PreviewCap(shape: Circle(), side: domeSide, symbol: "playpause.fill", glyph: domeSide * 0.3, lit: true)
            PreviewCap(shape: key, side: keySide, symbol: "goforward.10", glyph: glyph)
            PreviewCap(shape: key, side: keySide, symbol: "forward.end.fill", glyph: glyph)
            PreviewCap(shape: key, side: keySide, symbol: "repeat", glyph: glyph)
        }
    }

    /// A footer pod: its label over a rail. VOLUME's rail is lit from cyan up
    /// to Meter High; POSITION's is a bare track with its thumb.
    private func pod(_ label: String, fill: CGFloat?) -> some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let railY = h * 0.62
            let railX: CGFloat = 7
            let railWidth = max(0, w - 2 * railX)
            let thumbX = railX + railWidth * (fill ?? PreviewTrack.progress)
            Board(width: w, height: h) {
                PreviewWell(cornerRadius: 5).at(0, 0, w, h)
                PreviewType(label, fonts.mono(4.5, weight: .bold), theme.ink3, tracking: 1)
                    .previewJob(.text)
                    .at(railX, 4, railWidth, 7, alignment: .leading)
                Capsule().fill(theme.wellDeep).previewJob(.panels)
                    .at(railX, railY - 1.25, railWidth, 2.5)
                if let fill {
                    Capsule()
                        .fill(LinearGradient(colors: [theme.cyan, theme.meterHot],
                                             startPoint: .leading, endPoint: .trailing))
                        .previewJob(.accent)
                        .at(railX, railY - 1.25, railWidth * fill, 2.5)
                }
                PreviewKey(cornerRadius: 1.5, legend: 0)
                    .at(thumbX - 2.5, railY - 5, 5, 10)
            }
        }
    }
}

// MARK: - Full window

private struct PreviewFullWindow: View {
    @Environment(\.carbon) private var theme
    @Environment(\.themePreviewFonts) private var fonts

    static let size = CGSize(width: 600, height: 400)
    /// The inspector's cover; never a cover screen.
    static let coverSide: CGFloat = 112

    // Half of the real console's measures (`CarbonLayout`), rounded.
    private static let insetH: CGFloat = 9
    private static let insetV: CGFloat = 8
    private static let gap: CGFloat = 6
    private static let headerHeight: CGFloat = 85
    private static let footerHeight: CGFloat = 46
    private static let brandWidth: CGFloat = 80
    private static let switchWidth: CGFloat = 58
    private static let sidebarWidth: CGFloat = 116
    private static let inspectorWidth: CGFloat = 158

    var body: some View {
        let w = Self.size.width, h = Self.size.height
        let headerY = Self.insetV
        let panesY = headerY + Self.headerHeight + Self.gap
        let footerY = h - Self.insetV - Self.footerHeight
        let panesHeight = footerY - Self.gap - panesY
        let displayX = Self.insetH + Self.brandWidth + Self.gap
        let displayWidth = w - 2 * Self.insetH - Self.brandWidth - Self.switchWidth - 2 * Self.gap
        let browserX = Self.insetH + Self.sidebarWidth + Self.gap
        let browserWidth = w - 2 * Self.insetH - Self.sidebarWidth - Self.inspectorWidth - 2 * Self.gap
        Board(width: w, height: h) {
            PreviewChassis(cornerRadius: 12).at(0, 0, w, h)
            brandColumn.at(Self.insetH, headerY, Self.brandWidth, Self.headerHeight)
            PreviewNowScreen(width: displayWidth, height: Self.headerHeight)
                .at(displayX, headerY, displayWidth, Self.headerHeight)
            switchColumn.at(w - Self.insetH - Self.switchWidth, headerY, Self.switchWidth, Self.headerHeight)
            PreviewSources(width: Self.sidebarWidth, height: panesHeight)
                .at(Self.insetH, panesY, Self.sidebarWidth, panesHeight)
            PreviewBrowser(width: browserWidth, height: panesHeight)
                .at(browserX, panesY, browserWidth, panesHeight)
            PreviewInspector(width: Self.inspectorWidth, height: panesHeight)
                .at(w - Self.insetH - Self.inspectorWidth, panesY, Self.inspectorWidth, panesHeight)
            PreviewFooter(width: w - 2 * Self.insetH, height: Self.footerHeight,
                          keySide: 23, domeSide: 36, keySpacing: 6, padding: 14)
                .at(Self.insetH, footerY, w - 2 * Self.insetH, Self.footerHeight)
        }
    }

    /// The brand row and the four action keys: DIG CRATE, RESCAN, ADD TO
    /// CRATE (its icon lit), TRANSFER TO.
    private var brandColumn: some View {
        let w = Self.brandWidth
        return Board(width: w, height: Self.headerHeight) {
            PreviewBrand(typeSize: 6.5).at(0, 6, w - 27, 10, alignment: .leading)
            PreviewKey(cornerRadius: 3, legend: 0).at(w - 23, 4, 10, 10)
            PreviewKey(cornerRadius: 3, legend: 0).at(w - 11, 4, 10, 10)
            ForEach(0..<4, id: \.self) { index in
                PreviewKey(legend: [0.42, 0.34, 0.5, 0.46][index], lamp: index == 2 ? theme.orange : nil)
                    .at(0, 21 + CGFloat(index) * 16.5, w, 13)
            }
        }
    }

    /// The theme's name, the display-mode key with its lamp strip, and the
    /// VIEW, THEME and EQ keys with their option lamps.
    private var switchColumn: some View {
        let w = Self.switchWidth
        return Board(width: w, height: Self.headerHeight) {
            PreviewType(theme.name.uppercased(), fonts.display(6.5), theme.chassisInk, tracking: 0.6)
                .previewJob(.text)
                .at(0, 5, w, 10, alignment: .trailing)
            ZStack {
                PreviewKey(legend: 0)
                Capsule().fill(theme.lampNow)
                    .shadow(color: theme.lampNow.opacity(0.6), radius: 1.5)
                    .padding(.horizontal, 7)
                    .frame(height: 2.5)
                    .previewJob(.accent)
            }
            .at(0, 21, w, 13)
            ForEach(0..<3, id: \.self) { index in
                ZStack(alignment: .trailing) {
                    PreviewKey(legend: [0.3, 0.38, 0.22][index])
                    Circle().fill(theme.keyLamp)
                        .frame(width: 2.6, height: 2.6)
                        .shadow(color: theme.keyLamp.opacity(0.7), radius: 1.5)
                        .padding(.trailing, 6)
                        .opacity(index == 1 ? 1 : 0.35)
                        .previewJob(.accent)
                }
                .at(0, 37.5 + CGFloat(index) * 16.5, w, 13)
            }
        }
    }
}

/// A pane's title in its corner, the way SOURCES, BROWSER and INSPECTOR are
/// set: small spaced mono caps in `ink3`.
private struct PaneLabel: View {
    @Environment(\.carbon) private var theme
    @Environment(\.themePreviewFonts) private var fonts
    let text: String

    var body: some View {
        PreviewType(text, fonts.mono(5.5, weight: .bold), theme.ink3, tracking: 1.2)
            .previewJob(.text)
    }
}

/// A selected row: the selection slot (its LED and the light it spreads),
/// which belongs to the accent.
private struct PreviewSelection: View {
    var body: some View {
        CarbonSelectionSlot(cornerRadius: 2)
            .previewJob(.accent)
    }
}

private struct PreviewSources: View {
    @Environment(\.carbon) private var theme
    let width: CGFloat
    let height: CGFloat

    /// Section headings (nil width) and rows (name length as a share).
    private static let rows: [CGFloat?] = [nil, 0.42, nil, 0.5, 0.34, 0.46, 0.58, 0.4, nil, 0.62, nil, 0.4, 0.3]

    var body: some View {
        let wellX: CGFloat = 5
        let wellY: CGFloat = 16
        let wellWidth = width - 2 * wellX
        Board(width: width, height: height) {
            PreviewPaper(cornerRadius: 5).at(0, 0, width, height)
            PaneLabel(text: "SOURCES").at(8, 4, 60, 9, alignment: .leading)
            PreviewWell(cornerRadius: 5).at(wellX, wellY, wellWidth, height - wellY - 5)
            ForEach(Array(Self.rows.enumerated()), id: \.offset) { index, row in
                let y = wellY + 6 + CGFloat(index) * 13.5
                if let row {
                    let selected = index == 3
                    if selected {
                        PreviewSelection().at(wellX + 2, y - 2, wellWidth - 4, 12)
                    }
                    RoundedRectangle(cornerRadius: 1).stroke(theme.ink3, lineWidth: 0.8)
                        .previewJob(.text)
                        .at(wellX + 8, y + 2, 5, 5)
                    PreviewBar(color: selected ? theme.selectionInk : theme.ink)
                        .previewJob(.text)
                        .at(wellX + 17, y + 3, (wellWidth - 36) * row, 3)
                    PreviewBar(color: theme.ink3)
                        .previewJob(.text)
                        .at(wellX + wellWidth - 12, y + 3, 6, 3)
                } else {
                    PreviewBar(color: theme.ink4)
                        .previewJob(.text)
                        .at(wellX + 6, y + 4, 34, 2)
                }
            }
        }
    }
}

private struct PreviewBrowser: View {
    @Environment(\.carbon) private var theme
    @Environment(\.themePreviewFonts) private var fonts
    let width: CGFloat
    let height: CGFloat

    private static let artists: [CGFloat] = [0.5, 0.72, 0.4, 0.8, 0.46, 0.6, 0.38, 0.55, 0.44]
    private static let albums: [CGFloat] = [0.82]
    private static let tracks: [CGFloat] = [0.66, 0.84, 0.58, 0.76, 0.5, 0.7, 0.8, 0.62, 0.54, 0.74, 0.6, 0.68,
                                            0.48, 0.72, 0.56]

    var body: some View {
        let wellX: CGFloat = 5
        let wellY: CGFloat = 16
        let wellWidth = width - 2 * wellX
        let columnWidth = wellWidth / 3
        let listY = wellY + 32
        Board(width: width, height: height) {
            PreviewPaper(cornerRadius: 5).at(0, 0, width, height)
            PaneLabel(text: "BROWSER · LIBRARY").at(8, 4, 120, 9, alignment: .leading)
            PreviewWell(cornerRadius: 5).at(wellX, wellY, wellWidth, height - wellY - 5)
            // The search field.
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(theme.paper2)
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(theme.hair, lineWidth: 0.6))
                    .previewJob(.panels)
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 5.5, weight: .semibold))
                        .foregroundStyle(theme.ink3)
                    PreviewBar(color: theme.ink3).frame(width: 52, height: 2.5)
                }
                .padding(.leading, 6)
                .previewJob(.text)
            }
            .at(wellX + 5, wellY + 5, wellWidth - 10, 11)
            ForEach(0..<3, id: \.self) { column in
                let x = wellX + CGFloat(column) * columnWidth
                if column > 0 {
                    Rectangle().fill(theme.hair).previewJob(.panels)
                        .at(x, wellY + 20, 0.75, height - wellY - 27)
                }
                PreviewType(["ARTIST", "ALBUM", "TRACK"][column], fonts.mono(5, weight: .bold),
                            theme.columnHeaderInk, tracking: 1)
                    .previewJob(.text)
                    .at(x + 7, wellY + 21, columnWidth - 10, 8, alignment: .leading)
                Rectangle().fill(theme.hair).previewJob(.panels)
                    .at(x + 3, listY - 2, columnWidth - 6, 0.6)
                list(column: column, x: x, y: listY, width: columnWidth)
            }
        }
    }

    @ViewBuilder
    private func list(column: Int, x: CGFloat, y: CGFloat, width: CGFloat) -> some View {
        let rows = [Self.artists, Self.albums, Self.tracks][column]
        let selected = [1, 0, 0][column]
        ForEach(Array(rows.enumerated()), id: \.offset) { index, share in
            let rowY = y + CGFloat(index) * 11.5
            if index % 2 == 1 {
                Rectangle().fill(theme.rowAlt).previewJob(.panels).at(x + 1, rowY, width - 2, 11.5)
            }
            if index == selected {
                PreviewSelection().at(x + 2, rowY + 0.5, width - 4, 10.5)
            }
            if column == 2 {
                PreviewBar(color: theme.ink3).previewJob(.text).at(x + 7, rowY + 4.25, 6, 3)
            }
            let textX = x + (column == 2 ? 17 : 9)
            PreviewBar(color: index == selected ? theme.selectionInk : theme.ink)
                .previewJob(.text)
                .at(textX, rowY + 4.25, (width - (textX - x) - 18) * share, 3)
            PreviewBar(color: theme.ink3).previewJob(.text).at(x + width - 13, rowY + 4.25, 7, 3)
        }
    }
}

private struct PreviewInspector: View {
    @Environment(\.carbon) private var theme
    @Environment(\.interfaceStyle) private var style
    @Environment(\.themePreviewFonts) private var fonts
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let inner = width - 16
        let coverSide = PreviewFullWindow.coverSide
        let coverY: CGFloat = 36
        let textY = coverY + coverSide + 8
        Board(width: width, height: height) {
            PreviewPaper(cornerRadius: 5).at(0, 0, width, height)
            PaneLabel(text: "INSPECTOR").at(8, 4, 60, 9, alignment: .leading)
            // INFO, lit, then QUEUE, ART and DISC.
            ForEach(0..<4, id: \.self) { index in
                let tabWidth = (inner - 9) / 4
                let tabX = 8 + CGFloat(index) * (tabWidth + 3)
                if index == 0 {
                    ZStack {
                        if style == .hardware {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(LinearGradient(colors: [theme.orangeHi, theme.orange],
                                                 startPoint: .top, endPoint: .bottom))
                            .previewJob(.accent)
                        } else {
                            // A selected `KeyButton`: the accent, in the style's finish.
                            StyledSlab(shape: CarbonGeometry.styledShape(3, for: style), fill: theme.orange,
                                       hi: theme.orangeHi, lo: theme.orangeLo,
                                       depth: PreviewStyleMetrics.keyDepth, outline: PreviewStyleMetrics.keyOutline)
                                .previewJob(.accent)
                        }
                        PreviewBar(color: Color.white.opacity(0.9)).frame(width: tabWidth * 0.42, height: 2.5)
                            .previewJob(.accent)
                    }
                    .at(tabX, 17, tabWidth, 11)
                } else {
                    PreviewKey(cornerRadius: 3, legend: 0.42, centred: true).at(tabX, 17, tabWidth, 11)
                }
            }
            ThemePreviewCover(side: coverSide, cornerRadius: 3, allowsScreen: false)
                .at((width - coverSide) / 2, coverY, coverSide, coverSide)
            PreviewType("Diggin'", fonts.sans(9.5, weight: .bold), theme.ink)
                .previewJob(.text)
                .at(8, textY, inner, 12, alignment: .leading)
            PreviewType(PreviewTrack.artist, fonts.mono(5, weight: .semibold), theme.ink2, tracking: 1)
                .previewJob(.text)
                .at(8, textY + 13, inner, 7, alignment: .leading)
            Rectangle().fill(theme.hair).previewJob(.panels).at(8, textY + 23, inner, 0.6)
            ForEach(0..<3, id: \.self) { index in
                let rowY = textY + 29 + CGFloat(index) * 8
                PreviewBar(color: theme.ink3).previewJob(.text).at(8, rowY, 18, 2.5)
                PreviewBar(color: theme.ink).previewJob(.text).at(40, rowY, [26, 18, 34][index], 2.5)
            }
            HStack(spacing: 2.5) {
                ForEach(0..<5, id: \.self) { _ in
                    Image(systemName: "star.fill").font(.system(size: 5)).foregroundStyle(theme.orange)
                }
            }
            .previewJob(.accent)
            .at(8, textY + 53, inner, 7, alignment: .trailing)
            PreviewBar(color: theme.ink3).previewJob(.text).at(8, textY + 55.25, 22, 2.5)
            ForEach(0..<3, id: \.self) { index in
                let keyWidth = (inner - 6) / 3
                PreviewKey(cornerRadius: 3, legend: 0.44, centred: true)
                    .at(8 + CGFloat(index) * (keyWidth + 3), height - 19, keyWidth, 12)
            }
        }
    }
}

// MARK: - Mini player

private struct PreviewMiniPlayer: View {
    @Environment(\.carbon) private var theme
    @Environment(\.interfaceStyle) private var style
    @Environment(\.softSurfaces) private var softSurfaces
    @Environment(\.themePreviewFonts) private var fonts

    static let size = CGSize(width: 200, height: 350)
    static let artSide: CGFloat = 180

    var body: some View {
        let w = Self.size.width, h = Self.size.height
        let pad: CGFloat = 10
        let artY: CGFloat = 34
        let screenY = artY + Self.artSide + 9
        let screenHeight: CGFloat = 52
        let transportY = screenY + screenHeight + 8
        let dome: CGFloat = 40
        let key: CGFloat = 29
        Board(width: w, height: h) {
            PreviewChassis(cornerRadius: 16).at(0, 0, w, h)
            // NOW PLAYING and the three chrome keys.
            HStack(spacing: 5) {
                Circle().fill(theme.keyLamp).frame(width: 4.4, height: 4.4)
                    .shadow(color: theme.keyLamp.opacity(0.8), radius: 2)
                    .previewJob(.accent)
                PreviewType("NOW PLAYING", fonts.mono(6.5, weight: .bold), theme.ink3, tracking: 1.5)
                    .previewJob(.text)
            }
            .at(pad + 1, 12, 100, 14, alignment: .leading)
            ForEach(0..<3, id: \.self) { index in
                ZStack {
                    PreviewKey(cornerRadius: 5, legend: 0)
                    Image(systemName: ["list.bullet", "opticaldisc", "pip.exit"][index])
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(theme.ink3)
                        .previewJob(.text)
                }
                .at(w - pad - 18 - CGFloat(2 - index) * 22, 10, 18, 18)
            }
            ThemePreviewCover(side: Self.artSide, cornerRadius: 10)
                .at(pad, artY, Self.artSide, Self.artSide)
            miniScreen.at(pad, screenY, w - 2 * pad, screenHeight)
            HStack(spacing: 4.5) {
                let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                PreviewCap(shape: shape, side: key, symbol: "shuffle", glyph: 9.5)
                PreviewCap(shape: shape, side: key, symbol: "backward.end.fill", glyph: 9.5)
                PreviewCap(shape: Circle(), side: dome, symbol: "playpause.fill", glyph: 12.5, lit: true)
                PreviewCap(shape: shape, side: key, symbol: "forward.end.fill", glyph: 9.5)
                PreviewCap(shape: shape, side: key, symbol: "repeat", glyph: 9.5)
            }
            .at(pad, transportY, w - 2 * pad, dome)
            seekRail.at(pad + 2, h - pad - 10, w - 2 * pad - 4, 8)
        }
    }

    /// The mini display: the title in the display face, the band and the
    /// album under it, the time at the right in the accent. The theme's own
    /// accent even on a monochrome panel: the real mini player draws its
    /// glass straight from the theme (`MiniPlayerTimeReadout` reads
    /// `theme.orange`), and only `OLEDDisplay` collapses onto the phosphor.
    private var miniScreen: some View {
        let glass = theme.previewGlass
        return ZStack(alignment: .topLeading) {
            PreviewGlass(cornerRadius: 7.5)
            VStack(alignment: .leading, spacing: 3) {
                PreviewType(PreviewTrack.title, fonts.display(13.5, weight: .thin), glass.oledForeground,
                            tracking: -0.3)
                    .previewJob(.screenText)
                PreviewType(PreviewTrack.artist, fonts.mono(7, weight: .semibold),
                            glass.oledForeground.opacity(0.52), tracking: 1.4)
                    .previewJob(.screenText)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Not fixed: the album gives way to the time, truncated.
                    Text(PreviewTrack.album)
                        .font(fonts.mono(7, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(glass.oledForeground.opacity(0.52))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .previewJob(.screenText)
                    PreviewType("0:42 / 3:15", fonts.mono(7, weight: .bold), theme.orange)
                        .previewJob(.accent)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7.5, style: .continuous))
    }

    /// The seek rail: a groove with its knob at the play position.
    private var seekRail: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let x = w * PreviewTrack.progress
            Board(width: w, height: proxy.size.height) {
                Capsule().fill(theme.wellDeep)
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                    .previewJob(.panels)
                    .at(0, 2.75, w, 2.5)
                Capsule().fill(theme.orange).previewJob(.accent).at(0, 2.75, x, 2.5)
                if style == .hardware {
                Circle()
                    .fill(RadialGradient(colors: [theme.metalHi, theme.metal], center: .init(x: 0.5, y: 0.3),
                                         startRadius: 0.5, endRadius: 5))
                    .depthShadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                    .previewJob(.frame)
                    .at(x - 4, 0, 8, 8)
                } else {
                    StyledSlab(shape: Circle(), fill: softSurfaces?.metal ?? theme.metal,
                               hi: theme.metalHi, lo: theme.metalLo,
                               depth: PreviewStyleMetrics.knobDepth, outline: PreviewStyleMetrics.knobOutline)
                        .previewJob(.frame)
                        .at(x - 4, 0, 8, 8)
                }
            }
        }
    }
}

// MARK: - Compact player

private struct PreviewCompactPlayer: View {
    @Environment(\.carbon) private var theme

    static let size = CGSize(width: 470, height: 150)
    static let artSide: CGFloat = 112

    private static let insetH: CGFloat = 9
    private static let insetV: CGFloat = 7
    private static let gap: CGFloat = 6
    private static let footerHeight: CGFloat = 46

    var body: some View {
        let w = Self.size.width, h = Self.size.height
        let columnX = Self.insetH + Self.artSide + Self.gap
        let columnWidth = w - columnX - Self.insetH
        let displayHeight = h - 2 * Self.insetV - Self.gap - Self.footerHeight
        let artY = h - Self.insetV - Self.artSide
        Board(width: w, height: h) {
            PreviewChassis(cornerRadius: 12).at(0, 0, w, h)
            PreviewBrand(typeSize: 6.5).at(Self.insetH, artY - 15, 80, 11, alignment: .leading)
            ZStack {
                PreviewKey(cornerRadius: 3, legend: 0)
                Image(systemName: "rectangle.expand.vertical")
                    .font(.system(size: 5.5, weight: .bold))
                    .foregroundStyle(theme.chassisInk)
                    .previewJob(.text)
            }
            .at(Self.insetH + Self.artSide - 14, artY - 15, 14, 10)
            ThemePreviewCover(side: Self.artSide, cornerRadius: 6)
                .at(Self.insetH, artY, Self.artSide, Self.artSide)
            PreviewNowScreen(width: columnWidth, height: displayHeight)
                .at(columnX, Self.insetV, columnWidth, displayHeight)
            PreviewFooter(width: columnWidth, height: Self.footerHeight,
                          keySide: 20, domeSide: 32, keySpacing: 4.5, padding: 8)
                .at(columnX, h - Self.insetV - Self.footerHeight, columnWidth, Self.footerHeight)
        }
    }
}

// MARK: - Previews

#if DEBUG
private enum ThemePreviewSamples {
    @MainActor
    static func theme(_ id: String, appearance: ThemeDefinition.BaseAppearance = .dark)
        -> (theme: CarbonTheme, fonts: [String: ThemeFont], style: InterfaceStyle) {
        guard let manifest = ThemeRegistry.shared.manifest(for: id) else {
            return (appearance == .dark ? .carbon : .linen, [:], .hardware)
        }
        let target = manifest.definition.isAdaptive ? appearance : manifest.definition.baseAppearance
        let definition = manifest.definition.resolved(for: target)
        let base: CarbonTheme = definition.baseAppearance == .dark ? .carbon : .linen
        var theme = CarbonTheme(definition: definition, resolvedBase: base)
        theme.name = definition.name
        theme.id = definition.id
        return (theme, definition.fonts ?? [:], manifest.definition.resolvedStyle)
    }
}

#Preview("Carbon") {
    let sample = ThemePreviewSamples.theme("carbon")
    return ThemePreviewIllustration(theme: sample.theme, fonts: sample.fonts)
        .environment(\.interfaceStyle, sample.style)
        .padding()
}

#Preview("Llama '97, Frame") {
    let sample = ThemePreviewSamples.theme("llama-97")
    return ThemePreviewIllustration(theme: sample.theme, fonts: sample.fonts, highlighted: [.frame])
        .environment(\.interfaceStyle, sample.style)
        .padding()
}

#Preview("Pocket, players") {
    let sample = ThemePreviewSamples.theme("pocket")
    return ThemePreviewIllustration(theme: sample.theme, fonts: sample.fonts, screens: [.mini, .compact])
        .environment(\.interfaceStyle, sample.style)
        .padding()
}
#endif
