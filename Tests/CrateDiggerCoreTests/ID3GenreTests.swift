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

    func testAnUnknownNumberIsLeftAlone() {
        XCTAssertEqual(ID3Genre.name(for: "999"), "999")
    }
}
#endif
