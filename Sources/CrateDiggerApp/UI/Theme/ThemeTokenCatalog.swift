import AppKit
import CoreText
import CrateDiggerCore
import SwiftUI

/// The editor's map of what a theme actually contains: every token, the group
/// it belongs to, a label naming *what it paints*, and a note saying where
/// you'll see it.
///
/// `ThemeDefinition` stores tokens as bare string-keyed dictionaries (that's
/// what makes the format open to third parties), so this is where those keys
/// become something you can pick from a list without reading the source. Labels
/// deliberately describe the surface rather than transcribe the token name —
/// "Top Highlight" tells you what will change, `chassisHi` doesn't.
///
/// Keys here must match `CarbonTheme.init(definition:resolvedBase:)` and
/// `CarbonGeometry.init(definition:)` exactly; a typo shows up as a control
/// that silently does nothing. The `read` key path keeps them honest: it's the
/// same field the renderer reads, so the editor always seeds from the value
/// actually on screen.
enum ThemeTokenCatalog {

    // MARK: - Colors

    struct ColorToken {
        let key: String
        let label: String
        /// Shown on hover — where this color actually appears.
        let note: String
        let read: KeyPath<CarbonTheme, Color>
    }

    struct ColorGroup: Identifiable {
        let name: String
        let tokens: [ColorToken]
        var id: String { name }
    }

