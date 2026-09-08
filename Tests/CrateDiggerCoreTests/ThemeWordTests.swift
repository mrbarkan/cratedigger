import XCTest
@testable import CrateDiggerCore

final class ThemeWordTests: XCTestCase {

    func testEveryOtherThemeKeepsTheWordTheme() {
        for id in ["carbon", "cobalt", "apple-music", nil] {
            XCTAssertEqual(ThemeWord.inflect("THEME", themeID: id), "THEME")
            XCTAssertEqual(ThemeWord.inflect("Theme Editor…", themeID: id), "Theme Editor…")
        }
    }

    func testLlamaSaysSkinInEveryCasing() {
        let id = ThemeWord.skinThemeID
        XCTAssertEqual(ThemeWord.inflect("THEME", themeID: id), "SKIN")
        XCTAssertEqual(ThemeWord.inflect("Theme Editor…", themeID: id), "Skin Editor…")
        XCTAssertEqual(ThemeWord.inflect("No theme loaded", themeID: id), "No skin loaded")
    }

    /// The plural has to be replaced before the singular, or "THEMES" comes
    /// out as "SKINS" only by luck — and as "SKINS" with a stray S if not.
    func testPluralsSurviveTheSwap() {
        let id = ThemeWord.skinThemeID
        XCTAssertEqual(ThemeWord.inflect("Refresh Themes", themeID: id), "Refresh Skins")
        XCTAssertEqual(ThemeWord.inflect("THEMES", themeID: id), "SKINS")
        XCTAssertEqual(ThemeWord.inflect("No themes installed.", themeID: id), "No skins installed.")
    }

    func testAWholeSentenceKeepsEverythingElse() {
        XCTAssertEqual(
            ThemeWord.inflect("THEME — appearance and installed skins, in the inspector.",
                              themeID: ThemeWord.skinThemeID),
            "SKIN — appearance and installed skins, in the inspector."
        )
    }
}
