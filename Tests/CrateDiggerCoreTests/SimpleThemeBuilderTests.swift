import XCTest
@testable import CrateDiggerCore

final class SimpleThemeBuilderTests: XCTestCase {
    private func loadBase(_ name: String) throws -> ThemeDefinition {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        url.appendPathComponent("Sources/CrateDiggerApp/Resources/Themes/\(name).cdtheme/theme.json")
        return try JSONDecoder().decode(ThemeDefinition.self, from: Data(contentsOf: url))
    }

    private let state = SimpleThemeState(recipe: SimpleThemeRecipe(palette: ["#1D2433", "#E9E4D8", "#D9482B", "#3C9D8A"]))

    private func choices(_ appearance: SimpleAppearanceMode = .dark, material: ShellMaterial? = nil,
                         look: CoverScreenLook? = nil) -> SimpleThemeChoices {
        SimpleThemeChoices(appearance: appearance, material: material, coverLook: look, fonts: [:])
    }

    func testBothWritesBothLayersAndKeepsBaseEffects() throws {
        let built = SimpleThemeBuilder.build(state: state, choices: choices(.both), onto: try loadBase("Pocket"))
        XCTAssertNotNil(built.light)
        XCTAssertNotNil(built.dark)
        XCTAssertTrue(built.isAdaptive)
        XCTAssertEqual(built.effects?["oledMonochrome"], 1)
        XCTAssertEqual(built.simple, state.recipe)
        for key in SimplePaletteRecipe.simpleWrittenTokens {
            XCTAssertNil(built.colors?[key], "\(key) must not stay in shared colours")
        }
        XCTAssertNotEqual(built.light?.colors?["paper"], built.dark?.colors?["paper"])
    }

    func testSingleAppearanceClearsLayers() throws {
        let built = SimpleThemeBuilder.build(state: state, choices: choices(.light), onto: try loadBase("Pocket"))
        XCTAssertNil(built.light)
        XCTAssertNil(built.dark)
        XCTAssertEqual(built.baseAppearance, .light)
        XCTAssertNotNil(built.colors?["paper"])
        XCTAssertFalse(built.isAdaptive)
    }

    func testMaterialIsExclusive() throws {
        let base = try loadBase("Pocket")
        let strengths: [ShellMaterial: Double] = [.weave: 0.09, .brushed: 0.06, .plastic: 0.05, .grain: 0.10, .blasted: 0.06]
        for material in ShellMaterial.allCases {
            let built = SimpleThemeBuilder.build(state: state, choices: choices(material: material), onto: base)
            for other in ShellMaterial.allCases {
                let value = built.effects?[other.effectKey]
                XCTAssertEqual(value, other == material ? strengths[material] : 0, "\(material)/\(other)")
            }
            XCTAssertEqual(ShellMaterial.resolve(effects: built.effects ?? [:])?.material, material)
        }
        let none = SimpleThemeBuilder.build(state: state, choices: choices(material: nil), onto: base)
        XCTAssertNil(ShellMaterial.resolve(effects: none.effects ?? [:]))
    }

    func testCoverLookIsExclusive() throws {
        let base = try loadBase("Pocket")
        for look in CoverScreenLook.allCases {
            let built = SimpleThemeBuilder.build(state: state, choices: choices(look: look), onto: base)
            for other in CoverScreenLook.allCases {
                XCTAssertEqual(built.effects?[other.effectKey], other == look ? 0.55 : 0)
            }
            XCTAssertEqual(built.effects?["coverPixelSize"], 1.5)
        }
        let none = SimpleThemeBuilder.build(state: state, choices: choices(look: nil), onto: base)
        XCTAssertNil(CoverScreenLook.resolve(effects: none.effects ?? [:]))
    }

    func testLayerEffectsCannotOverrideChoice() throws {
        var base = try loadBase("Pocket")
        base.light = ThemeVariant(effects: ["shellBrushed": 0.3, "coverGrid": 0.9])
        base.dark = ThemeVariant()
        let built = SimpleThemeBuilder.build(state: state, choices: choices(.both, material: .weave), onto: base)
        for appearance in [ThemeDefinition.BaseAppearance.light, .dark] {
            let flat = built.resolved(for: appearance)
            XCTAssertEqual(ShellMaterial.resolve(effects: flat.effects ?? [:])?.material, .weave)
            XCTAssertNil(CoverScreenLook.resolve(effects: flat.effects ?? [:]))
        }
    }

    func testFontsMergeOntoBase() throws {
        var c = choices()
        c.fonts = ["sans": ThemeFont(regular: "Inter-Regular")]
        var base = try loadBase("Llama 97")
        let baseMono = base.fonts?["mono"]
        base.fonts?["sans"] = nil
        let built = SimpleThemeBuilder.build(state: state, choices: c, onto: base)
        XCTAssertEqual(built.fonts?["sans"]?.regular, "Inter-Regular")
        XCTAssertEqual(built.fonts?["mono"], baseMono)
    }

    func testBuildIsDeterministic() throws {
        let base = try loadBase("Pocket")
        let c = choices(.both, material: .brushed, look: .pixel)
        XCTAssertEqual(SimpleThemeBuilder.build(state: state, choices: c, onto: base),
                       SimpleThemeBuilder.build(state: state, choices: c, onto: base))
    }

    // MARK: Self-contained