    static let colorGroups: [ColorGroup] = [
        ColorGroup(name: "Window Frame", tokens: [
            ColorToken(key: "chassis", label: "Frame",
                       note: "The main body panel behind everything — header, footer and pane surrounds.",
                       read: \.chassis),
            ColorToken(key: "chassisHi", label: "Top Highlight",
                       note: "Lit top edge of every raised panel and button.",
                       read: \.chassisHi),
            ColorToken(key: "chassisLo", label: "Bottom Shadow",
                       note: "Shaded bottom edge of raised panels — the other half of the bevel.",
                       read: \.chassisLo),
            ColorToken(key: "chassisDeep", label: "Deep Edge",
                       note: "Darkest frame tone, used for outer edges and drop shadows.",
                       read: \.chassisDeep),
        ]),
        ColorGroup(name: "Panels & Lists", tokens: [
            ColorToken(key: "well", label: "Recessed Well",
                       note: "The sunken tray the Sources, Browser and Inspector sit inside.",
                       read: \.well),
            ColorToken(key: "wellDeep", label: "Well Shadow",
                       note: "Inner shadow at the top of a recessed well.",
                       read: \.wellDeep),
            ColorToken(key: "paper", label: "List Background",
                       note: "Background of the track list, sidebar and inspector content.",
                       read: \.paper),
            ColorToken(key: "paper2", label: "Alternate Rows",
                       note: "Second list tone — alternating rows and nested sections.",
                       read: \.paper2),
        ]),
        ColorGroup(name: "Text", tokens: [
            ColorToken(key: "ink", label: "Primary Text",
                       note: "Track and album titles — the most important text.",
                       read: \.ink),
            ColorToken(key: "ink2", label: "Secondary Text",
                       note: "Artist names, values, body copy.",
                       read: \.ink2),
            ColorToken(key: "ink3", label: "Section Labels",
                       note: "The small uppercase headings like SOURCES and BROWSER.",
                       read: \.ink3),
            ColorToken(key: "ink4", label: "Faint Text",
                       note: "Durations, counts, hints — text you read only when you look for it.",
                       read: \.ink4),
            ColorToken(key: "hair", label: "Divider Lines",
                       note: "Hairline rules between rows, sections and panels.",
                       read: \.hair),
        ]),
        ColorGroup(name: "Accent Colors", tokens: [
            ColorToken(key: "orange", label: "Accent",
                       note: "The theme's signature color: active keys, selected rows, OPEN ARTWORK.",
                       read: \.orange),
            ColorToken(key: "orangeHi", label: "Accent Light",
                       note: "Lighter accent for gradients and hover states.",
                       read: \.orangeHi),
            ColorToken(key: "orangeLo", label: "Accent Dark",
                       note: "Darker accent for pressed states and gradient bottoms.",
                       read: \.orangeLo),
            ColorToken(key: "sun", label: "Amber",
                       note: "Secondary highlight — tips, warnings, the selection lamp.",
                       read: \.sun),
            ColorToken(key: "sunHi", label: "Amber Light",
                       note: "Lighter amber for gradients and glow.",
                       read: \.sunHi),
            ColorToken(key: "sunLo", label: "Amber Dark",
                       note: "Darker amber for gradient bottoms.",
                       read: \.sunLo),
            ColorToken(key: "cyan", label: "Teal",
                       note: "Meters, progress and 'in progress' indicators.",
                       read: \.cyan),
            ColorToken(key: "cyanGlow", label: "Teal Glow",
                       note: "Halo around lit meters and active indicators.",
                       read: \.cyanGlow),
            ColorToken(key: "red", label: "Alert Red",
                       note: "Errors, destructive actions, the record lamp.",
                       read: \.red),
            ColorToken(key: "indigo", label: "Info Blue",
                       note: "Informational badges and secondary status.",
                       read: \.indigo),
        ]),
        ColorGroup(name: "Buttons & Knobs", tokens: [
            ColorToken(key: "metalHi", label: "Button Highlight",
                       note: "Top edge of keys, knobs and transport buttons.",
                       read: \.metalHi),
            ColorToken(key: "metal", label: "Button Face",
                       note: "The main surface of every key and knob.",
                       read: \.metal),
            ColorToken(key: "metalLo", label: "Button Shadow",
                       note: "Lower half of a key's bevel.",
                       read: \.metalLo),
            ColorToken(key: "metalDeep", label: "Button Edge",
                       note: "Outer rim and cast shadow beneath keys.",
                       read: \.metalDeep),
        ]),
        ColorGroup(name: "Desktop Backdrop", tokens: [
            ColorToken(key: "backgroundBase", label: "Backdrop",
                       note: "The area behind the whole chassis, visible around the rounded corners.",
                       read: \.backgroundBase),
            ColorToken(key: "backgroundGradientStart", label: "Backdrop Top",
                       note: "Top of the backdrop gradient.",
                       read: \.backgroundGradientStart),
            ColorToken(key: "backgroundGradientEnd", label: "Backdrop Bottom",
                       note: "Bottom of the backdrop gradient.",
                       read: \.backgroundGradientEnd),
        ]),
        ColorGroup(name: "Display Screen", tokens: [
            ColorToken(key: "oledSurface", label: "Screen Glass",
                       note: "The dark glass of the big display in the header.",
                       read: \.oledSurface),
            ColorToken(key: "oledStrokeInner", label: "Screen Bezel",
                       note: "Inner rim around the display glass.",
                       read: \.oledStrokeInner),
            ColorToken(key: "oledForeground", label: "Screen Text",
                       note: "The phosphor glow the display's text is drawn in.",
                       read: \.oledForeground),
            ColorToken(key: "oledForegroundMuted", label: "Screen Text Dim",
                       note: "Secondary display text — timings, labels, counts.",
                       read: \.oledForegroundMuted),
            ColorToken(key: "onAir", label: "ON AIR Lamp",
                       note: "The live/now-playing indicator on the display.",
                       read: \.onAir),
        ]),
        ColorGroup(name: "Selected Rows", tokens: [
            ColorToken(key: "selectionLedCore", label: "Selection Lamp",
                       note: "The small lit dot marking the selected row in light themes.",
                       read: \.selectionLedCore),
            ColorToken(key: "selectionInk", label: "Selected Text",
                       note: "Text color over a selected row — keep it readable on the accent.",
                       read: \.selectionInk),
        ]),
    ]

    /// Flat list, for search and for seeding a draft with every token.
    static let allColorTokens: [ColorToken] = colorGroups.flatMap(\.tokens)

    // MARK: - Geometry

