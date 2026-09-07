#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

/// Old rippers wrote the ID3v1 genre *number* instead of the name, and ID3v2
/// allowed "(17)" and "(17)Rock". A Genre column full of "17" rows is not a
/// library anyone can browse.
final class ID3GenreTests: XCTestCase {

    func testABareNumberBecomesTheID3v1Name() {
        XCTAssertEqual(ID3Genre.name(for: "17"), "Rock")
        XCTAssertEqual(ID3Genre.name(for: "5"), "Funk")
        XCTAssertEqual(ID3Genre.name(for: "52"), "Electronic")
        XCTAssertEqual(ID3Genre.name(for: "131"), "Indie")
    }

    func testTheID3v2ParenthesisedFormsAreRead() {
        XCTAssertEqual(ID3Genre.name(for: "(17)"), "Rock")
        XCTAssertEqual(ID3Genre.name(for: "(17)Rock"), "Rock")
        XCTAssertEqual(ID3Genre.name(for: "(255)"), "(255)", "unknown code, left alone")
    }

    func testANameIsLeftAlone() {
        XCTAssertEqual(ID3Genre.name(for: "Alternative Rock"), "Alternative Rock")
        XCTAssertEqual(ID3Genre.name(for: "  Jazz "), "  Jazz ", "not a normalizer, just the number map")
    }

    /// An MP4 `gnre` atom read as text: two bytes, big-endian, the ID3v1 index
    /// plus one. Old iTunes rips are full of these and they are real genres,
    /// not junk — 235 of them in one library were Rock.
    func testAnMP4GenreAtomIsDecoded() {
        XCTAssertEqual(ID3Genre.name(for: "\u{0}\u{12}"), "Rock")         // 18 - 1 = 17
        XCTAssertEqual(ID3Genre.name(for: "\u{0}\u{15}"), "Alternative")  // 21 - 1 = 20
        XCTAssertEqual(ID3Genre.name(for: "\u{0}\u{0e}"), "Pop")          // 14 - 1 = 13
        XCTAssertEqual(ID3Genre.name(for: "\u{0}5"), "Electronic")         // 0x35 = 53, - 1 = 52
    }

    func testAnUnknownNumberIsLeftAlone() {
        XCTAssertEqual(ID3Genre.name(for: "999"), "999")
    }
}
#endif
