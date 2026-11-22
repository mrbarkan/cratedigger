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

    public static func build(state: SimpleThemeState, choices: SimpleThemeChoices,
                             onto base: ThemeDefinition) -> ThemeDefinition {
        var theme = base
        theme.simple = state.recipe

        let palette = state.palette.compactMap(PaletteColor.init(hex:))
        func tokens(for appearance: ThemeDefinition.BaseAppearance) -> [String: String] {
            let jobColors = SimplePaletteAssigner.jobColors(palette: palette, assignment: state.assignment,
                                                            appearance: appearance)
            return SimplePaletteRecipe.tokens(jobColors: jobColors, contrast: state.contrast, appearance: appearance)
        }

        let ownedEffectKeys = ShellMaterial.allCases.map(\.effectKey)
            + CoverScreenLook.allCases.map(\.effectKey) + [coverPixelSizeKey]

        switch choices.appearance {
        case .light, .dark:
            let appearance: ThemeDefinition.BaseAppearance = choices.appearance == .light ? .light : .dark
            theme.colors = (base.colors ?? [:]).merging(tokens(for: appearance)) { _, new in new }
            theme.light = nil
            theme.dark = nil
            theme.baseAppearance = appearance
        case .both:
            var shared = base.colors ?? [:]
            for key in SimplePaletteRecipe.simpleWrittenTokens { shared[key] = nil }
            theme.colors = shared.isEmpty ? nil : shared
            for appearance in [ThemeDefinition.BaseAppearance.light, .dark] {
                var layer = base.variant(for: appearance) ?? ThemeVariant()
                layer.colors = (layer.colors ?? [:]).merging(tokens(for: appearance)) { _, new in new }
                // A layer's own effects would out-vote the choice made here.
                if var effects = layer.effects {
                    for key in ownedEffectKeys { effects[key] = nil }
                    layer.effects = effects.isEmpty ? nil : effects
                }
                theme.setVariant(layer, for: appearance)
            }
        }

        var effects = base.effects ?? [:]
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
}
