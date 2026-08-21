import AppKit
import CrateDiggerCore
import SwiftUI

public struct ShadowSpec: Equatable {
    public let color: Color
    public let radius: CGFloat
    public let x: CGFloat
    public let y: CGFloat

    public init(color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) {
        self.color = color
        self.radius = radius
        self.x = x
        self.y = y
    }
}

public struct CarbonTheme: Equatable {
    public enum Mode: String, Equatable {
        case linen
        case carbon
    }

    public let mode: Mode

    public let chassis: Color
    public let chassisHi: Color
    public let chassisLo: Color
    public let chassisDeep: Color

    public let well: Color
    public let wellDeep: Color

    public let paper: Color
    public let paper2: Color

    public let ink: Color
    public let ink2: Color
    public let ink3: Color
    public let ink4: Color
    public let hair: Color

    // `var` rather than `let` only so `monochromeGlass` can build a variant of
    // an existing theme; nothing mutates a live one.
    public var orange: Color
    public var orangeHi: Color
    public var orangeLo: Color
    public var sun: Color
    public var sunHi: Color
    public var sunLo: Color
    public var cyan: Color
    public var cyanGlow: Color
    public var red: Color
    public var indigo: Color

    public let metalHi: Color
    public let metal: Color
    public let metalLo: Color
    public let metalDeep: Color

    public let shadow1: ShadowSpec
    public let shadow2: ShadowSpec

    public let backgroundBase: Color
    public let backgroundGradientStart: Color
    public let backgroundGradientEnd: Color

    public let oledSurface: Color
    public let oledStrokeInner: Color

    /// The depth wash raked across the glass, under everything drawn on it —
    /// a translucent color, so its alpha is the strength. It was a fixed
    /// `black 28%`, which reads as depth on a black screen and as a dirty grey
    /// smear on a pale one, with no token to turn it down; a light glass now
    /// defaults to a much softer wash (see `init(definition:resolvedBase:)`).
    public let oledSurfaceShade: Color

    /// The OLED glass's warm phosphor foreground + its "ON AIR" accent.
    /// Both built-ins ship identical values (the display reads as one fixed
    /// physical screen regardless of light/dark) but a theme can override them.
    public let oledForeground: Color
    public let oledForegroundMuted: Color
    public var onAir: Color

    /// CRT scanline strength on the OLED glass (0 = off). Themeable via
    /// `effects.oledScanlineOpacity`, clamped to 0…0.15.
    public let oledScanlineOpacity: Double

    /// Whether the chassis casts shadows. `false` (`effects.flat` = `1`) drops
    /// every depth shadow — panels, keys, the glass, artwork — and leaves the
    /// bevels, gradients and emission glows alone, so the interface reads as
    /// printed rather than moulded. See `View.depthShadow`.
    public let castsShadows: Bool

    /// Whether the display is a single-phosphor panel: everything on the glass
    /// is drawn in `oledForeground`, at whatever intensity it had, instead of
    /// the accents the rest of the interface uses. Themeable via
    /// `effects.oledMonochrome` (`1` on, `0` off) — real LCD/VFD/LED hardware
    /// only ever emits one colour, and every screen preset but the default
    /// models that hardware.
    public let oledMonochrome: Bool

    /// The light-mode selection-row LED core color (`CarbonSelectionSlot`).
    public var selectionLedCore: Color

    /// Foreground (text/icon) color when laid over a selected row background.
    /// Centralized so row views and the sources sidebar keep selected text
    /// readable over the accent gradients.
    public let selectionInk: Color

    /// Identifies the active theme's font-role overrides.
    ///
    /// Fonts reach the UI through the `ActiveThemeFonts` global rather than the
    /// environment (`CarbonTypography` explains why: hundreds of static
    /// `CarbonFont.mono(_:)` call sites). But writing a global invalidates
    /// nothing, so swapping a typeface used to change the screen only where
    /// something happened to redraw for another reason — in the editor, that
    /// looked like font changes simply not applying.
    ///
    /// Carrying the signature here makes a font change a *theme* change, which
    /// every `@Environment(\.carbon)` reader already reacts to. It's compared,
    /// never displayed.
    public var fontsSignature: String = ""

    public var isDark: Bool { mode == .carbon }
}