    func testSeedCopiesNonColourSettingsAndNothingElse() throws {
        var original = try loadBase("Llama 97")
        original.inherits = "somewhere"
        let seed = SimpleThemeBuilder.seed(from: original, id: "new", name: "New")
        XCTAssertEqual(seed.id, "new")
        XCTAssertEqual(seed.name, "New")
        XCTAssertNil(seed.inherits)
        XCTAssertNil(seed.logo)
        XCTAssertNil(seed.author)
        XCTAssertNil(seed.colors)
        XCTAssertNil(seed.simple)
        XCTAssertEqual(seed.fonts, original.fonts)
        XCTAssertEqual(seed.geometry, original.geometry)
        XCTAssertEqual(seed.effects, original.effects)
        XCTAssertEqual(seed.shadows, original.shadows)
        XCTAssertTrue(seed.isAdaptive)
        for appearance in [ThemeDefinition.BaseAppearance.light, .dark] {
            let layer = try XCTUnwrap(seed.variant(for: appearance))
            XCTAssertNil(layer.colors, "\(appearance)")
            XCTAssertNil(layer.logo, "\(appearance)")
            XCTAssertEqual(layer.shadows, original.variant(for: appearance)?.shadows, "\(appearance)")
            XCTAssertEqual(layer.effects, original.variant(for: appearance)?.effects, "\(appearance)")
        }
    }

    func testSeedFromSingleAppearanceFlattensItsOwnLayer() throws {
        var original = try loadBase("Llama 97")
        original.light = nil   // not adaptive: only the dark layer draws
        let seed = SimpleThemeBuilder.seed(from: original, id: "new", name: "New")
        XCTAssertFalse(seed.isAdaptive)
        XCTAssertNil(seed.light)
        XCTAssertNil(seed.dark)
        XCTAssertEqual(seed.shadows, original.resolved(for: .dark).shadows)
    }

    func testBuiltThemeNamesNoParentNoLogoAndNoOverride() throws {
        var base = SimpleThemeBuilder.seed(from: try loadBase("Llama 97"), id: "n", name: "N")
        base.inherits = "llama-97"
        base.logo = "logo-dark.pdf"
        base.colors = ["keyLamp": "#FF0D19", "chassis": "#000000"]
        let overrides: Set<String> = ["lampNow", "lampConvert", "lampScan", "lampSync", "lampCD", "lampDevices",
                                      "lampSearch", "lampStats", "transportLamp", "keyLamp", "meterHot",
                                      "chassisInk", "columnHeaderInk"]
        for mode in SimpleAppearanceMode.allCases {
            let built = SimpleThemeBuilder.build(state: state, choices: choices(mode), onto: base)
            XCTAssertNil(built.inherits, "\(mode)")
            XCTAssertNil(built.logo, "\(mode)")
            XCTAssertNil(built.light?.logo, "\(mode)")
            XCTAssertNil(built.dark?.logo, "\(mode)")
            for appearance in [ThemeDefinition.BaseAppearance.light, .dark] {
                let colors = built.resolved(for: appearance).colors ?? [:]
                XCTAssertTrue(overrides.isDisjoint(with: colors.keys), "\(mode) \(appearance): \(overrides.intersection(colors.keys))")
            }
        }
    }

    /// LIGHT or DARK over an adaptive base takes that look's own shadows and effects.
    func testSingleAppearanceTakesThatLooksShadowsAndEffects() throws {
        var base = SimpleThemeBuilder.seed(from: try loadBase("Llama 97"), id: "n", name: "N")
        base.light?.effects = ["oledGlare": 0.4]
        for (mode, appearance) in [(SimpleAppearanceMode.light, ThemeDefinition.BaseAppearance.light),
                                   (.dark, .dark)] {
            let built = SimpleThemeBuilder.build(state: state, choices: choices(mode), onto: base)
            XCTAssertEqual(built.shadows, base.resolved(for: appearance).shadows, "\(mode)")
            XCTAssertEqual(built.effects?["oledGlare"], base.resolved(for: appearance).effects?["oledGlare"], "\(mode)")
        }
    }

    func testBuildStampsTheCurrentRecipeVersion() throws {
        let old = SimpleThemeState(recipe: SimpleThemeRecipe(palette: ["#1D2433", "#E9E4D8"], recipe: 0))
        let built = SimpleThemeBuilder.build(state: old, choices: choices(), onto: try loadBase("Carbon"))
        XCTAssertEqual(built.simple?.recipe, SimplePaletteRecipe.currentVersion)
        XCTAssertNotEqual(SimpleThemeRecipe(palette: ["#1D2433", "#E9E4D8"]).recipe, 0,
                          "a new recipe is the current table's, not 0")
    }

    func testContrastFloorsHoldOnBuiltTheme() throws {
        let base = try loadBase("Carbon")
        for contrast in SimpleContrast.allCases {
            var s = state
            s.contrast = contrast
            let built = SimpleThemeBuilder.build(state: s, choices: choices(.both), onto: base)
            for appearance in [ThemeDefinition.BaseAppearance.light, .dark] {
                let tokens = built.resolved(for: appearance).colors ?? [:]
                for pair in ContrastFloors.pairs(contrast: contrast) {
                    let ratio = try XCTUnwrap(ContrastFloors.ratio(of: pair, in: tokens),
                                              "\(pair.foreground)/\(pair.background) missing")
                    XCTAssertGreaterThanOrEqual(ratio, pair.minimum, "\(contrast) \(appearance) \(pair.foreground) on \(pair.background)")
                }
            }
        }
    }
}
