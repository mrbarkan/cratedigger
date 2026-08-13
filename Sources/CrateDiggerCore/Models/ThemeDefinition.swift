import Foundation

/// The on-disk, third-party-authorable shape of a CrateDigger theme ("skin").
///
/// A theme is a single JSON file (optionally alongside a `Fonts/` folder inside
/// a `.cdtheme` bundle directory). All fields except `id`/`name`/`baseAppearance`
/// are optional — an author overrides only the tokens they care about via
/// `inherits`, and every omitted token is filled in from the inherited base at
/// load time. This is what makes a minimal theme (a handful of color overrides)
/// just as valid as a fully bespoke one.
public struct ThemeDefinition: Codable, Sendable, Equatable {
    public enum BaseAppearance: String, Codable, Sendable {
        case light
        case dark
    }

    /// Stable slug used for `inherits` references and persistence
    /// (`PreferencesStore.selectedThemeID`). Not shown in the UI.
    public var id: String
    public var name: String
    public var author: String?
    public var version: String?

    /// Drives `preferredColorScheme`/window chrome when this theme is the
    /// active selection.
    public var baseAppearance: BaseAppearance

    /// The id of another theme (built-in `"linen"`/`"carbon"`, or any other
    /// installed theme) that supplies every token this definition omits.
    /// `nil` means "supply defaults from the theme matching `baseAppearance`."
    public var inherits: String?

    /// Color token overrides, keyed by `CarbonTheme`'s stored property names
    /// (e.g. `"orange"`, `"chassis"`, `"ink"`). Values are `"#RRGGBB"` or
    /// `"#RRGGBBAA"` hex strings.
    public var colors: [String: String]?

    /// `"shadow1"`/`"shadow2"` overrides.
    public var shadows: [String: ShadowDefinition]?

    /// Font overrides keyed by semantic role (`"mono"`, `"sans"`, `"display"`).
    ///
    /// A value is either a single PostScript name or a per-weight set — see
    /// `ThemeFont`. A name that isn't registered falls back to the system font
    /// automatically (`Font.custom` behavior), so an author never needs to ship
    /// fonts for this to be safe.
    public var fonts: [String: ThemeFont]?

    /// Geometry overrides keyed by `CarbonLayout`'s field names (e.g.
    /// `"chassisCornerRadius"`, `"playButtonSize"`). Values are clamped to
    /// safe ranges when converted to `CarbonGeometry` — a theme cannot break
    /// the app's layout, only push it to an extreme within reason.
    public var geometry: [String: Double]?

    /// Display-effect overrides (e.g. `"oledScanlineOpacity"`). Values are
    /// clamped to safe ranges when converted to `CarbonTheme`, same contract
    /// as `geometry`.
    public var effects: [String: Double]?

    /// Optional per-appearance layers. A theme that supplies **both** is
    /// *adaptive*: it follows the user's Light/Dark/System setting instead of
    /// forcing the one appearance it was authored in, so a single theme covers
    /// both rather than shipping as a "— Light"/"— Dark" pair.
    ///
    /// Each layer holds only what differs from the shared tokens above, so the
    /// common palette is still written once. A theme with neither (or only one)
    /// behaves exactly as before — this is purely additive, and every theme
    /// authored before it keeps loading unchanged.
    public var light: ThemeVariant?
    public var dark: ThemeVariant?

    public init(
        id: String,
        name: String,
        author: String? = nil,
        version: String? = nil,
        baseAppearance: BaseAppearance,
        inherits: String? = nil,
        colors: [String: String]? = nil,
        shadows: [String: ShadowDefinition]? = nil,
        fonts: [String: ThemeFont]? = nil,
        geometry: [String: Double]? = nil,
        effects: [String: Double]? = nil,
        light: ThemeVariant? = nil,
        dark: ThemeVariant? = nil
    ) {
        self.light = light
        self.dark = dark
        self.id = id
        self.name = name
        self.author = author
        self.version = version
        self.baseAppearance = baseAppearance
        self.inherits = inherits
        self.colors = colors
        self.shadows = shadows
        self.fonts = fonts
        self.geometry = geometry
        self.effects = effects
    }
}

/// The weights the interface actually asks for. Anything heavier or lighter a
/// caller requests is served by the nearest of these.
public enum ThemeFontWeight: String, Codable, Sendable, CaseIterable {
    case regular
    case medium
    case semibold
    case bold
}

/// A font role's faces.
///
/// Real families ship a separate file per weight, and a theme that names only
/// one of them leaves the interface to *synthesise* bold and medium by
/// smearing a single face — which looks wrong and is what AppKit complains
/// about with "Unable to update Font Descriptor's weight". Naming the real
/// faces lets every weight render as drawn.
///
/// Encodes as a bare string when only `regular` is set, so the simple case
/// stays simple in a hand-authored file:
///
/// ```json
/// "fonts": {
///   "sans": "Helvetica",
///   "mono": { "regular": "Menlo-Regular", "bold": "Menlo-Bold" }
/// }
/// ```
public struct ThemeFont: Codable, Sendable, Equatable {
    /// The base face. Required — it's what every unspecified weight falls back to.
    public var regular: String
    public var medium: String?
    public var semibold: String?
    public var bold: String?

    public init(regular: String, medium: String? = nil, semibold: String? = nil, bold: String? = nil) {
        self.regular = regular
        self.medium = medium
        self.semibold = semibold
        self.bold = bold
    }

