import XCTest
@testable import CrateDiggerCore

/// A pale Screen Glass (an LCD rather than an OLED) has to stay readable everywhere
/// the app draws on it: the display's lamps, LED matrix and NOW colours collapse to
/// the screen text (`oledMonochrome`), and the mini player's time, which is drawn in
/// the accent whatever the glass, reads at 3:1 because the glass gives way to the
/// accent. Measured on themes the builder makes, shuffles included, since a Shuffle is
/// what puts a pale colour on the glass.
final class SimplePaleGlassTests: XCTestCase {
    private func loadBase(_ name: String) throws -> ThemeDefinition {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        url.appendPathComponent("Sources/CrateDiggerApp/Resources/Themes/\(name).cdtheme/theme.json")
        return try JSONDecoder().decode(ThemeDefinition.self, from: Data(contentsOf: url))
    }

    private func choices(_ mode: SimpleAppearanceMode) -> SimpleThemeChoices {
        SimpleThemeChoices(appearance: mode, material: nil, coverLook: nil, fonts: [:])
    }

    private func written(_ mode: SimpleAppearanceMode) -> [ThemeDefinition.BaseAppearance] {
        switch mode {
        case .light: return [.light]
        case .dark: return [.dark]
        case .both: return [.light, .dark]
        }
    }

    private func color(_ key: String, _ tokens: [String: String]) -> PaletteColor {
        PaletteColor(hex: tokens[key] ?? "")!
    }

    private func monochrome(_ flat: ThemeDefinition) -> Bool {
        (flat.effects?["oledMonochrome"] ?? 0) > 0.5
    }

    /// Checks one built theme in every appearance it writes. Returns how many of those
    /// had a glass lighter than its text.
    @discardableResult
    private func check(_ built: ThemeDefinition, mode: SimpleAppearanceMode, baseMonochrome: Bool,
                       _ label: String, file: StaticString = #filePath, line: UInt = #line) -> Int {
        var pale = 0
        for appearance in written(mode) {
            let flat = built.resolved(for: appearance)
            let tokens = flat.colors ?? [:]
            let glass = color("oledSurface", tokens), text = color("oledForeground", tokens)
            let accent = color("orange", tokens)
            let where_ = "\(label) \(appearance) glass \(glass.hex) text \(text.hex) accent \(accent.hex)"
            if glass.relativeLuminance > text.relativeLuminance {
                pale += 1
                XCTAssertTrue(monochrome(flat), "pale glass must collapse the display — \(where_)",
                              file: file, line: line)
            } else {
                XCTAssertEqual(monochrome(flat), baseMonochrome, "a dark glass keeps the original's — \(where_)",
                               file: file, line: line)
            }
            XCTAssertGreaterThanOrEqual(PaletteColor.contrast(accent, glass), 3.0, "accent on glass — \(where_)",
                                        file: file, line: line)
            XCTAssertGreaterThanOrEqual(PaletteColor.contrast(text, glass), 7.0, "text on glass — \(where_)",
                                        file: file, line: line)
        }
        return pale
    }

    func testSeededPalettesAndShufflesKeepTheGlassReadable() throws {
        let carbon = try loadBase("Carbon")
        var rng = SplitMix64(seed: 0x61A55)
        var pale = 0
        for _ in 0..<120 {
            let count = 2 + Int(rng.next() % 5)
            let palette = (0..<count).map { _ in
                PaletteColor(r: rng.unit(), g: rng.unit(), b: rng.unit()).hex
            }
            var state = SimpleThemeState(recipe: SimpleThemeRecipe(palette: palette))
            for step in 0..<4 {
                if step > 0 { state.shuffle() }
                for mode in SimpleAppearanceMode.allCases {
                    let built = SimpleThemeBuilder.build(state: state, choices: choices(mode), onto: carbon)
                    pale += check(built, mode: mode, baseMonochrome: false, "\(palette) step \(step) \(mode)")
                }
            }
        }
        XCTAssertGreaterThan(pale, 0, "no seeded case had a pale glass, so the rule went unmeasured")
    }

