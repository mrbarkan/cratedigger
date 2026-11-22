import XCTest
@testable import CrateDiggerCore

final class ThemeEditorModeRulesTests: XCTestCase {
    func testSimpleToAdvancedOffersConvert() {
        XCTAssertEqual(ThemeEditorModeRules.crossings(from: .simple), [.copy, .convert, .cancel])
    }

    func testAdvancedToSimpleNeverConverts() {
        XCTAssertEqual(ThemeEditorModeRules.crossings(from: .advanced), [.copy, .cancel])
    }

    func testModeOfTheme() {
        var def = ThemeDefinition(id: "t", name: "T", baseAppearance: .dark)
        XCTAssertEqual(ThemeEditorModeRules.mode(of: def), .advanced)
        def.simple = SimpleThemeRecipe(palette: ["#112233", "#AABBCC"])
        XCTAssertEqual(ThemeEditorModeRules.mode(of: def), .simple)
    }
}