    /// The face drawn for `weight`, or `nil` when the theme doesn't name one —
    /// callers use that distinction to decide whether to apply a synthetic
    /// weight on top (needed for a single-face theme, wrong for a real one).
    public func face(for weight: ThemeFontWeight) -> String? {
        switch weight {
        case .regular:  return regular
        case .medium:   return medium
        case .semibold: return semibold
        case .bold:     return bold
        }
    }

    /// The face to actually draw with, always resolving to something.
    public func resolvedFace(for weight: ThemeFontWeight) -> String {
        // A missing middle weight prefers a heavier named face over the base:
        // asking for semibold on a family that ships only regular and bold
        // looks better bold than smeared.
        switch weight {
        case .regular:  return regular
        case .medium:   return medium ?? semibold ?? bold ?? regular
        case .semibold: return semibold ?? bold ?? medium ?? regular
        case .bold:     return bold ?? semibold ?? medium ?? regular
        }
    }

    private enum CodingKeys: String, CodingKey {
        case regular, medium, semibold, bold
    }

    public init(from decoder: Decoder) throws {
        // `"sans": "Helvetica"` — the shorthand every theme written before
        // per-weight faces existed uses.
        if let single = try? decoder.singleValueContainer().decode(String.self) {
            self.init(regular: single)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            regular: try container.decode(String.self, forKey: .regular),
            medium: try container.decodeIfPresent(String.self, forKey: .medium),
            semibold: try container.decodeIfPresent(String.self, forKey: .semibold),
            bold: try container.decodeIfPresent(String.self, forKey: .bold)
        )
    }

    public func encode(to encoder: Encoder) throws {
        guard medium != nil || semibold != nil || bold != nil else {
            var container = encoder.singleValueContainer()
            try container.encode(regular)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(regular, forKey: .regular)
        try container.encodeIfPresent(medium, forKey: .medium)
        try container.encodeIfPresent(semibold, forKey: .semibold)
        try container.encodeIfPresent(bold, forKey: .bold)
    }
}

/// One appearance's layer of a theme — only the tokens that differ from the
/// theme's shared set when that appearance is active.
///
/// Deliberately narrower than `ThemeDefinition`: geometry and fonts don't
/// change between light and dark (a corner radius isn't lighter at night), so
/// allowing them here would invite themes that shift layout as the system
/// appearance changes.
public struct ThemeVariant: Codable, Sendable, Equatable {
    public var colors: [String: String]?
    public var shadows: [String: ShadowDefinition]?
    public var effects: [String: Double]?

    public init(
        colors: [String: String]? = nil,
        shadows: [String: ShadowDefinition]? = nil,
        effects: [String: Double]? = nil
    ) {
        self.colors = colors
        self.shadows = shadows
        self.effects = effects
    }

    public var isEmpty: Bool {
        (colors?.isEmpty ?? true) && (shadows?.isEmpty ?? true) && (effects?.isEmpty ?? true)
    }
}

public extension ThemeDefinition {
    /// A theme that carries both layers follows the user's Light/Dark/System
    /// setting; one that doesn't still forces its own `baseAppearance`, exactly
    /// as every theme did before variants existed.
    var isAdaptive: Bool { light != nil && dark != nil }

    func variant(for appearance: BaseAppearance) -> ThemeVariant? {
        appearance == .light ? light : dark
    }

    /// Flattens this theme for one appearance: the shared tokens with that
    /// appearance's layer laid over them. Rendering always goes through here,
    /// so `CarbonTheme` never has to know variants exist.
    func resolved(for appearance: BaseAppearance) -> ThemeDefinition {
        guard let variant = variant(for: appearance) else { return self }

        var result = self
        // A theme rendering its light layer *is* light, whatever it declares.
        result.baseAppearance = appearance
        result.colors = ThemeDefinition.overlay(colors, variant.colors)
        result.shadows = ThemeDefinition.overlay(shadows, variant.shadows)
        result.effects = ThemeDefinition.overlay(effects, variant.effects)
        return result
    }

    internal static func overlay<Value>(_ base: [String: Value]?, _ over: [String: Value]?) -> [String: Value]? {
        guard let over else { return base }
        guard let base else { return over }
        return base.merging(over) { _, new in new }
    }
}

public struct ShadowDefinition: Codable, Sendable, Equatable {
    /// `"#RRGGBB"` or `"#RRGGBBAA"`.
    public var color: String
    public var opacity: Double?
    public var radius: Double
    public var x: Double
    public var y: Double

    public init(color: String, opacity: Double? = nil, radius: Double, x: Double = 0, y: Double = 0) {
        self.color = color
        self.opacity = opacity
        self.radius = radius
        self.x = x
        self.y = y
    }
}

/// A discovered-but-not-yet-fully-resolved theme, paired with where it came
/// from (bundled vs. user-installed) so the UI can distinguish "built-in" from
/// "installed by you" and only offer to reveal/delete the latter.
public struct ThemeManifest: Identifiable, Sendable, Equatable {
    public enum Origin: Sendable, Equatable {
        case builtIn
        case userInstalled(sourceURL: URL)
    }

    public var id: String { definition.id }
    public var definition: ThemeDefinition
    public var origin: Origin

    public init(definition: ThemeDefinition, origin: Origin) {
        self.definition = definition
        self.origin = origin
    }
}

/// A non-fatal problem encountered while discovering/parsing themes. Loading
/// always continues past these — a single bad file never breaks the rest.
public struct ThemeLoadWarning: Sendable, Equatable {
    public var sourceURL: URL
    public var message: String

    public init(sourceURL: URL, message: String) {
        self.sourceURL = sourceURL
        self.message = message
    }
}
