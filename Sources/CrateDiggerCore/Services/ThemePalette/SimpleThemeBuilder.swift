import Foundation

public enum SimpleAppearanceMode: String, CaseIterable, Sendable {
    case light, dark, both
}

/// What Simple chooses besides colour.
public struct SimpleThemeChoices: Equatable, Sendable {
    public var appearance: SimpleAppearanceMode
    public var material: ShellMaterial?
    public var coverLook: CoverScreenLook?
    /// Keyed `display` / `mono` / `sans`.
    public var fonts: [String: ThemeFont]

    public init(appearance: SimpleAppearanceMode, material: ShellMaterial?,
                coverLook: CoverScreenLook?, fonts: [String: ThemeFont]) {
        self.appearance = appearance
        self.material = material
        self.coverLook = coverLook
        self.fonts = fonts
    }
}

/// Turns a Simple state and its choices into a theme, laid over `base`.
///
/// A Simple theme is self-contained in every appearance: it names no parent, shows no
/// logo (the header shows its name), and every colour it draws is one the recipe wrote.
/// The optional overrides (`lamp…`, `keyLamp`, `transportLamp`, `meterHot`,
/// `chassisInk`, `columnHeaderInk`) are never written, so they follow the new accent
/// and inks, and the contrast floors cover what they follow. Everything else (fonts,
/// geometry, shadows, display effects) comes from `base`: for a new theme, the seed
/// `seed(from:id:name:)` made from the theme it was started from.
public enum SimpleThemeBuilder {
    /// The strengths the built-in themes use; grain and blasted are tuned from captures.
    public static func strength(of material: ShellMaterial) -> Double {
        switch material {
        case .weave: return 0.09
        case .brushed: return 0.06
        case .plastic: return 0.05
        case .grain: return 0.10
        case .blasted: return 0.06
        }
    }

    public static let coverLookStrength = 0.55
    public static let coverPixelSize = 1.5
    static let coverPixelSizeKey = "coverPixelSize"
    static let monochromeKey = "oledMonochrome"

    /// The effects Simple decides; a layer's own value for one would out-vote the choice.
    static let ownedEffectKeys: [String] = ShellMaterial.allCases.map(\.effectKey)
        + CoverScreenLook.allCases.map(\.effectKey) + [coverPixelSizeKey]

    /// A new Simple theme's starting point, made from `original` as the app draws it
    /// (already resolved against its own parents, as `ThemeManifest.definition` is):
    /// a new id and name, no parent, no logo, no colours, and the original's fonts,
    /// geometry, shadows and effects copied in. Layer-specific shadows and effects stay
    /// in their layers, so BOTH keeps each look's own and LIGHT or DARK takes that
    /// appearance's. An adaptive original gives an adaptive seed. The recipe is left
    /// for the caller (`SimplePaletteExtractor`).
    public static func seed(from original: ThemeDefinition, id: String, name: String) -> ThemeDefinition {
        // A single-appearance original is drawn from one layer only, whatever stray
        // layer it carries.
        let source = original.isAdaptive ? original : original.resolved(for: original.baseAppearance)
        var seed = ThemeDefinition(
            id: id,
            name: name,
            baseAppearance: original.baseAppearance,
            shadows: source.shadows,
            fonts: source.fonts,
            geometry: source.geometry,
            effects: source.effects
        )
        if original.isAdaptive {
            for appearance in [ThemeDefinition.BaseAppearance.light, .dark] {
                let layer = original.variant(for: appearance)
                seed.setVariant(ThemeVariant(shadows: layer?.shadows, effects: layer?.effects), for: appearance)
            }
        }
        return seed
    }

    public static func build(state: SimpleThemeState, choices: SimpleThemeChoices,
                             onto base: ThemeDefinition) -> ThemeDefinition {
        var theme = base
        var recipe = state.recipe
        recipe.recipe = SimplePaletteRecipe.currentVersion
        theme.simple = recipe
        theme.inherits = nil
        theme.logo = nil

        let palette = state.palette.compactMap(PaletteColor.init(hex:))
        func tokens(for appearance: ThemeDefinition.BaseAppearance) -> [String: String] {
            let jobColors = SimplePaletteAssigner.jobColors(palette: palette, assignment: state.assignment,
                                                            appearance: appearance)
            return SimplePaletteRecipe.tokens(jobColors: jobColors, contrast: state.contrast, appearance: appearance)
        }

        var effects: [String: Double]
        switch choices.appearance {
        case .light, .dark:
            let appearance: ThemeDefinition.BaseAppearance = choices.appearance == .light ? .light : .dark
            // The chosen look's own shadows and effects, flattened into the shared set.
            let flat = base.resolved(for: appearance)
            let written = tokens(for: appearance)
            theme.colors = written
            theme.shadows = flat.shadows
            effects = flat.effects ?? [:]
            if glassIsLighterThanText(written) { effects[monochromeKey] = 1 }
            theme.light = nil
            theme.dark = nil
            theme.baseAppearance = appearance
        case .both:
            theme.colors = nil
            effects = base.effects ?? [:]
            for appearance in [ThemeDefinition.BaseAppearance.light, .dark] {
                var layer = base.variant(for: appearance) ?? ThemeVariant()
                let written = tokens(for: appearance)
                layer.colors = written
                layer.logo = nil
                var layerEffects = layer.effects ?? [:]
                for key in ownedEffectKeys { layerEffects[key] = nil }
                // A layer's own: the other look's glass may be dark.
                if glassIsLighterThanText(written) { layerEffects[monochromeKey] = 1 }
                layer.effects = layerEffects.isEmpty ? nil : layerEffects
                theme.setVariant(layer, for: appearance)
            }
        }

        for material in ShellMaterial.allCases {
            effects[material.effectKey] = material == choices.material ? strength(of: material) : 0
        }
        for look in CoverScreenLook.allCases {
            effects[look.effectKey] = look == choices.coverLook ? coverLookStrength : 0
        }
        if choices.coverLook != nil { effects[coverPixelSizeKey] = coverPixelSize }
        theme.effects = effects

        if !choices.fonts.isEmpty {
            theme.fonts = (base.fonts ?? [:]).merging(choices.fonts) { _, new in new }
        }
        return theme
    }

    /// A pale glass (an LCD) under darker screen text: the display's lamps, LED matrix
    /// and NOW colours, chosen for a dark glass, would not read on it, so the display
    /// draws everything in the screen text instead (`oledMonochrome`). A dark glass
    /// leaves the value the theme was started with.
    static func glassIsLighterThanText(_ tokens: [String: String]) -> Bool {
        guard let glass = tokens["oledSurface"].flatMap(PaletteColor.init(hex:)),
              let text = tokens["oledForeground"].flatMap(PaletteColor.init(hex:)) else { return false }
        return glass.relativeLuminance > text.relativeLuminance
    }
}