public extension CarbonTheme {
    static let linen = CarbonTheme(
        mode: .linen,
        chassis:      Color(hex: 0xF5F8FA),
        chassisHi:    Color(hex: 0xFFFFFF),
        chassisLo:    Color(hex: 0xD7E1E5),
        chassisDeep:  Color(hex: 0x9CAAB0),
        well:         Color(hex: 0xE9F1F4),
        wellDeep:     Color(hex: 0xC8D5DA),
        paper:        Color(hex: 0xFAFCFD),
        paper2:       Color(hex: 0xEEF4F7),
        ink:          Color(hex: 0x12171C),
        ink2:         Color(hex: 0x313E47),
        ink3:         Color(hex: 0x657580),
        ink4:         Color(hex: 0x98A5AB),
        hair:         Color(hex: 0xC7D2D7),
        orange:       Color(hex: 0xFF6236),
        orangeHi:     Color(hex: 0xFF956F),
        orangeLo:     Color(hex: 0xD7441E),
        sun:          Color(hex: 0xF4C84A),
        sunHi:        Color(hex: 0xFFE58A),
        sunLo:        Color(hex: 0xC99E2F),
        cyan:         Color(hex: 0x3AA8B8),
        cyanGlow:     Color(hex: 0xBDEEF2),
        red:          Color(hex: 0xE2473F),
        indigo:       Color(hex: 0x4B6FCB),
        metalHi:      Color(hex: 0xFFFFFF),
        metal:        Color(hex: 0xDDE8EC),
        metalLo:      Color(hex: 0xABB9C0),
        metalDeep:    Color(hex: 0x5F6D75),
        shadow1: ShadowSpec(color: Color(white: 0.06, opacity: 0.10), radius: 10, y: 3),
        shadow2: ShadowSpec(color: Color(white: 0.05, opacity: 0.24), radius: 48, y: 22),
        backgroundBase:          Color(hex: 0xDCE9EC),
        backgroundGradientStart: Color(hex: 0xF2F8F9),
        backgroundGradientEnd:   Color(hex: 0xC7D8DF),
        oledSurface:     Color(hex: 0x0A0A0A),
        oledStrokeInner: Color(hex: 0x1A1A1A),
        oledSurfaceShade: Color.black.opacity(0.28),
        oledForeground:      Color(red: 0.961, green: 0.945, blue: 0.902),
        oledForegroundMuted: Color.white.opacity(0.55),
        onAir:               Color(red: 1.0, green: 0.357, blue: 0.29),
        oledScanlineOpacity: 0.018,
        castsShadows: true,
        oledMonochrome: false,
        selectionLedCore: Color(hex: 0xFFD24A),
        selectionInk:    Color(hex: 0xFFFFFF)
    )

    static let carbon = CarbonTheme(
        mode: .carbon,
        chassis:      Color(hex: 0x171C22),
        chassisHi:    Color(hex: 0x2B3540),
        chassisLo:    Color(hex: 0x0C0F13),
        chassisDeep:  Color(hex: 0x05070A),
        well:         Color(hex: 0x121A22),
        wellDeep:     Color(hex: 0x070A0E),
        paper:        Color(hex: 0x111820),
        paper2:       Color(hex: 0x0A0E13),
        ink:          Color(hex: 0xF3F7F7),
        ink2:         Color(hex: 0xC8D4D9),
        ink3:         Color(hex: 0x82929B),
        ink4:         Color(hex: 0x56636C),
        hair:         Color(hex: 0x26333C),
        orange:       Color(hex: 0xFF6D3F),
        orangeHi:     Color(hex: 0xFFA07C),
        orangeLo:     Color(hex: 0xD94C25),
        sun:          Color(hex: 0xF4CA54),
        sunHi:        Color(hex: 0xFFE894),
        sunLo:        Color(hex: 0xC79D30),
        cyan:         Color(hex: 0x45C7BD),
        cyanGlow:     Color(hex: 0xBEF4EF),
        red:          Color(hex: 0xEA554C),
        indigo:       Color(hex: 0x7282E8),
        metalHi:      Color(hex: 0x56626B),
        metal:        Color(hex: 0x303A43),
        metalLo:      Color(hex: 0x151A20),
        metalDeep:    Color(hex: 0x05070A),
        shadow1: ShadowSpec(color: Color.black.opacity(0.52), radius: 12, y: 3),
        shadow2: ShadowSpec(color: Color.black.opacity(0.72), radius: 54, y: 24),
        backgroundBase:          Color(hex: 0x080A0E),
        backgroundGradientStart: Color(hex: 0x18232C),
        backgroundGradientEnd:   Color(hex: 0x030406),
        oledSurface:     Color(hex: 0x050504),
        oledStrokeInner: Color(hex: 0x0E0E0C),
        oledSurfaceShade: Color.black.opacity(0.28),
        oledForeground:      Color(red: 0.961, green: 0.945, blue: 0.902),
        oledForegroundMuted: Color.white.opacity(0.55),
        onAir:               Color(red: 1.0, green: 0.357, blue: 0.29),
        oledScanlineOpacity: 0.018,
        castsShadows: true,
        oledMonochrome: false,
        selectionLedCore: Color(hex: 0xFFD24A),
        selectionInk:    Color(hex: 0xFFFFFF)
    )
}

public extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8)  & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    /// Parses a theme-file color token: `"#RRGGBB"` or `"#RRGGBBAA"`
    /// (leading `#` optional, case-insensitive). `nil` for anything else so
    /// callers can fall back to a known-good default rather than crash on a
    /// malformed 3rd-party theme.
    /// Perceived brightness, 0 (black) … 1 (white). Used to pick a default for
    /// an effect layered *on* a themed surface, where the surface's own color
    /// decides what reads correctly — see `oledSurfaceShade`.
    var themeLuminance: Double {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return 0 }
        return Double(0.299 * srgb.redComponent + 0.587 * srgb.greenComponent + 0.114 * srgb.blueComponent)
    }

    init?(hexString: String) {
        var value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8, let parsed = UInt32(value, radix: 16) else { return nil }

        if value.count == 8 {
            let r = Double((parsed >> 24) & 0xFF) / 255.0
            let g = Double((parsed >> 16) & 0xFF) / 255.0
            let b = Double((parsed >> 8) & 0xFF) / 255.0
            let a = Double(parsed & 0xFF) / 255.0
            self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
        } else {
            self.init(hex: parsed)
        }
    }
}

public extension CarbonTheme {
    /// Converts a (possibly partial) `ThemeDefinition` into a fully-populated
    /// `CarbonTheme`. Every token the definition doesn't override — an
    /// unset/malformed color, an omitted shadow — falls back to the matching
    /// field on `resolvedBase` (normally `.linen` or `.carbon`, matching the
    /// definition's declared `baseAppearance`), so a theme that only sets a
    /// few colors still renders a complete, correct theme.
    init(definition: ThemeDefinition, resolvedBase: CarbonTheme) {
        func color(_ key: String, _ fallback: Color) -> Color {
            guard let hex = definition.colors?[key], let parsed = Color(hexString: hex) else { return fallback }
            return parsed
        }
        func shadow(_ key: String, _ fallback: ShadowSpec) -> ShadowSpec {
            guard let shadowDefinition = definition.shadows?[key] else { return fallback }
            return ShadowSpec(definition: shadowDefinition, fallback: fallback)
        }

        mode = definition.baseAppearance == .dark ? .carbon : .linen

        chassis = color("chassis", resolvedBase.chassis)
        chassisHi = color("chassisHi", resolvedBase.chassisHi)
        chassisLo = color("chassisLo", resolvedBase.chassisLo)
        chassisDeep = color("chassisDeep", resolvedBase.chassisDeep)

        well = color("well", resolvedBase.well)
        wellDeep = color("wellDeep", resolvedBase.wellDeep)

        paper = color("paper", resolvedBase.paper)
        paper2 = color("paper2", resolvedBase.paper2)

        ink = color("ink", resolvedBase.ink)
        ink2 = color("ink2", resolvedBase.ink2)
        ink3 = color("ink3", resolvedBase.ink3)
        ink4 = color("ink4", resolvedBase.ink4)
        hair = color("hair", resolvedBase.hair)

        orange = color("orange", resolvedBase.orange)
        orangeHi = color("orangeHi", resolvedBase.orangeHi)
        orangeLo = color("orangeLo", resolvedBase.orangeLo)
        sun = color("sun", resolvedBase.sun)
        sunHi = color("sunHi", resolvedBase.sunHi)
        sunLo = color("sunLo", resolvedBase.sunLo)
        cyan = color("cyan", resolvedBase.cyan)
        cyanGlow = color("cyanGlow", resolvedBase.cyanGlow)
        red = color("red", resolvedBase.red)
        indigo = color("indigo", resolvedBase.indigo)

        metalHi = color("metalHi", resolvedBase.metalHi)
        metal = color("metal", resolvedBase.metal)
        metalLo = color("metalLo", resolvedBase.metalLo)
        metalDeep = color("metalDeep", resolvedBase.metalDeep)

        shadow1 = shadow("shadow1", resolvedBase.shadow1)
        shadow2 = shadow("shadow2", resolvedBase.shadow2)

        backgroundBase = color("backgroundBase", resolvedBase.backgroundBase)
        backgroundGradientStart = color("backgroundGradientStart", resolvedBase.backgroundGradientStart)
        backgroundGradientEnd = color("backgroundGradientEnd", resolvedBase.backgroundGradientEnd)

        oledSurface = color("oledSurface", resolvedBase.oledSurface)
        oledStrokeInner = color("oledStrokeInner", resolvedBase.oledStrokeInner)
        // The built-in shade is tuned for a black screen. A theme that puts a
        // pale glass in the header (Apple Music's light layer) would inherit a
        // 28% black rake across it, so the default follows the glass instead of
        // the base theme — a theme can still name any color/alpha it likes.
        oledSurfaceShade = color("oledSurfaceShade",
                                 oledSurface.themeLuminance > 0.5
                                     ? Color.black.opacity(0.06)
                                     : resolvedBase.oledSurfaceShade)
        oledForeground = color("oledForeground", resolvedBase.oledForeground)
        oledForegroundMuted = color("oledForegroundMuted", resolvedBase.oledForegroundMuted)
        onAir = color("onAir", resolvedBase.onAir)
        oledScanlineOpacity = min(max(definition.effects?["oledScanlineOpacity"]
                                        ?? resolvedBase.oledScanlineOpacity, 0), 0.15)
        oledMonochrome = (definition.effects?["oledMonochrome"]
                            ?? (resolvedBase.oledMonochrome ? 1 : 0)) > 0.5
        castsShadows = (definition.effects?["flat"]
                            ?? (resolvedBase.castsShadows ? 0 : 1)) < 0.5

        selectionLedCore = color("selectionLedCore", resolvedBase.selectionLedCore)
        selectionInk = color("selectionInk", resolvedBase.selectionInk)

        // Sorted so the same overrides always produce the same signature and
        // an unrelated edit never spuriously invalidates the whole tree.
        // Spelled out rather than interpolating the struct: every named face
        // has to be in here, since changing only a role's bold face still has
        // to invalidate the tree.
        fontsSignature = (definition.fonts ?? [:])
            .sorted { $0.key < $1.key }
            .map { role, font in
                let faces = ThemeFontWeight.allCases.compactMap { weight -> String? in
                    guard let face = font.face(for: weight) else { return nil }
                    return "\(weight.rawValue):\(face)"
                }
                return "\(role)=\(faces.joined(separator: "/"))"
            }
            .joined(separator: ",")
    }
}

