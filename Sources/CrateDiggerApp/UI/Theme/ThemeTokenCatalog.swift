import AppKit
import CoreText
import CrateDiggerCore
import SwiftUI

/// The editor's map of what a theme actually contains: every token, the group
/// it belongs to, and the human label for it. `ThemeDefinition` stores tokens
/// as bare string-keyed dictionaries (that's what makes the format open to
/// third parties), so this is where those keys get names, an order, and — for
/// geometry — the range a dial may travel.
///
/// Keys here must match `CarbonTheme.init(definition:resolvedBase:)` and
/// `CarbonGeometry.init(definition:)` exactly; a typo shows up as a control
/// that silently does nothing. The `read` key path is what keeps them honest:
/// it's the same field the renderer reads, so the editor always seeds a
/// swatch from the value actually on screen.
enum ThemeTokenCatalog {

    // MARK: - Colors

    struct ColorToken {
        let key: String
        let label: String
        let read: KeyPath<CarbonTheme, Color>
    }

    struct ColorGroup: Identifiable {
        let name: String
        let tokens: [ColorToken]
        var id: String { name }
    }

    static let colorGroups: [ColorGroup] = [
        ColorGroup(name: "Chassis", tokens: [
            ColorToken(key: "chassis", label: "Base", read: \.chassis),
            ColorToken(key: "chassisHi", label: "Highlight", read: \.chassisHi),
            ColorToken(key: "chassisLo", label: "Shade", read: \.chassisLo),
            ColorToken(key: "chassisDeep", label: "Deep", read: \.chassisDeep),
        ]),
        ColorGroup(name: "Wells & Paper", tokens: [
            ColorToken(key: "well", label: "Well", read: \.well),
            ColorToken(key: "wellDeep", label: "Well Deep", read: \.wellDeep),
            ColorToken(key: "paper", label: "Paper", read: \.paper),
            ColorToken(key: "paper2", label: "Paper Alt", read: \.paper2),
        ]),
        ColorGroup(name: "Ink", tokens: [
            ColorToken(key: "ink", label: "Primary", read: \.ink),
            ColorToken(key: "ink2", label: "Secondary", read: \.ink2),
            ColorToken(key: "ink3", label: "Tertiary", read: \.ink3),
            ColorToken(key: "ink4", label: "Quaternary", read: \.ink4),
            ColorToken(key: "hair", label: "Hairline", read: \.hair),
        ]),
        ColorGroup(name: "Accents", tokens: [
            ColorToken(key: "orange", label: "Accent", read: \.orange),
            ColorToken(key: "orangeHi", label: "Accent Hi", read: \.orangeHi),
            ColorToken(key: "orangeLo", label: "Accent Lo", read: \.orangeLo),
            ColorToken(key: "sun", label: "Sun", read: \.sun),
            ColorToken(key: "sunHi", label: "Sun Hi", read: \.sunHi),
            ColorToken(key: "sunLo", label: "Sun Lo", read: \.sunLo),
            ColorToken(key: "cyan", label: "Cyan", read: \.cyan),
            ColorToken(key: "cyanGlow", label: "Cyan Glow", read: \.cyanGlow),
            ColorToken(key: "red", label: "Red", read: \.red),
            ColorToken(key: "indigo", label: "Indigo", read: \.indigo),
        ]),
        ColorGroup(name: "Metal", tokens: [
            ColorToken(key: "metalHi", label: "Highlight", read: \.metalHi),
            ColorToken(key: "metal", label: "Base", read: \.metal),
            ColorToken(key: "metalLo", label: "Shade", read: \.metalLo),
            ColorToken(key: "metalDeep", label: "Deep", read: \.metalDeep),
        ]),
        ColorGroup(name: "Background", tokens: [
            ColorToken(key: "backgroundBase", label: "Base", read: \.backgroundBase),
            ColorToken(key: "backgroundGradientStart", label: "Gradient Top", read: \.backgroundGradientStart),
            ColorToken(key: "backgroundGradientEnd", label: "Gradient Bottom", read: \.backgroundGradientEnd),
        ]),
        ColorGroup(name: "OLED Glass", tokens: [
            ColorToken(key: "oledSurface", label: "Surface", read: \.oledSurface),
            ColorToken(key: "oledStrokeInner", label: "Inner Stroke", read: \.oledStrokeInner),
            ColorToken(key: "oledForeground", label: "Phosphor", read: \.oledForeground),
            ColorToken(key: "oledForegroundMuted", label: "Phosphor Muted", read: \.oledForegroundMuted),
            ColorToken(key: "onAir", label: "On Air", read: \.onAir),
        ]),
        ColorGroup(name: "Selection", tokens: [
            ColorToken(key: "selectionLedCore", label: "LED Core", read: \.selectionLedCore),
            ColorToken(key: "selectionInk", label: "Selected Ink", read: \.selectionInk),
        ]),
    ]

    /// Flat list, for search and for seeding a draft with every token.
    static let allColorTokens: [ColorToken] = colorGroups.flatMap(\.tokens)

    // MARK: - Geometry

    struct GeometryToken: Identifiable {
        let key: String
        let label: String
        let range: ClosedRange<CGFloat>
        let read: KeyPath<CarbonGeometry, CGFloat>
        var id: String { key }
    }

    struct GeometryGroup: Identifiable {
        let name: String
        let tokens: [GeometryToken]
        var id: String { name }
    }