    /// Pocket's light layer: a pale LCD with a deep accent stays pale, and goes monochrome.
    func testPaleGlassWithADeepAccentStaysPaleAndGoesMonochrome() throws {
        let recipe = SimpleThemeRecipe(
            palette: ["#C9C6BE", "#E4E1DA", "#1B1B22", "#A12A5E", "#B7BBB0", "#1F2326"],
            assignment: [.frame: 0, .panels: 1, .text: 2, .accent: 3, .glass: 4, .screenText: 5])
        let state = SimpleThemeState(recipe: recipe)
        let built = SimpleThemeBuilder.build(state: state, choices: choices(.light), onto: try loadBase("Carbon"))
        let tokens = built.colors ?? [:]
        XCTAssertEqual(tokens["oledSurface"], "#B7BBB0", "the glass already reads the accent at 3:1")
        XCTAssertEqual(built.effects?["oledMonochrome"], 1)
        XCTAssertEqual(check(built, mode: .light, baseMonochrome: false, "pocket light"), 1)
    }

    /// A pale glass under a bright accent cannot hold the accent at 3:1 however pale it
    /// gets, so it goes dark instead (the accent never moves), and the display keeps its colours.
    func testPaleGlassUnderABrightAccentGivesWay() throws {
        let recipe = SimpleThemeRecipe(
            palette: ["#1D2433", "#E9E4D8", "#FF6D3F", "#F3F0E6"],
            assignment: [.frame: 0, .panels: 0, .text: 1, .accent: 2, .glass: 3, .screenText: 0])
        let built = SimpleThemeBuilder.build(state: SimpleThemeState(recipe: recipe), choices: choices(.dark),
                                             onto: try loadBase("Carbon"))
        let tokens = built.colors ?? [:]
        XCTAssertEqual(tokens["orange"], "#FF6D3F", "the accent never moves")
        XCTAssertLessThan(color("oledSurface", tokens).relativeLuminance,
                          color("oledForeground", tokens).relativeLuminance)
        XCTAssertNotEqual(built.effects?["oledMonochrome"], 1)
        check(built, mode: .dark, baseMonochrome: false, "bright accent")
    }

    /// In BOTH, monochrome is a layer's own: only the layer whose glass is pale gets it.
    func testBothWritesMonochromeOnlyInThePaleLayer() throws {
        // In light the deep accent fits its band and the glass stays pale; in dark the
        // accent is lifted to the dark band's lightness and the glass gives way.
        let recipe = SimpleThemeRecipe(
            palette: ["#C9C6BE", "#E4E1DA", "#1B1B22", "#A12A5E", "#B7BBB0", "#1F2326"],
            assignment: [.frame: 0, .panels: 1, .text: 2, .accent: 3, .glass: 4, .screenText: 5])
        let built = SimpleThemeBuilder.build(state: SimpleThemeState(recipe: recipe), choices: choices(.both),
                                             onto: try loadBase("Carbon"))
        XCTAssertNotEqual(built.effects?["oledMonochrome"], 1, "not in the shared effects")
        XCTAssertEqual(built.light?.effects?["oledMonochrome"], 1)
        XCTAssertFalse(monochrome(built.resolved(for: .dark)))
        XCTAssertEqual(check(built, mode: .both, baseMonochrome: false, "both"), 1)
    }

    /// A dark glass leaves whatever the theme it was started from says.
    func testDarkGlassKeepsTheBaseValue() throws {
        let state = SimpleThemeState(recipe: SimpleThemeRecipe(
            palette: ["#1D2433", "#E9E4D8", "#D9482B", "#3C9D8A"],
            assignment: [.frame: 0, .panels: 0, .text: 1, .accent: 2, .glass: 0, .screenText: 1]))
        for value in [0.0, 1.0] {
            var base = try loadBase("Carbon")
            base.effects = ["oledMonochrome": value]
            for mode in SimpleAppearanceMode.allCases {
                let built = SimpleThemeBuilder.build(state: state, choices: choices(mode), onto: base)
                XCTAssertEqual(check(built, mode: mode, baseMonochrome: value == 1, "base \(value) \(mode)"), 0)
            }
        }
    }

    /// The floor itself: the accent on the glass is settled by moving the glass, never
    /// the accent, and the screen text still reads at 7:1 afterwards.
    func testEnforceMovesTheGlassNotTheAccent() {
        let tokens = ["orange": "#C0503A", "oledSurface": "#9A9488", "oledForeground": "#1A1A1A",
                      "oledForegroundMuted": "#1A1A1A8C"]
        let fixed = ContrastFloors.enforce(tokens, contrast: .standard)
        XCTAssertEqual(fixed["orange"], "#C0503A")
        let glass = PaletteColor(hex: fixed["oledSurface"]!)!
        XCTAssertGreaterThanOrEqual(PaletteColor.contrast(PaletteColor(hex: "#C0503A")!, glass), 3)
        XCTAssertGreaterThanOrEqual(PaletteColor.contrast(PaletteColor(hex: fixed["oledForeground"]!)!, glass), 7)
    }
}

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
