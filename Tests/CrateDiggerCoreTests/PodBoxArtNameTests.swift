import XCTest
@testable import CrateDiggerCore

final class PodBoxArtNameTests: XCTestCase {
    /// Names covering every rule; the fixed-point and file-stem properties run over all of them.
    static let corpus: [String] = [
        "N*E*R*D", "N.E.R.D", "NERD", "AC/DC", "AC_DC", "AC-DC", "ACDC",
        "Björk", "Bjo\u{308}rk", "Bjork", "The Beatles", "Beatles", "Beatles, The",
        "Simon & Garfunkel", "The The", "The ", "Herbert, Frank", "Frank Herbert",
        "!!!", "", "&&&", "Ø", "ø", "Œ", "Æ", "ß", "Þ", "Ĳ", "ＡＢＣ", "КИНО", "Кино", "椎名林檎",
        "Sigur Rós", "R.E.M.", "Who's Next?", "Guns N' Roses", "CON", "a, b, c", "Sunn O)))",
        ".hidden", "Dvořák, Antonín", "Mötley Crüe",
    ]

    func testWorkedExamples() {
        for name in ["N*E*R*D", "N.E.R.D", "NERD"] { XCTAssertEqual(PodBoxArtName.folded(name), "nerd", name) }
        for name in ["AC/DC", "AC_DC", "AC-DC", "ACDC"] { XCTAssertEqual(PodBoxArtName.folded(name), "acdc", name) }
        XCTAssertEqual(PodBoxArtName.folded("Björk"), "bjork")
        for name in ["The Beatles", "Beatles", "Beatles, The"] {
            XCTAssertEqual(PodBoxArtName.folded(name), "beatles", name)
        }
        XCTAssertEqual(PodBoxArtName.folded("Simon & Garfunkel"), "simonandgarfunkel")
        XCTAssertEqual(PodBoxArtName.key("AC/DC"), PodBoxArtName.key("ACDC"))
        XCTAssertEqual(PodBoxArtName.key("Beatles, The"), PodBoxArtName.key("The Beatles"))
    }

    func testTheThe() {
        XCTAssertEqual(PodBoxArtName.folded("The The"), "the")
    }

    func testLoneTheIsUntouched() {
        XCTAssertEqual(PodBoxArtName.folded("The "), "the")
        XCTAssertEqual(PodBoxArtName.folded("The"), "the")
        XCTAssertEqual(PodBoxArtName.folded(", the"), "the")
        XCTAssertEqual(PodBoxArtName.folded("x, the"), "x")
        XCTAssertEqual(PodBoxArtName.folded("Theme"), "theme")
    }

    func testAltKeyReversesOneComma() {
        XCTAssertTrue(PodBoxArtName.matches("Herbert, Frank", "Frank Herbert"))
        XCTAssertTrue(PodBoxArtName.matches("Frank Herbert", "Herbert, Frank"))
        XCTAssertEqual(PodBoxArtName.altKey("Herbert, Frank"), PodBoxArtName.key("Frank Herbert"))
        XCTAssertFalse(PodBoxArtName.matches("Herbert, Frank", "Frank Zappa"))
    }

    func testAltKeyZeroWithoutExactlyOneComma() {
        XCTAssertEqual(PodBoxArtName.altKey("Frank Herbert"), 0)
        XCTAssertEqual(PodBoxArtName.altKey("a, b, c"), 0)
        XCTAssertEqual(PodBoxArtName.altKey(""), 0)
    }

    func testFullwidthFolds() {
        XCTAssertEqual(PodBoxArtName.folded("ＡＢＣ"), "abc")
        XCTAssertEqual(PodBoxArtName.key("ＡＢＣ"), PodBoxArtName.key("abc"))
    }

    func testCombiningMarksDropped() {
        let nfd = "Bjo\u{308}rk"
        XCTAssertEqual(PodBoxArtName.key(nfd), PodBoxArtName.key("Björk"))
        XCTAssertEqual(PodBoxArtName.folded(nfd), "bjork")
    }

    func testLatinPairs() {
        XCTAssertEqual(PodBoxArtName.folded("Æ"), "ae")
        XCTAssertEqual(PodBoxArtName.folded("ß"), "ss")
        XCTAssertEqual(PodBoxArtName.folded("Þ"), "th")
        XCTAssertEqual(PodBoxArtName.folded("Œ"), "oe")
        XCTAssertEqual(PodBoxArtName.folded("Ĳ"), "ij")
        XCTAssertEqual(PodBoxArtName.folded("×÷"), "", "the table's two drops")
    }

    /// PodBox's C (compiled by scripts/podbox-artname-vectors.sh) gives Ø and
    /// ø the key of plain "o": the table wins over the brief's prose ("oe").
    func testOSlashFollowsTheTable() {
        XCTAssertEqual(PodBoxArtName.folded("Ø"), "o")
        XCTAssertEqual(PodBoxArtName.folded("ø"), "o")
        XCTAssertEqual(PodBoxArtName.key("Ø"), PodBoxArtName.key("o"))
    }