private extension ShadowSpec {
    init(definition: ShadowDefinition, fallback: ShadowSpec) {
        let base = Color(hexString: definition.color) ?? fallback.color
        let resolvedColor = definition.opacity.map { base.opacity($0) } ?? base
        self.init(color: resolvedColor, radius: definition.radius, x: definition.x, y: definition.y)
    }
}

public extension CarbonTheme {
    /// The same theme with every accent collapsed onto the display's own
    /// phosphor — what a single-colour LCD, VFD or LED panel does to anything
    /// drawn on it. `OLEDDisplay` hands this to the glass's subtree (and
    /// nowhere else) when `oledMonochrome` is on.
    ///
    /// What's left to tell things apart is intensity rather than hue, which is
    /// how the glass already draws its unlit states — a dark annunciator is the
    /// same phosphor at 16%.
    var monochromeGlass: CarbonTheme {
        var copy = self
        for accent: WritableKeyPath<CarbonTheme, Color> in [
            \.orange, \.orangeHi, \.orangeLo,
            \.sun, \.sunHi, \.sunLo,
            \.cyan, \.cyanGlow,
            \.red, \.indigo,
            \.onAir, \.selectionLedCore,
        ] {
            copy[keyPath: accent] = oledForeground
        }
        return copy
    }
}
