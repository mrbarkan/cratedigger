import XCTest
@testable import CrateDiggerCore

/// Covers themes that carry both a light and a dark version in one file,
/// including the guarantee that every theme authored before variants existed
/// keeps loading and rendering exactly as it did.
final class ThemeVariantTests: XCTestCase {

    private func adaptive() -> ThemeDefinition {
        ThemeDefinition(
            id: "nothing",
            name: "Nothing",
            baseAppearance: .dark,
            colors: ["chassis": "#111111", "ink": "#EEEEEE", "orange": "#FF0000"],
            light: ThemeVariant(colors: ["chassis": "#FFFFFF", "ink": "#111111"]),
            dark: ThemeVariant()
        )
    }

    // MARK: - Resolution

    func testAdaptiveThemeReportsItself() {
        XCTAssertTrue(adaptive().isAdaptive)
        XCTAssertFalse(
            ThemeDefinition(id: "x", name: "X", baseAppearance: .dark, colors: ["ink": "#FFF000"]).isAdaptive
        )
    }

    /// A theme with only one layer isn't adaptive — it can't follow the system
    /// if it only knows one look.
    func testOneLayerIsNotAdaptive() {
        var definition = adaptive()
        definition.light = nil
        XCTAssertFalse(definition.isAdaptive)
    }

    func testResolvingLightAppliesTheLightLayer() {
        let resolved = adaptive().resolved(for: .light)
        XCTAssertEqual(resolved.colors?["chassis"], "#FFFFFF")
        XCTAssertEqual(resolved.colors?["ink"], "#111111")
        XCTAssertEqual(resolved.baseAppearance, .light, "the layer being rendered decides the appearance")
    }

    /// Tokens the layer doesn't mention fall through to the shared set — that's
    /// what keeps a light/dark pair from having to restate a whole palette.
    func testSharedTokensSurviveTheLayer() {
        let resolved = adaptive().resolved(for: .light)
        XCTAssertEqual(resolved.colors?["orange"], "#FF0000")
    }

    func testResolvingDarkKeepsTheSharedSet() {
        let resolved = adaptive().resolved(for: .dark)
        XCTAssertEqual(resolved.colors?["chassis"], "#111111")
        XCTAssertEqual(resolved.baseAppearance, .dark)
    }

    /// The compatibility guarantee: a theme with no layers is returned
    /// untouched whichever appearance is asked for.
    func testThemeWithoutLayersIgnoresTheRequestedAppearance() {
        let plain = ThemeDefinition(
            id: "carbon", name: "Carbon", baseAppearance: .dark, colors: ["chassis": "#171C22"]
        )
        XCTAssertEqual(plain.resolved(for: .light), plain)
        XCTAssertEqual(plain.resolved(for: .dark), plain)
    }

    // MARK: - Inheritance

    /// Inheriting an adaptive theme must inherit its adaptiveness, or a
    /// one-line child would silently collapse to a single appearance.
    func testChildInheritsBothLayers() {
        var warnings: [ThemeLoadWarning] = []
        let child = ThemeDefinition(
            id: "mine", name: "Mine", baseAppearance: .dark,
            inherits: "nothing", colors: ["orange": "#00FF00"]
        )
        let byID = ["nothing": adaptive(), "mine": child]

        let resolved = ThemeLoaderService.resolveInheritance(
            child, in: byID, warnings: &warnings, sourceURL: URL(fileURLWithPath: "/tmp/x.json")
        )

        XCTAssertTrue(resolved.isAdaptive)
        XCTAssertEqual(resolved.light?.colors?["chassis"], "#FFFFFF")
        XCTAssertEqual(resolved.colors?["orange"], "#00FF00", "the child's own override still wins")
    }

    func testChildLayerOverridesTheParentLayer() {
        var warnings: [ThemeLoadWarning] = []
        let child = ThemeDefinition(
            id: "mine", name: "Mine", baseAppearance: .dark, inherits: "nothing",
            light: ThemeVariant(colors: ["chassis": "#FAFAFA"])
        )
        let byID = ["nothing": adaptive(), "mine": child]

        let resolved = ThemeLoaderService.resolveInheritance(
            child, in: byID, warnings: &warnings, sourceURL: URL(fileURLWithPath: "/tmp/x.json")
        )

        XCTAssertEqual(resolved.light?.colors?["chassis"], "#FAFAFA")
        XCTAssertEqual(resolved.light?.colors?["ink"], "#111111", "untouched parent layer tokens survive")
    }