    struct GeometryToken: Identifiable {
        let key: String
        let label: String
        let note: String
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
        GeometryGroup(name: "Corner Roundness", tokens: [
            GeometryToken(key: "chassisCornerRadius", label: "Window",
                          note: "Roundness of the app's outer corners.",
                          range: CarbonGeometry.Bounds.cornerRadius, read: \.chassisCornerRadius),
            GeometryToken(key: "wellCornerRadius", label: "Panels",
                          note: "Roundness of the recessed wells around each pane.",
                          range: CarbonGeometry.Bounds.cornerRadius, read: \.wellCornerRadius),
            GeometryToken(key: "paperCornerRadius", label: "Lists",
                          note: "Roundness of list and content surfaces.",
                          range: CarbonGeometry.Bounds.cornerRadius, read: \.paperCornerRadius),
            GeometryToken(key: "oledCornerRadius", label: "Screen",
                          note: "Roundness of the big display glass.",
                          range: CarbonGeometry.Bounds.cornerRadius, read: \.oledCornerRadius),
        ]),
        GeometryGroup(name: "Padding & Gaps", tokens: [
            GeometryToken(key: "chassisInsetH", label: "Side Margin",
                          note: "Space between the window edge and the panes.",
                          range: CarbonGeometry.Bounds.inset, read: \.chassisInsetH),
            GeometryToken(key: "chassisInsetV", label: "Top Margin",
                          note: "Space above the header and below the footer.",
                          range: CarbonGeometry.Bounds.inset, read: \.chassisInsetV),
            GeometryToken(key: "chassisRowGap", label: "Row Gap",
                          note: "Gap between header, main area and footer.",
                          range: CarbonGeometry.Bounds.gap, read: \.chassisRowGap),
            GeometryToken(key: "mainGap", label: "Pane Gap",
                          note: "Gap between Sources, Browser and Inspector.",
                          range: CarbonGeometry.Bounds.gap, read: \.mainGap),
            GeometryToken(key: "wellPadding", label: "Well Padding",
                          note: "Space between a well's edge and its contents.",
                          range: CarbonGeometry.Bounds.inset, read: \.wellPadding),
            GeometryToken(key: "oledPaddingH", label: "Screen Pad ↔",
                          note: "Horizontal padding inside the display glass.",
                          range: CarbonGeometry.Bounds.inset, read: \.oledPaddingH),
            GeometryToken(key: "oledPaddingV", label: "Screen Pad ↕",
                          note: "Vertical padding inside the display glass.",
                          range: CarbonGeometry.Bounds.inset, read: \.oledPaddingV),
        ]),
        GeometryGroup(name: "Section Sizes", tokens: [
            GeometryToken(key: "headerHeight", label: "Header",
                          note: "Height of the top section holding the display.",
                          range: CarbonGeometry.Bounds.headerFooterHeight, read: \.headerHeight),
            GeometryToken(key: "footerHeight", label: "Footer",
                          note: "Height of the transport bar at the bottom.",
                          range: CarbonGeometry.Bounds.headerFooterHeight, read: \.footerHeight),
            GeometryToken(key: "sidebarWidth", label: "Sources",
                          note: "Width of the left-hand Sources sidebar.",
                          range: CarbonGeometry.Bounds.paneWidth, read: \.sidebarWidth),
            GeometryToken(key: "inspectorWidth", label: "Inspector",
                          note: "Width of the right-hand Inspector pane.",
                          range: CarbonGeometry.Bounds.paneWidth, read: \.inspectorWidth),
            GeometryToken(key: "brandWidth", label: "Brand Column",
                          note: "Width of the top-left column with the app name and library buttons.",
                          range: CarbonGeometry.Bounds.paneWidth, read: \.brandWidth),
            GeometryToken(key: "viewSwitchWidth", label: "Switch Column",
                          note: "Width of the top-right VIEW / THEME / EQ column.",
                          range: CarbonGeometry.Bounds.switcherWidth, read: \.viewSwitchWidth),
        ]),
        GeometryGroup(name: "Control Sizes", tokens: [
            GeometryToken(key: "transportButtonSize", label: "Transport",
                          note: "Diameter of the skip, back and shuffle buttons.",
                          range: CarbonGeometry.Bounds.button, read: \.transportButtonSize),
            GeometryToken(key: "playButtonSize", label: "Play Button",
                          note: "Diameter of the big play/pause dome.",
                          range: CarbonGeometry.Bounds.button, read: \.playButtonSize),
            GeometryToken(key: "keyHeight", label: "Buttons",
                          note: "Height of standard keys like EDIT TAGS and CLEANUP.",
                          range: CarbonGeometry.Bounds.smallControl, read: \.keyHeight),
            GeometryToken(key: "patchBayKeyHeight", label: "Convert Keys",
                          note: "Height of the keys in the CNVRT Patch Bay.",
                          range: CarbonGeometry.Bounds.smallControl, read: \.patchBayKeyHeight),
            GeometryToken(key: "patchBayCycleButtonHeight", label: "Convert Dials",
                          note: "Height of the Patch Bay's cycling selectors.",
                          range: CarbonGeometry.Bounds.button, read: \.patchBayCycleButtonHeight),
            GeometryToken(key: "patchBayRowGap", label: "Convert Gap",
                          note: "Spacing between Patch Bay rows.",
                          range: CarbonGeometry.Bounds.gap, read: \.patchBayRowGap),
        ]),
    ]

