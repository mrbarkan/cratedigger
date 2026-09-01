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

    // MARK: - Overlay effects

    /// One dial-able overlay effect: a number in `effects[key]` that some
    /// overlay reads. Same shape as `GeometryToken`, for the same reason — the
    /// `read` key path is the value the renderer actually uses, so the control
    /// can't drift from what's on screen.
    ///
    /// They split by *what they're on*. An interface effect sits on the
    /// console's own surface — texture grain is a property of the material.
    /// A display effect sits on the glass, where a rake, a reflection and a
    /// dot screen belong to the screen and nothing else.
    struct EffectDial: Identifiable {
        enum Surface: String {
            case interface
            case display
        }

        let key: String
        let label: String
        /// Shown on hover — what the effect is imitating.
        let note: String
        /// Ceiling. Past it the effect stops reading as hardware and starts
        /// reading as a filter. `CarbonTheme` clamps to it and the editor's
        /// slider runs to it — one number, not two.
        let max: Double
        /// What the switch lights up to. Every effect ships off, so "on" needs
        /// a strength of its own: a slider that lands on 0 looks broken.
        let on: Double
        let surface: Surface
        let read: KeyPath<CarbonTheme, Double>
        var id: String { key }
    }

    static let effectDials: [EffectDial] = [
        EffectDial(
            key: "grain", label: "Texture Grain",
            note: "Fine grain over the console — the tooth a real surface has and a rendered one doesn't. Never over the display: that's glass, behind its own sheet.",
            max: 0.6, on: 0.2, surface: .interface, read: \.grainAmount
        ),
        EffectDial(
            key: "oledScanlineOpacity", label: "Scan Lines",
            note: "The CRT rake: a hairline every 3pt across the display glass.",
            max: 0.15, on: 0.03, surface: .display, read: \.oledScanlineOpacity
        ),
        EffectDial(
            key: "oledGlare", label: "Glare",
            note: "A reflection sweeping the display glass from the top-left, as if something in the room were lighting it.",
            max: 0.5, on: 0.16, surface: .display, read: \.oledGlareAmount
        ),
        EffectDial(
            key: "oledHalftone", label: "Halftone",
            note: "A print dot screen over the glass. It bites into lit pixels and leaves dark glass alone, so the type breaks into dots like a scanned photo of a screen.",
            max: 0.5, on: 0.2, surface: .display, read: \.oledHalftoneAmount
        ),
    ]

    static func effectDials(on surface: EffectDial.Surface) -> [EffectDial] {
        effectDials.filter { $0.surface == surface }
    }

    /// The ceiling for one effect key, for `CarbonTheme`'s clamp. An unknown
    /// key can't be dialled from the editor, so it just passes 0…1.
    static func effectMax(_ key: String) -> Double {
        effectDials.first { $0.key == key }?.max ?? 1
    }

    /// The shipped Carbon glass as hex, read off the built-in theme through the
    /// same key paths the swatches use. The CARBON preset is a reset, so it
    /// must not restate colours that could drift from what the app ships.
    static var carbonScreenColors: [String: String] {
        let tokens = colorGroups.first { $0.name == screenGroupName }?.tokens ?? []
        return Dictionary(uniqueKeysWithValues: tokens.map {
            ($0.key, CarbonTheme.carbon[keyPath: $0.read].themeHexString)
        })
    }

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
            ColorToken(key: "paper2", label: "Panel Shade",
                       note: "The darker end of a panel's gradient — the bottom of the browser, inspector and conversion surfaces. Not row striping: that's Alternate Rows.",
                       read: \.paper2),
            ColorToken(key: "rowAlt", label: "Alternate Rows",
                       note: "Every other row in the browser's Artist, Album and Track columns. Fully transparent in the built-ins — give it an alpha to stripe the lists.",
                       read: \.rowAlt),
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
                       note: "The theme's signature color: active keys, selected rows, OPEN ARTWORK, the POSITION bar — and the hot end of the VU, EQ and VOLUME ramps.",
                       read: \.orange),
            ColorToken(key: "orangeHi", label: "Accent Light",
                       note: "Lighter accent for gradients and hover states, and the peak segment at the top of the VU and EQ meters.",
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
                       note: "The cool end of every footer meter — the bottom of the VU and EQ ramps and the start of the VOLUME fader — plus 'in progress' indicators and the tint in the meters' black wells.",
                       read: \.cyan),
            ColorToken(key: "cyanGlow", label: "Teal Glow",
                       note: "Halo around lit meters, and the peak segment at the cool end of the VU and EQ ramps.",
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
            ColorToken(key: "transportLamp", label: "Transport Lamp",
                       note: "The LED behind the play, shuffle and repeat caps, in the footer and the mini player. Unset it follows the Accent.",
                       read: \.transportLamp),
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
        ColorGroup(name: screenGroupName, tokens: [
            ColorToken(key: "oledSurface", label: "Screen Glass",
                       note: "The dark glass of the big display in the header.",
                       read: \.oledSurface),
            ColorToken(key: "oledSurfaceShade", label: "Screen Shade",
                       note: "Depth wash raked across the glass, under the text. Translucent — its opacity is the strength, so drop the alpha for a pale screen.",
                       read: \.oledSurfaceShade),
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
                       note: "The live/streaming indicator on the display rail — the seventh lamp, alongside the six in Display Lamps. It sits with the glass because the screen presets set it.",
                       read: \.onAir),
        ]),
        ColorGroup(name: "Display Lamps", tokens: [
            ColorToken(key: "lampNow", label: "NOW Lamp",
                       note: "Lights the NOW annunciator on the glass, and the DISPLAY button's strip, while the Now Playing screen is up. Unset it follows the Amber accent.",
                       read: \.lampNow),
            ColorToken(key: "lampConvert", label: "CNVRT Lamp",
                       note: "The CNVRT annunciator and DISPLAY strip on the conversion screen. Unset it follows the Accent.",
                       read: \.lampConvert),
            ColorToken(key: "lampScan", label: "SCAN Lamp",
                       note: "The SCAN annunciator and DISPLAY strip while a folder scan is on screen. Unset it follows Teal.",
                       read: \.lampScan),
            ColorToken(key: "lampSync", label: "SYNC Lamp",
                       note: "The SYNC annunciator for the remote-library screen. Unset it follows Info Blue.",
                       read: \.lampSync),
            ColorToken(key: "lampCD", label: "CD Lamp",
                       note: "The CD annunciator for the disc-ripping screen. Unset it follows Alert Red.",
                       read: \.lampCD),
            ColorToken(key: "lampDevices", label: "DEV Lamp",
                       note: "The DEV annunciator and DISPLAY strip on the devices screen. Unset it follows Accent Light.",
                       read: \.lampDevices),
            ColorToken(key: "lampSearch", label: "SRCH Lamp",
                       note: "The SRCH annunciator and the tuner sweep on the search screen. Unset it follows Teal Glow.",
                       read: \.lampSearch),
        ]),
        ColorGroup(name: "Selected Rows", tokens: [
            ColorToken(key: "selectionLedCore", label: "Selection Lamp",
                       note: "The small lit dot at the leading edge of the selected row.",
                       read: \.selectionLedCore),
            ColorToken(key: "selectionGlow", label: "Selection Halo",
                       note: "The glow around that lamp. Selection's own colour — retinting the accents leaves it alone.",
                       read: \.selectionGlow),
            ColorToken(key: "selectionSpread", label: "Selection Wash",
                       note: "The light the lamp casts across the row, fading out toward the trailing edge.",
                       read: \.selectionSpread),
            ColorToken(key: "selectionInk", label: "Selected Text",
                       note: "Text color over a selected row — keep it readable on the accent.",
                       read: \.selectionInk),
        ]),
    ]

    /// Flat list, for search and for seeding a draft with every token.
    static let allColorTokens: [ColorToken] = colorGroups.flatMap(\.tokens)

    // MARK: - Screen presets

    /// The group the presets below rewrite, named once so the editor can spot
    /// it without matching a string that's only written down here.
    static let screenGroupName = "Display Screen"

    /// A one-click look for the header display: the whole Display Screen color
    /// group, its scanline strength, and the family its titles are set in.
    ///
    /// A preset is a starting point, not a mode — it writes the same tokens the
    /// swatches below it do, so anything it sets can be tweaked afterwards.
    struct ScreenPreset: Identifiable {
        let name: String
        /// Shown on hover — what the screen is imitating.
        let note: String
        /// Keyed by the `screenGroupName` token keys above.
        let colors: [String: String]
        /// What the same panel does in Light appearance, when that's a
        /// different piece of hardware rather than the same one re-tinted — an
        /// iPod with its backlight off. `nil` (the usual case) means the glass
        /// looks identical whichever way the app is set: a green CRT is a green
        /// CRT at noon.
        var lightColors: [String: String]?
        /// `effects.oledScanlineOpacity` — a CRT rakes, an LED panel doesn't.
        let scanline: Double
        /// `effects.oledMonochrome`. Most presets here model single-emitter
        /// hardware and set it; the one modern colour panel (OLED WHITE) turns
        /// it off. The switch below the row overrides either way.
        var monochrome: Bool = true
        /// A font *family*, mapped onto real faces at apply time. Every one
        /// here ships with macOS or with the app, and a family that somehow
        /// isn't installed leaves the current face alone rather than pinning a
        /// name nothing can draw.
        let fontFamily: String
        var id: String { name }

        /// Whether the two appearances get different glass — the tip says so,
        /// since it's the one preset whose result you can't fully see at once.
        var isAppearanceAware: Bool { lightColors != nil }

        func colors(for appearance: ThemeDefinition.BaseAppearance) -> [String: String] {
            appearance == .light ? (lightColors ?? colors) : colors
        }
    }

    static let screenPresets: [ScreenPreset] = [
        ScreenPreset(
            name: "CARBON",
            note: "The app's own glass: a modern colour OLED — near-black panel, warm-white type, full accents, no rake. This one is the reset; it puts the screen back exactly as CrateDigger ships it.",
            colors: carbonScreenColors,
            scanline: 0,
            monochrome: false,
            fontFamily: "Major Mono Display"
        ),
        ScreenPreset(
            name: "LCD GREEN",
            note: "Monochrome green phosphor on dark glass — the classic terminal readout.",
            colors: [
                "oledSurface": "#04120A",
                "oledSurfaceShade": "#00190E8C",
                "oledStrokeInner": "#0E3320",
                "oledForeground": "#6BFF7B",
                "oledForegroundMuted": "#6BFF7BA6",
                "onAir": "#6BFF7B",
            ],
            scanline: 0.06,
            fontFamily: "Menlo"
        ),
        ScreenPreset(
            name: "AMBER",
            note: "The same monochrome tube lit amber — warmer, and easier to read for long stretches.",
            colors: [
                "oledSurface": "#120A03",
                "oledSurfaceShade": "#1A0C008C",
                "oledStrokeInner": "#3A2109",
                "oledForeground": "#FFB63C",
                "oledForegroundMuted": "#FFB63CA6",
                "onAir": "#FFB63C",
            ],
            scanline: 0.06,
            fontFamily: "Menlo"
        ),
        ScreenPreset(
            name: "VFD CYAN",
            note: "Vacuum-fluorescent teal, like a tape deck or amp: bright segments, no scanlines.",
            colors: [
                "oledSurface": "#02080C",
                "oledSurfaceShade": "#001A2299",
                "oledStrokeInner": "#0B2A33",
                "oledForeground": "#7FEBFF",
                "oledForegroundMuted": "#7FEBFFA6",
                "onAir": "#7FEBFF",
            ],
            scanline: 0.015,
            fontFamily: "Major Mono Display"
        ),
        ScreenPreset(
            name: "RED LED",
            note: "Segmented red LED on near-black — the clock-radio look.",
            colors: [
                "oledSurface": "#0A0202",
                "oledSurfaceShade": "#1A00008C",
                "oledStrokeInner": "#2A0B08",
                "oledForeground": "#FF4A32",
                "oledForegroundMuted": "#FF4A32A6",
                "onAir": "#FF3B2F",
            ],
            scanline: 0.02,
            fontFamily: "Major Mono Display"
        ),
        ScreenPreset(
            name: "OLED BLUE",
            note: "The classic clip-on player's OLED: bright aqua pixels on true black, no rake. Lit pixels only, so the glass is genuinely off where nothing is drawn. (The real panel had a second, yellow-green emitter for its status strip; this keeps the one phosphor.)",
            colors: [
                "oledSurface": "#000000",
                "oledSurfaceShade": "#00080C99",
                "oledStrokeInner": "#0A222A",
                "oledForeground": "#81F0FC",
                "oledForegroundMuted": "#81F0FCA6",
                "onAir": "#81F0FC",
            ],
            scanline: 0,
            fontFamily: "Verdana"
        ),
        ScreenPreset(
            name: "BACKLIT",
            note: "A lit blue-green panel with dark type, like a backlit calculator — the one preset that reads dark-on-light.",
            colors: [
                "oledSurface": "#86D6CE",
                "oledSurfaceShade": "#0B2A2E29",
                "oledStrokeInner": "#4C8C87",
                "oledForeground": "#0C2B26",
                "oledForegroundMuted": "#0C2B26B3",
                "onAir": "#0C2B26",
            ],
            scanline: 0.03,
            fontFamily: "Andale Mono"
        ),
        ScreenPreset(
            name: "IPOD",
            note: "The click-wheel iPod's grayscale panel — reflective grey-green in Light, blue-white backlit in Dark, dark pixels either way.",
            colors: [
                "oledSurface": "#8FC6D6",
                "oledSurfaceShade": "#0E1A1F1F",
                "oledStrokeInner": "#4E7A88",
                "oledForeground": "#0E1A1C",
                "oledForegroundMuted": "#0E1A1CA6",
                "onAir": "#12262B",
            ],
            lightColors: [
                "oledSurface": "#C3CBBE",
                "oledSurfaceShade": "#1E241E1F",
                "oledStrokeInner": "#8C9488",
                "oledForeground": "#1B211B",
                "oledForegroundMuted": "#1B211BA6",
                "onAir": "#2A3328",
            ],
            scanline: 0.02,
            fontFamily: "Helvetica Neue"
        ),
        ScreenPreset(
            name: "PAPER",
            note: "Reflective e-paper: near-white glass, black type, no glow. Suits a light theme.",
            colors: [
                "oledSurface": "#EDEAE1",
                "oledSurfaceShade": "#00000014",
                "oledStrokeInner": "#C6C0B2",
                "oledForeground": "#1B1A16",
                "oledForegroundMuted": "#1B1A16A6",
                "onAir": "#B4432E",
            ],
            scanline: 0,
            fontFamily: "Courier New"
        ),
    ]

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
                          note: "Height of the keys in the CNVRT conversion panel.",
                          range: CarbonGeometry.Bounds.smallControl, read: \.patchBayKeyHeight),
            GeometryToken(key: "patchBayCycleButtonHeight", label: "Convert Dials",
                          note: "Height of the conversion panel's cycling selectors.",
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

    /// Main-thread-only memo. `availableMembers` walks the font registry, and
    /// the editor asks for the same handful of families on every redraw.
    private static var faceCache: [String: [FontFace]] = [:]

    /// Every face in a family, ordered light → heavy with italics after their
    /// upright counterparts, so the menu reads the way a type specimen does.
    static func faces(inFamily family: String) -> [FontFace] {
        if let cached = faceCache[family] { return cached }
        let resolved = uncachedFaces(inFamily: family)
        faceCache[family] = resolved
        return resolved
    }

    private static func uncachedFaces(inFamily family: String) -> [FontFace] {
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
            light: named(3),
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

    /// How many of the interface's weights a role currently names.
    static func namedWeightCount(_ font: ThemeFont) -> Int {
        ThemeFontWeight.allCases.filter { font.face(for: $0) != nil }.count
    }

    /// How many the family could supply. Compared against the above, this is
    /// what tells a theme picked before per-weight mapping existed — a bare
    /// `"sans": "SFPro-Regular"` — that it's leaving three real faces unused.
    static func availableWeightCount(inFamily family: String) -> Int {
        themeFont(forFamily: family).map(namedWeightCount) ?? 1
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
