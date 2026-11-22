import XCTest
@testable import CrateDiggerCore

final class SimplePaletteExtractorTests: XCTestCase {
    private func carbon() throws -> ThemeDefinition {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        url.appendPathComponent("Sources/CrateDiggerApp/Resources/Themes/Carbon.cdtheme/theme.json")
        return try JSONDecoder().decode(ThemeDefinition.self, from: Data(contentsOf: url))
    }

    func testExtractCarbonAssignsSixJobsNoPins() throws {
        let r = SimplePaletteExtractor.recipe(from: try carbon(), resolvedBase: [:])
        XCTAssertTrue(r.pins.isEmpty)
        XCTAssertEqual(Set(assignedIndices(r).keys), Set(ThemeJob.allCases))
        XCTAssertLessThanOrEqual(r.palette.count, 6)
        XCTAssertGreaterThanOrEqual(r.palette.count, 2)
        XCTAssertEqual(r.contrast, .standard)
        XCTAssertEqual(r.recipe, SimplePaletteRecipe.currentVersion)
        for index in assignedIndices(r).values { XCTAssertTrue(r.palette.indices.contains(index)) }
        XCTAssertEqual(r.sanitized(), r)
    }

    func testExtractMergesNearDuplicates() {
        let def = ThemeDefinition(id: "t", name: "T", baseAppearance: .dark, colors: [
            "chassis": "#202020", "paper": "#212121", "ink": "#F0F0F0",
            "orange": "#FF6D3F", "oledSurface": "#202020", "oledForeground": "#F1F1F1"
        ])
        let r = SimplePaletteExtractor.recipe(from: def, resolvedBase: [:])
        XCTAssertEqual(r.palette.count, 3)
        XCTAssertEqual(assignedIndices(r)[.frame], assignedIndices(r)[.panels])
        XCTAssertEqual(assignedIndices(r)[.frame], assignedIndices(r)[.glass])
        XCTAssertEqual(assignedIndices(r)[.text], assignedIndices(r)[.screenText])
    }

    func testExtractFallsBackToResolvedBase() {
        let def = ThemeDefinition(id: "t", name: "T", baseAppearance: .dark, colors: ["chassis": "#202020"])
        let base = ["paper": "#101820", "ink": "#FFFFFF", "orange": "#00FF88",
                    "oledSurface": "#000000", "oledForeground": "#88FFAA"]
        let r = SimplePaletteExtractor.recipe(from: def, resolvedBase: base)
        XCTAssertTrue(r.palette.contains("#00FF88"))
    }

    func testExtractedCarbonRebuildsAnchors() throws {
        let def = try carbon()
        let r = SimplePaletteExtractor.recipe(from: def, resolvedBase: [:])
        let palette = r.palette.map { PaletteColor(hex: $0)! }
        let jobs = SimplePaletteAssigner.jobColors(palette: palette, assignment: r.assignment, appearance: .dark)
        let tokens = SimplePaletteRecipe.tokens(jobColors: jobs, contrast: .standard, appearance: .dark)
        let dark = def.resolved(for: .dark).colors ?? [:]
        for (_, key) in SimplePaletteExtractor.anchorTokens {
            let want = PaletteColor(hex: dark[key]!)!
            let got = PaletteColor(hex: tokens[key]!)!
            // Near-duplicates merge within `mergeDistance` (ink and the cream screen text
            // sit 0.0225 apart), and the recipe separates chassis from paper (0.0213).
            XCTAssertLessThanOrEqual(want.distance(to: got), SimplePaletteExtractor.mergeDistance,"\(key): \(dark[key]!) vs \(tokens[key]!)")
        }
    }
}

/// The swatch each job was given, derived (nil) assignments left out.
func assignedIndices(_ recipe: SimpleThemeRecipe) -> [ThemeJob: Int] {
    recipe.assignment.compactMapValues { $0 }
}
