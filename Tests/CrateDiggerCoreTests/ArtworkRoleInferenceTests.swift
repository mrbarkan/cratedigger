#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// Importing a folder of scans is only useful if the files land under sensible
/// roles — otherwise every page becomes "cover" and the last one wins.
final class ArtworkRoleInferenceTests: XCTestCase {

    func testRecognisesTheCommonScanVocabulary() {
        let cases: [(String, ArtworkRole)] = [
            ("front.jpg", .cover),
            ("Front Cover.png", .cover),
            ("cover.jpeg", .cover),
            ("folder.jpg", .cover),
            ("back.jpg", .back),
            ("Rear.tif", .back),
            ("spine.png", .spine),
            ("inlay.jpg", .inlay),
            ("tray card.jpg", .inlay),
            ("disc.png", .disc),
            ("CD1.jpg", .disc),
            ("vinyl label.jpg", .disc),
            ("booklet_03.tif", .bookletPage),
            ("liner notes 2.jpg", .bookletPage),
            ("obi.jpg", .obi),
            ("matrix.jpg", .matrixRunout),
            ("runout side a.jpg", .matrixRunout),
            ("hype sticker.png", .sticker),
            ("poster.jpg", .poster),
            ("inner sleeve.jpg", .sleeve),
            ("shrink wrapped.jpg", .wrapped)
        ]
        for (filename, expected) in cases {
            XCTAssertEqual(ArtworkRole.inferred(fromFilename: filename), expected,
                           "wrong role for \(filename)")
        }
    }

    /// "back cover" is a back, not a cover — the more specific word has to win
    /// or half a scanned album files itself as the front.
    func testMoreSpecificKeywordsBeatCover() {
        XCTAssertEqual(ArtworkRole.inferred(fromFilename: "back cover.jpg"), .back)
        XCTAssertEqual(ArtworkRole.inferred(fromFilename: "cover_back.png"), .back)
        XCTAssertEqual(ArtworkRole.inferred(fromFilename: "cd label.jpg"), .disc)
        XCTAssertEqual(ArtworkRole.inferred(fromFilename: "booklet cover.jpg"), .bookletPage)
    }

    func testUnlabelledNamesReturnNilSoTheCallerDecides() {
        for filename in ["IMG_4821.jpg", "scan001.png", "untitled.tif", "0001.jpeg", ".jpg"] {
            XCTAssertNil(ArtworkRole.inferred(fromFilename: filename),
                         "\(filename) carries no role signal and should not be guessed")
        }
    }

    func testIsCaseAndExtensionInsensitive() {
        for filename in ["BACK.JPG", "Back.png", "bAcK.tiff", "back"] {
            XCTAssertEqual(ArtworkRole.inferred(fromFilename: filename), .back)
        }
    }

    /// Every role it can return must be one the user could also have picked
    /// manually, so an inferred role is editable afterwards.
    func testInferredRolesAreAllAssignable() {
        let names = ["front.jpg", "back.jpg", "cd1.png", "booklet_1.jpg", "obi.jpg",
                     "matrix.jpg", "spine.jpg", "inlay.jpg", "poster.jpg",
                     "inner sleeve.jpg", "sticker.jpg", "shrink.jpg"]
        for name in names {
            guard let role = ArtworkRole.inferred(fromFilename: name) else { continue }
            XCTAssertTrue(ArtworkRole.assignable.contains(role),
                          "\(role) inferred from \(name) is not user-assignable")
        }
    }
}
#endif
