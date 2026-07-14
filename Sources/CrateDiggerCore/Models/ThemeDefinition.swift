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

    /// Font overrides keyed by semantic role (`"mono"`, `"sans"`, `"display"`),
    /// value is a PostScript font name. A name that isn't registered falls
    /// back to the system font automatically (`Font.custom` behavior) — an
    /// author never needs to ship fonts for this to be safe.
    public var fonts: [String: String]?

    /// Geometry overrides keyed by `CarbonLayout`'s field names (e.g.
    /// `"chassisCornerRadius"`, `"playButtonSize"`). Values are clamped to
    /// safe ranges when converted to `CarbonGeometry` — a theme cannot break
    /// the app's layout, only push it to an extreme within reason.
    public var geometry: [String: Double]?

    public init(
        id: String,
        name: String,
        author: String? = nil,
        version: String? = nil,
        baseAppearance: BaseAppearance,
        inherits: String? = nil,
        colors: [String: String]? = nil,
        shadows: [String: ShadowDefinition]? = nil,
        fonts: [String: String]? = nil,
        geometry: [String: Double]? = nil
    ) {
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
