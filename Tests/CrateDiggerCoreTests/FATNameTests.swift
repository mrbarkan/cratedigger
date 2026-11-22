import XCTest
@testable import CrateDiggerCore

final class FATNameTests: XCTestCase {
    func testIllegalCharactersReplaced() {
        XCTAssertEqual(FATName.component("Who's Next?", extension: nil), "Who's Next")
        XCTAssertEqual(FATName.component("AC/DC", extension: nil), "AC-DC")
        XCTAssertEqual(FATName.component("a<b>c|d\"e*", extension: nil), "a-b-c-d'e")
        XCTAssertEqual(FATName.component("a\\b:c", extension: "jpg"), "a-b-c.jpg")
    }

    func testTrailingDotsAndSpacesTrimmed() {
        XCTAssertEqual(FATName.component("R.E.M.", extension: nil), "R.E.M")
        XCTAssertEqual(FATName.component("Trailing . . ", extension: "jpg"), "Trailing.jpg")
        // "Who?" loses the ? first, then nothing is left to trim.
        XCTAssertEqual(FATName.component("Who. ?", extension: nil), "Who")
    }

    func testLeadingDotRemoved() {
        XCTAssertEqual(FATName.component(".hidden", extension: "jpg"), "hidden.jpg")
        XCTAssertEqual(FATName.component("..also", extension: nil), "also")
    }

    func testReservedNames() {
        XCTAssertEqual(FATName.component("con", extension: nil), "con_")
        XCTAssertEqual(FATName.component("LPT1", extension: "jpg"), "LPT1_.jpg")
        XCTAssertEqual(FATName.component("Nul", extension: nil), "Nul_")
        XCTAssertEqual(FATName.component("com9", extension: nil), "com9_")
        XCTAssertEqual(FATName.component("COM10", extension: nil), "COM10")
        XCTAssertEqual(FATName.component("Console", extension: nil), "Console")
    }

    func testControlCharacters() {
        XCTAssertEqual(FATName.component("a\u{0}b\u{1F}c\u{7F}d\te", extension: nil), "a_b_c_d_e")
    }

    func testOutputIsNFC() {
        let decomposed = "Bjo\u{308}rk"
        let result = FATName.component(decomposed, extension: "jpg")
        XCTAssertEqual(result, "Bj\u{F6}rk.jpg")
        XCTAssertEqual(result?.unicodeScalars.count, 9, "precomposed: one scalar for ö")
    }

    func testTruncatesOnGraphemeBoundaryKeepingExtension() throws {
        let flag = "\u{1F1F8}\u{1F1EA}" // a flag: one grapheme, four UTF-16 units
        let long = String(repeating: "é", count: 300) + flag
        let result = try XCTUnwrap(FATName.component(long, extension: "jpg"))
        XCTAssertEqual(result.utf16.count, 255)
        XCTAssertTrue(result.hasSuffix(".jpg"))
        XCTAssertEqual(result, String(repeating: "é", count: 251) + ".jpg")

        // The cut lands inside the flag: the whole flag goes, never half of it.
        let straddling = String(repeating: "é", count: 249) + flag + "tail"
        let cut = try XCTUnwrap(FATName.component(straddling, extension: "jpg"))
        XCTAssertEqual(cut, String(repeating: "é", count: 249) + ".jpg")
        XCTAssertLessThanOrEqual(cut.utf16.count, 255)

        let fits = String(repeating: "é", count: 247) + flag
        XCTAssertEqual(FATName.component(fits, extension: "jpg"), fits + ".jpg")
    }

    func testNothingLeftGivesNil() {
        XCTAssertNil(FATName.component("???", extension: nil))
        XCTAssertNil(FATName.component("...", extension: "jpg"))
        XCTAssertNil(FATName.component("", extension: "jpg"))
        XCTAssertNil(FATName.component(" . ", extension: nil))
    }

    func testFitsPlayerPathBoundary() {
        // "/<HDD0>/" is 8 bytes.
        let fits = String(repeating: "a", count: 244)
        let over = String(repeating: "a", count: 245)
        XCTAssertTrue(FATName.fitsPlayerPath(fits, prefix: nil))
        XCTAssertFalse(FATName.fitsPlayerPath(over, prefix: nil))
        // UTF-8 bytes, not characters: é is two.
        XCTAssertTrue(FATName.fitsPlayerPath(String(repeating: "é", count: 122), prefix: nil))
        XCTAssertFalse(FATName.fitsPlayerPath(String(repeating: "é", count: 122) + "a", prefix: nil))
        // A custom prefix replaces the default one.
        XCTAssertTrue(FATName.fitsPlayerPath(String(repeating: "a", count: 249), prefix: "/x"))
        XCTAssertFalse(FATName.fitsPlayerPath(String(repeating: "a", count: 249), prefix: "/xy"))
    }

    func testCollidesIgnoresCaseAndNormalisation() {
        XCTAssertTrue(FATName.collides("Björk.jpg", "BJO\u{308}RK.JPG"))
        XCTAssertTrue(FATName.collides("abc", "ABC"))
        XCTAssertFalse(FATName.collides("Bjork.jpg", "Björk.jpg"))
        XCTAssertFalse(FATName.collides("a", "b"))
    }
}
