#if canImport(XCTest)
import CrateDiggerCore
import SwiftUI
import XCTest
@testable import CrateDiggerApp

/// The shell materials: what each shipped theme resolves to, and the tiles
/// they are drawn from.
///
/// The themes half exists because a shipped theme that quietly started
/// resolving a different material (or two) would only be caught by someone
/// squinting at the chassis.
final class ShellMaterialTests: XCTestCase {

    private var themes: [String: ThemeDefinition] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CrateDiggerAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/CrateDiggerApp/Resources/Themes", isDirectory: true)
        let result = ThemeLoaderService(bundles: [], userThemesDirectoryOverride: directory).discoverThemes()
        themes = Dictionary(uniqueKeysWithValues: result.themes.map { ($0.id, $0.definition) })
    }

    /// Rendered the way `ThemeRegistry` renders it, for one layer.
    private func render(_ id: String, _ appearance: ThemeDefinition.BaseAppearance) throws -> CarbonTheme {
        let definition = try XCTUnwrap(themes[id], "\(id) is not bundled").resolved(for: appearance)
        return CarbonTheme(definition: definition,
                           resolvedBase: definition.baseAppearance == .dark ? .carbon : .linen)
    }

    // MARK: - The shipped themes

    /// The materials each shipped theme was given on 2026-11-10, chosen by the
    /// owner from live captures: Carbon traded its grain for the weave it is
    /// named after, Llama '97 got the brushed chrome of its era, and Cobalt
    /// stayed bare. None of them has a cover look.
    func testShippedThemesCarryTheirChosenMaterials() throws {
        let expected: [(id: String, material: ShellMaterial?, strength: Double)] = [
            ("carbon", .weave, 0.14),
            ("llama-97", .brushed, 0.16),
            ("cobalt", nil, 0),
        ]
        for (id, material, strength) in expected {
            for appearance in [ThemeDefinition.BaseAppearance.light, .dark] {
                let theme = try render(id, appearance)
                XCTAssertEqual(theme.shellMaterial, material, "\(id) \(appearance)")
                XCTAssertEqual(theme.shellMaterialStrength, strength, accuracy: 0.000001, "\(id) \(appearance)")
                XCTAssertEqual(theme.grainAmount, 0, "\(id) \(appearance): one material at a time")
                XCTAssertNil(theme.coverScreenLook, "\(id) \(appearance) resolves a cover look")
            }
        }
    }

    func testPocketIsPlasticWithAPixelScreen() throws {
        for appearance in [ThemeDefinition.BaseAppearance.light, .dark] {
            let theme = try render("pocket", appearance)
            XCTAssertEqual(theme.shellMaterial, .plastic)
            XCTAssertEqual(theme.shellMaterialStrength, 0.08, accuracy: 0.0001)
            XCTAssertEqual(theme.coverScreenLook, .pixel)
            XCTAssertEqual(theme.coverScreenStrength, 0.55, accuracy: 0.0001)
            XCTAssertEqual(theme.coverPixelSize, 1.5)
        }
    }

    // MARK: - Tiles

    private let materials: [ShellMaterial] = [.plastic, .brushed, .blasted, .weave]

    func testGrainHasNoMaterialTile() {
        XCTAssertNil(ShellMaterialTexture.tiles(for: .grain), "grain is CarbonTexture's, untouched")
    }

    func testEveryMaterialHasBothHalves() throws {
        for material in materials {
            let tiles = try XCTUnwrap(ShellMaterialTexture.tiles(for: material))
            XCTAssertGreaterThan(tiles.light.size.width, 0, "\(material)")
            XCTAssertGreaterThan(tiles.dark.size.height, 0, "\(material)")
            XCTAssertGreaterThan(tiles.fieldMax, 0, "\(material)")

            let field = ShellMaterialTexture.field(for: material)
            XCTAssertEqual(field.values.count, field.width * field.height)
            XCTAssertTrue(field.values.contains { $0 > 0 }, "\(material) has no light half")
            XCTAssertTrue(field.values.contains { $0 < 0 }, "\(material) has no dark half")
            XCTAssertEqual(Double(field.values.map(abs).max() ?? 0), tiles.fieldMax, accuracy: 0.0001)
        }
    }

    /// The tiles are 2x and sized in points, so they repeat at the size the
    /// design gives them and not at the pixel count.
    func testTileSizesInPoints() {
        XCTAssertEqual(ShellMaterialTexture.plastic.light.size, NSSize(width: 256, height: 256))
        XCTAssertEqual(ShellMaterialTexture.brushed.light.size, NSSize(width: 512, height: 128))
        XCTAssertEqual(ShellMaterialTexture.blasted.light.size, NSSize(width: 256, height: 256))
        XCTAssertEqual(ShellMaterialTexture.weave.light.size, NSSize(width: 64, height: 64))
        XCTAssertEqual(ShellMaterialTexture.field(for: .brushed).width, 1024)
    }

    /// Seeded: the same on every launch, so two snapshots can be compared.
    func testFieldsAreDeterministic() {
        for material in materials {
            XCTAssertEqual(ShellMaterialTexture.field(for: material).values,
                           ShellMaterialTexture.field(for: material).values,
                           "\(material) changed between two generations")
        }
    }

    /// No seam: across the tile's edge, neighbouring pixels differ by as much
    /// as they do across the middle of the tile, and no more. The middle pair
    /// is half a tile in, which for the weave is a whole number of twill
    /// repeats, so it sits at the same place in the pattern as the edge.
    func testTilesWrapWithoutASeam() {
        for material in materials {
            let field = ShellMaterialTexture.field(for: material)
            let w = field.width, h = field.height

            var edgeX: Float = 0, middleX: Float = 0
            for y in 0..<h {
                edgeX += abs(field[w - 1, y] - field[0, y])
                middleX += abs(field[w / 2 - 1, y] - field[w / 2, y])
            }
            var edgeY: Float = 0, middleY: Float = 0
            for x in 0..<w {
                edgeY += abs(field[x, h - 1] - field[x, 0])
                middleY += abs(field[x, h / 2 - 1] - field[x, h / 2])
            }
            assertSimilar(edgeX, middleX, "\(material) left/right edge")
            assertSimilar(edgeY, middleY, "\(material) top/bottom edge")
        }
    }

    private func assertSimilar(_ edge: Float, _ middle: Float, _ what: String) {
        let ratio = Double(edge) / max(Double(middle), 1e-9)
        XCTAssertTrue((0.7...1.4).contains(ratio), "\(what): seam ratio \(ratio)")
    }

    /// The unit rule: the drawn layer's opacity times a texel's stored alpha
    /// is `strength × 22/255 × |f|`, so a field value of 1 at strength 1 moves
    /// a pixel by 22 of 255 whatever `fieldMax` turned out to be.
    func testOpacityFollowsTheUnitRule() {
        for material in materials {
            let tiles = ShellMaterialTexture.field(for: material)
            let encoded = ShellMaterialTexture.tiles(from: tiles)
            let alphaForUnitField = 1 / encoded.fieldMax
            XCTAssertEqual(encoded.opacity(forStrength: 1) * alphaForUnitField, 22.0 / 255.0, accuracy: 0.0001)
        }
        XCTAssertLessThanOrEqual(ShellMaterialTexture.blasted.opacity(forStrength: 100), 1)
    }

    /// Only the metals carry the sheen.
    func testSheenIsForTheMetalsOnly() {
        XCTAssertEqual(ShellMaterialTexture.sheenFactor(for: .brushed), 0.5)
        XCTAssertEqual(ShellMaterialTexture.sheenFactor(for: .blasted), 0.4)
        XCTAssertEqual(ShellMaterialTexture.sheenFactor(for: .plastic), 0)
        XCTAssertEqual(ShellMaterialTexture.sheenFactor(for: .weave), 0)
        XCTAssertEqual(ShellMaterialTexture.sheenFactor(for: .grain), 0)
    }
}
#endif