    /// Ranges come from `CarbonGeometry.Bounds` rather than being restated, so
    /// a dial can never park on a value the constructor then clamps away.
    static let geometryGroups: [GeometryGroup] = [
        GeometryGroup(name: "Corners", tokens: [
            GeometryToken(key: "chassisCornerRadius", label: "Chassis",
                          range: CarbonGeometry.Bounds.cornerRadius, read: \.chassisCornerRadius),
            GeometryToken(key: "wellCornerRadius", label: "Well",
                          range: CarbonGeometry.Bounds.cornerRadius, read: \.wellCornerRadius),
            GeometryToken(key: "paperCornerRadius", label: "Paper",
                          range: CarbonGeometry.Bounds.cornerRadius, read: \.paperCornerRadius),
            GeometryToken(key: "oledCornerRadius", label: "OLED",
                          range: CarbonGeometry.Bounds.cornerRadius, read: \.oledCornerRadius),
        ]),
        GeometryGroup(name: "Spacing", tokens: [
            GeometryToken(key: "chassisInsetH", label: "Inset H",
                          range: CarbonGeometry.Bounds.inset, read: \.chassisInsetH),
            GeometryToken(key: "chassisInsetV", label: "Inset V",
                          range: CarbonGeometry.Bounds.inset, read: \.chassisInsetV),
            GeometryToken(key: "chassisRowGap", label: "Row Gap",
                          range: CarbonGeometry.Bounds.gap, read: \.chassisRowGap),
            GeometryToken(key: "mainGap", label: "Pane Gap",
                          range: CarbonGeometry.Bounds.gap, read: \.mainGap),
            GeometryToken(key: "wellPadding", label: "Well Pad",
                          range: CarbonGeometry.Bounds.inset, read: \.wellPadding),
            GeometryToken(key: "oledPaddingH", label: "OLED Pad H",
                          range: CarbonGeometry.Bounds.inset, read: \.oledPaddingH),
            GeometryToken(key: "oledPaddingV", label: "OLED Pad V",
                          range: CarbonGeometry.Bounds.inset, read: \.oledPaddingV),
        ]),
        GeometryGroup(name: "Panes", tokens: [
            GeometryToken(key: "headerHeight", label: "Header",
                          range: CarbonGeometry.Bounds.headerFooterHeight, read: \.headerHeight),
            GeometryToken(key: "footerHeight", label: "Footer",
                          range: CarbonGeometry.Bounds.headerFooterHeight, read: \.footerHeight),
            GeometryToken(key: "sidebarWidth", label: "Sources",
                          range: CarbonGeometry.Bounds.paneWidth, read: \.sidebarWidth),
            GeometryToken(key: "inspectorWidth", label: "Inspector",
                          range: CarbonGeometry.Bounds.paneWidth, read: \.inspectorWidth),
            GeometryToken(key: "brandWidth", label: "Brand",
                          range: CarbonGeometry.Bounds.paneWidth, read: \.brandWidth),
            GeometryToken(key: "viewSwitchWidth", label: "Switcher",
                          range: CarbonGeometry.Bounds.switcherWidth, read: \.viewSwitchWidth),
        ]),
        GeometryGroup(name: "Controls", tokens: [
            GeometryToken(key: "transportButtonSize", label: "Transport",
                          range: CarbonGeometry.Bounds.button, read: \.transportButtonSize),
            GeometryToken(key: "playButtonSize", label: "Play Dome",
                          range: CarbonGeometry.Bounds.button, read: \.playButtonSize),
            GeometryToken(key: "keyHeight", label: "Key Height",
                          range: CarbonGeometry.Bounds.smallControl, read: \.keyHeight),
            GeometryToken(key: "patchBayKeyHeight", label: "Patch Key",
                          range: CarbonGeometry.Bounds.smallControl, read: \.patchBayKeyHeight),
            GeometryToken(key: "patchBayCycleButtonHeight", label: "Patch Cycle",
                          range: CarbonGeometry.Bounds.button, read: \.patchBayCycleButtonHeight),
            GeometryToken(key: "patchBayRowGap", label: "Patch Gap",
                          range: CarbonGeometry.Bounds.gap, read: \.patchBayRowGap),
        ]),
    ]

    static let allGeometryTokens: [GeometryToken] = geometryGroups.flatMap(\.tokens)

    // MARK: - Fonts

    /// The three semantic roles `CarbonFont` consults. Everything in the app
    /// draws through one of them, so three is the whole typography surface.
    static let fontRoles: [(key: String, label: String, fallback: String)] = [
        ("sans", "Interface", CarbonFont.sansFamily),
        ("mono", "Mono", CarbonFont.monoFamily),
        ("display", "Display", CarbonFont.displayFamily),
    ]

    /// The PostScript name CoreText will know a font file by after
    /// registration — which is what `fonts` must record, since `Font.custom`
    /// resolves by PostScript name and not by filename or family.
    static func postScriptName(of url: URL) -> String? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String
        else { return nil }
        return name
    }
}

extension Color {
    /// Round-trips a rendered color back into the `"#RRGGBB"`/`"#RRGGBBAA"`
    /// form theme files use, so the editor can seed a field from whatever is
    /// currently on screen — including built-in tokens that were never written
    /// as hex in the first place (`Color.white.opacity(0.55)`).
    var themeHexString: String {
        // Themes are authored in sRGB (that's what `Color(hexString:)` parses
        // into); converting first keeps a round-trip lossless.
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        let channel = { (value: CGFloat) in Int((value * 255).rounded()) }
        let r = channel(srgb.redComponent)
        let g = channel(srgb.greenComponent)
        let b = channel(srgb.blueComponent)
        let a = channel(srgb.alphaComponent)
        return a >= 255
            ? String(format: "#%02X%02X%02X", r, g, b)
            : String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}