    /// Review Focus 1: other scripts are hashed as they are, never lowercased.
    func testNonLatinNamesKeepTheirCodePoints() {
        XCTAssertNotEqual(PodBoxArtName.key("КИНО"), PodBoxArtName.key("Кино"))
        XCTAssertNotEqual(PodBoxArtName.key("КИНО"), 0)
        XCTAssertNotEqual(PodBoxArtName.key("Кино"), 0)
        XCTAssertEqual(PodBoxArtName.folded("椎名林檎"), "椎名林檎")
        XCTAssertEqual(PodBoxArtName.folded("Sigur Rós"), "sigurros")
    }

    /// Review Focus 1: a name with nothing the player keeps has key 0.
    func testZeroKeyNames() {
        XCTAssertEqual(PodBoxArtName.key("!!!"), 0)
        XCTAssertEqual(PodBoxArtName.key(""), 0)
        XCTAssertEqual(PodBoxArtName.key("  ...  "), 0)
        XCTAssertNotEqual(PodBoxArtName.key("&&&"), 0)
        XCTAssertEqual(PodBoxArtName.folded("&&&"), "andandand")
        XCTAssertNil(PodBoxArtName.fileStem(for: "!!!"))
        XCTAssertFalse(PodBoxArtName.matches("!!!", "???"), "two unkeyable names never match")
    }

    func testFinishMapsZeroHashToOne() {
        XCTAssertEqual(PodBoxArtName.finish(hash: 0, kept: true), 1)
        XCTAssertEqual(PodBoxArtName.finish(hash: 0, kept: false), 0)
        XCTAssertEqual(PodBoxArtName.finish(hash: 12345, kept: false), 0)
        XCTAssertEqual(PodBoxArtName.finish(hash: 12345, kept: true), 12345)
    }

    func testKeyOfFNV() {
        let expected: UInt32 = (0x811C9DC5 ^ 0x5A5A5A5A ^ 0x61) &* 16_777_619
        XCTAssertEqual(PodBoxArtName.key("a"), expected)
        XCTAssertEqual(PodBoxArtName.key("A"), expected)
    }

    func testFoldedIsAFixedPoint() {
        for name in Self.corpus {
            let once = PodBoxArtName.folded(name)
            XCTAssertEqual(PodBoxArtName.folded(once), once, name)
            XCTAssertEqual(PodBoxArtName.key(once), PodBoxArtName.key(name), name)
        }
    }

    func testFileStemKeepsTheKey() throws {
        for name in Self.corpus where PodBoxArtName.key(name) != 0 {
            let stem = try XCTUnwrap(PodBoxArtName.fileStem(for: name), name)
            XCTAssertEqual(PodBoxArtName.key(stem), PodBoxArtName.key(name), name)
            XCTAssertEqual(FATName.component(stem, extension: "jpg"), stem + ".jpg", "already FAT-safe: \(name)")
        }
        XCTAssertEqual(PodBoxArtName.fileStem(for: "AC/DC"), "AC-DC")
        XCTAssertEqual(PodBoxArtName.fileStem(for: "Björk"), "Björk")
        XCTAssertEqual(PodBoxArtName.fileStem(for: "Herbert, Frank"), "Herbert, Frank")
        XCTAssertEqual(PodBoxArtName.fileStem(for: "R.E.M."), "R.E.M")
    }

    func testFileStemFallsBackToFold() throws {
        // 400 characters: the FAT form is cut, which loses letters and so the key.
        let name = String(repeating: "Ab. ", count: 100)
        XCTAssertEqual(name.count, 400)
        let stem = try XCTUnwrap(PodBoxArtName.fileStem(for: name))
        XCTAssertEqual(stem, PodBoxArtName.folded(name))
        XCTAssertEqual(stem.count, 200)
        XCTAssertEqual(PodBoxArtName.key(stem), PodBoxArtName.key(name))

        // A FAT form that only loses punctuation keeps the key, so it is used as it is.
        XCTAssertEqual(PodBoxArtName.fileStem(for: "Who's Next?"), "Who's Next")

        // Even the fold too long for one name: nothing usable.
        XCTAssertNil(PodBoxArtName.fileStem(for: String(repeating: "x", count: 300)))
    }

    func testVectorsFromPodBoxSource() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/podbox-artname-vectors.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("No vectors: run scripts/podbox-artname-vectors.sh to make them.")
        }
        struct Vector: Decodable { let name: String; let key: UInt32; let altKey: UInt32 }
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(vectors.count, 250)
        for vector in vectors {
            XCTAssertEqual(PodBoxArtName.key(vector.name), vector.key, "key of \(vector.name.debugDescription)")
            XCTAssertEqual(PodBoxArtName.altKey(vector.name), vector.altKey, "altKey of \(vector.name.debugDescription)")
        }
    }
}
