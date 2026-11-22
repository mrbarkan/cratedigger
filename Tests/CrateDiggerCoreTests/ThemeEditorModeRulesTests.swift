import XCTest
@testable import CrateDiggerCore

final class ThemeEditorModeRulesTests: XCTestCase {
    func testSimpleToAdvancedOffersConvert() {
        XCTAssertEqual(ThemeEditorModeRules.crossings(from: .simple, isBuiltIn: false), [.copy, .convert, .cancel])
        XCTAssertEqual(ThemeEditorModeRules.crossings(from: .simple, isBuiltIn: true), [.copy, .convert, .cancel])
    }

    func testAdvancedToSimpleNeverConverts() {
        XCTAssertEqual(ThemeEditorModeRules.crossings(from: .advanced, isBuiltIn: false), [.copy, .cancel])
        XCTAssertEqual(ThemeEditorModeRules.crossings(from: .advanced, isBuiltIn: true), [.copy, .cancel])
    }

    func testModeOfTheme() {
        var def = ThemeDefinition(id: "t", name: "T", baseAppearance: .dark)
        XCTAssertEqual(ThemeEditorModeRules.mode(of: def), .advanced)
        def.simple = SimpleThemeRecipe(palette: ["#112233", "#AABBCC"])
        XCTAssertEqual(ThemeEditorModeRules.mode(of: def), .simple)
    }
}
