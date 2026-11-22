import XCTest
@testable import CrateDiggerCore

final class SimplePaletteExtractorAdaptiveTests: XCTestCase {
    private func carbon() throws -> ThemeDefinition {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        url.appendPathComponent("Sources/CrateDiggerApp/Resources/Themes/Carbon.cdtheme/theme.json")
        return try JSONDecoder().decode(ThemeDefinition.self, from: Data(contentsOf: url))
    }

    func testAdaptiveBringsLightOnlyColoursAsUnassignedExtras() throws {
        let def = try carbon()
        let r = SimplePaletteExtractor.recipe(from: def, resolvedBase: [:])
        XCTAssertLessThanOrEqual(r.palette.count, 6)
        let assigned = Set(assignedIndices(r).values)
        XCTAssertLessThan(assigned.count, r.palette.count, "at least one unassigned extra")
        let light = def.resolved(for: .light).colors ?? [:]
        let lightAnchors = SimplePaletteExtractor.anchorTokens.values.compactMap { light[$0].flatMap(PaletteColor.init(hex:)) }
        // Every unassigned swatch is a light-layer anchor colour.
        for (i, hex) in r.palette.enumerated() where !assigned.contains(i) {
            let swatch = PaletteColor(hex: hex)!
            XCTAssertTrue(lightAnchors.contains { $0.distance(to: swatch) < 0.001 }, hex)
        }
    }

    func testAdaptivePinsStayOnPrimaryLayer() throws {
        let def = try carbon()
        let r = SimplePaletteExtractor.recipe(from: def, resolvedBase: [:])
        let dark = def.resolved(for: .dark).colors ?? [:]
        XCTAssertTrue(r.pins.isEmpty)
        XCTAssertEqual(Set(assignedIndices(r).keys), Set(ThemeJob.allCases))
        for (job, key) in SimplePaletteExtractor.anchorTokens {
            let swatch = PaletteColor(hex: r.palette[assignedIndices(r)[job]!])!
            XCTAssertLessThan(swatch.distance(to: PaletteColor(hex: dark[key]!)!), SimplePaletteExtractor.mergeDistance)
        }
    }

    func testSingleAppearanceThemeHasNoExtras() {
        let def = ThemeDefinition(id: "t", name: "T", baseAppearance: .dark, colors: [
            "chassis": "#202020", "paper": "#303030", "ink": "#F0F0F0",
            "orange": "#FF6D3F", "oledSurface": "#000000", "oledForeground": "#88FFAA"
        ])
        let r = SimplePaletteExtractor.recipe(from: def, resolvedBase: [:])
        XCTAssertEqual(Set(assignedIndices(r).values).count, r.palette.count)
    }

    func testKeptSwatchesDropsUnassignedExtrasFirst() {
        let kept = SimplePaletteExtractor.keptSwatches(uses: [1, 1, 1, 1, 1, 1, 0, 0], assigned: Set(0...5), limit: 6)
        XCTAssertEqual(kept, [0, 1, 2, 3, 4, 5])
        // A assigned swatch survives over a better-used unassigned one.
        XCTAssertEqual(SimplePaletteExtractor.keptSwatches(uses: [1, 1, 5], assigned: [0, 1], limit: 2), [0, 1])
        // Only when nothing unassigned is left does the least-used assigned one go.
        XCTAssertEqual(SimplePaletteExtractor.keptSwatches(uses: [3, 1, 2], assigned: [0, 1, 2], limit: 2), [0, 2])
    }

    func testJobColorsOfEmptyPaletteIsEmpty() {
        XCTAssertTrue(SimplePaletteAssigner.jobColors(palette: [], assignment: [:], appearance: .dark).isEmpty)
    }
}