    static let allGeometryTokens: [GeometryToken] = geometryGroups.flatMap(\.tokens)

    // MARK: - Fonts

    /// The three semantic roles `CarbonFont` consults. Everything in the app
    /// draws through one of them, so three is the whole typography surface.
    static let fontRoles: [(key: String, label: String, note: String, fallback: String)] = [
        ("sans", "Interface",
         "Titles, artist names and body text throughout the app.",
         CarbonFont.sansFamily),
        ("mono", "Labels & Readouts",
         "The small uppercase headings, durations, counts and meter readouts.",
         CarbonFont.monoFamily),
        ("display", "Screen Titles",
         "The oversized text on the header display.",
         CarbonFont.displayFamily),
    ]

    /// Every font family installed on this Mac, sorted — the source for the
    /// editor's font menu. Computed once: `availableFontFamilies` walks the
    /// font registry, which is far too slow to touch from a view body.
    static let systemFontFamilies: [String] = NSFontManager.shared
        .availableFontFamilies
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    /// One selectable face within a family — what the VARIANT menu lists.
    struct FontFace: Identifiable, Hashable {
        /// PostScript name; what a theme records.
        let postScriptName: String
        /// AppKit's style name for it: "Regular", "Bold Italic", "Condensed Light".
        let styleName: String
        /// AppKit's 0–15 weight scale.
        let weight: Int
        let isItalic: Bool
        var id: String { postScriptName }
    }

    /// Every face in a family, ordered light → heavy with italics after their
    /// upright counterparts, so the menu reads the way a type specimen does.
    static func faces(inFamily family: String) -> [FontFace] {
        guard let members = NSFontManager.shared.availableMembers(ofFontFamily: family) else { return [] }

        return members.compactMap { member -> FontFace? in
            guard member.count >= 4,
                  let name = member[0] as? String,
                  let style = member[1] as? String,
                  let weight = member[2] as? Int,
                  let traits = member[3] as? UInt
            else { return nil }
            return FontFace(
                postScriptName: name,
                styleName: style,
                weight: weight,
                isItalic: traits & UInt(NSFontTraitMask.italicFontMask.rawValue) != 0
            )
        }
        .sorted { lhs, rhs in
            if lhs.isItalic != rhs.isItalic { return !lhs.isItalic }
            return lhs.weight < rhs.weight
        }
    }

    /// The face closest to an AppKit weight target, italics excluded — a theme
    /// picks its weights from the upright faces.
    private static func face(in faces: [FontFace], nearest target: Int) -> FontFace? {
        faces.filter { !$0.isItalic }
            .min { abs($0.weight - target) < abs($1.weight - target) }
    }

    /// Builds a role's full weight set from a family, mapping each of the
    /// interface's weights onto the family's real faces. This is why picking a
    /// family is enough on its own: bold headings get the family's actual bold
    /// rather than a smeared regular.
    ///
    /// AppKit's scale runs 0–15; 5 is regular/book, 6 medium, 8 semibold,
    /// 9 bold. A face is only recorded when the family genuinely has something
    /// near that weight, so a single-weight family stays a single-weight theme.
    static func themeFont(forFamily family: String, base: String? = nil) -> ThemeFont? {
        let faces = faces(inFamily: family)
        guard !faces.isEmpty else { return nil }
        guard let regular = base ?? face(in: faces, nearest: 5)?.postScriptName else { return nil }

        func named(_ target: Int) -> String? {
            guard let match = face(in: faces, nearest: target) else { return nil }
            // Don't record a weight the family can't really provide — that
            // would pin every heading to the base face and disable the
            // synthetic fallback that currently makes it legible.
            guard abs(match.weight - target) <= 1, match.postScriptName != regular else { return nil }
            return match.postScriptName
        }

        return ThemeFont(
            regular: regular,
            medium: named(6),
            semibold: named(8),
            bold: named(9)
        )
    }

    /// The family a recorded PostScript name belongs to, for showing what's
    /// currently selected.
    static func familyName(ofPostScriptName name: String) -> String? {
        NSFont(name: name, size: 12)?.familyName
    }

    /// The PostScript name CoreText will know a font file by after
    /// registration — which is what `fonts` must record for a bundled face.
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