    // MARK: - Minimization

    /// A layer records only what that appearance changes; anything matching the
    /// shared set belongs in the shared set alone.
    func testMinimizationPrunesLayerTokensMatchingTheSharedSet() {
        var definition = adaptive()
        definition.light?.colors?["orange"] = "#FF0000"   // same as shared

        let minimized = ThemeAuthoringService.minimized(definition, against: nil)

        XCTAssertNil(minimized.light?.colors?["orange"])
        XCTAssertEqual(minimized.light?.colors?["chassis"], "#FFFFFF")
    }

    /// An empty layer must stay present: non-nil layers are what mark a theme
    /// adaptive, so pruning one away would turn a light/dark theme back into a
    /// single-appearance one on the next save.
    func testEmptyLayerIsKeptSoTheThemeStaysAdaptive() {
        let minimized = ThemeAuthoringService.minimized(adaptive(), against: nil)
        XCTAssertNotNil(minimized.dark, "dark layer is empty but must survive")
        XCTAssertTrue(minimized.isAdaptive)
    }

    // MARK: - Round trip

    func testAdaptiveThemeSurvivesEncodingAndDecoding() throws {
        let encoded = try JSONEncoder().encode(adaptive())
        let decoded = try JSONDecoder().decode(ThemeDefinition.self, from: encoded)

        XCTAssertEqual(decoded, adaptive())
        XCTAssertTrue(decoded.isAdaptive)
    }

    /// Themes written before variants existed have no `light`/`dark` keys at
    /// all — decoding must not require them.
    func testLegacyThemeJSONStillDecodes() throws {
        let json = """
        { "id": "old", "name": "Old", "baseAppearance": "dark", "colors": { "ink": "#FFFFFF" } }
        """
        let decoded = try JSONDecoder().decode(ThemeDefinition.self, from: Data(json.utf8))

        XCTAssertFalse(decoded.isAdaptive)
        XCTAssertNil(decoded.light)
        XCTAssertEqual(decoded.colors?["ink"], "#FFFFFF")
    }

    // MARK: - Font weights

    /// The shorthand every theme used before per-weight faces existed.
    func testFontDecodesFromABareString() throws {
        let json = """
        { "id": "old", "name": "Old", "baseAppearance": "dark", "fonts": { "sans": "Helvetica" } }
        """
        let decoded = try JSONDecoder().decode(ThemeDefinition.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.fonts?["sans"], ThemeFont(regular: "Helvetica"))
    }

    func testFontDecodesPerWeightFaces() throws {
        let json = """
        {
          "id": "x", "name": "X", "baseAppearance": "dark",
          "fonts": { "mono": { "regular": "Menlo-Regular", "bold": "Menlo-Bold" } }
        }
        """
        let decoded = try JSONDecoder().decode(ThemeDefinition.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.fonts?["mono"]?.regular, "Menlo-Regular")
        XCTAssertEqual(decoded.fonts?["mono"]?.face(for: .bold), "Menlo-Bold")
        XCTAssertNil(decoded.fonts?["mono"]?.face(for: .medium))
    }

    /// A single-face role stays a bare string on the way out, so adding weight
    /// support doesn't bloat every existing theme file on its next save.
    func testSingleFaceFontEncodesAsABareString() throws {
        let encoded = try JSONEncoder().encode(ThemeFont(regular: "Helvetica"))
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"Helvetica\"")
    }

    func testMultiWeightFontEncodesAsAnObject() throws {
        let font = ThemeFont(regular: "Menlo-Regular", bold: "Menlo-Bold")
        let encoded = try JSONEncoder().encode(font)
        XCTAssertEqual(try JSONDecoder().decode(ThemeFont.self, from: encoded), font)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("regular"))
    }

    /// An unnamed middle weight resolves upward to a heavier real face rather
    /// than dropping back to the base — asking for semibold on a family that
    /// ships regular and bold should look bold, not smeared.
    func testMissingWeightResolvesToTheNearestHeavierFace() {
        let font = ThemeFont(regular: "Menlo-Regular", bold: "Menlo-Bold")
        XCTAssertEqual(font.resolvedFace(for: .semibold), "Menlo-Bold")
        XCTAssertEqual(font.resolvedFace(for: .regular), "Menlo-Regular")
        XCTAssertNil(font.face(for: .semibold), "resolution must not invent a named face")
    }
}
