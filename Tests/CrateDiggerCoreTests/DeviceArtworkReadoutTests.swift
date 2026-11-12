#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

/// The DEVICES screen's Artwork cell says what a transfer does with the art:
/// what goes inside the files and, when folder art is on, the cover.jpg
/// beside them. Both at once must read as both.
final class DeviceArtworkReadoutTests: XCTestCase {

    func testStripWithFolderArtReadsTheCoverSize() {
        let cell = DeviceArtworkReadout.cell(mode: .none, maxDimension: 600, folderArt: true)
        XCTAssertEqual(cell.value, "400 px")
        XCTAssertEqual(cell.sub, "cover.jpg")
    }

    func testKeepReadsEmbedded() {
        let cell = DeviceArtworkReadout.cell(mode: .preserve, maxDimension: nil, folderArt: false)
        XCTAssertEqual(cell.value, "KEEP")
        XCTAssertEqual(cell.sub, "Embedded")
    }

    func testReembedReadsTheCap() {
        let cell = DeviceArtworkReadout.cell(mode: .compatReembed, maxDimension: 600, folderArt: false)
        XCTAssertEqual(cell.value, "600 px")
        XCTAssertEqual(cell.sub, "Embedded")
    }

    func testKeepWithFolderArtSaysBoth() {
        let cell = DeviceArtworkReadout.cell(mode: .preserve, maxDimension: nil, folderArt: true)
        XCTAssertEqual(cell.value, "KEEP")
        XCTAssertEqual(cell.sub, "+ cover.jpg")
    }

    func testReembedWithFolderArtSaysBoth() {
        let cell = DeviceArtworkReadout.cell(mode: .compatReembed, maxDimension: 600, folderArt: true)
        XCTAssertEqual(cell.value, "600 px")
        XCTAssertEqual(cell.sub, "+ cover.jpg")
    }

    func testStripWithoutFolderArtReadsNone() {
        let cell = DeviceArtworkReadout.cell(mode: .none, maxDimension: 600, folderArt: false)
        XCTAssertEqual(cell.value, "NONE")
        XCTAssertEqual(cell.sub, "Stripped")
    }

    /// Re-embed with no cap re-encodes at the art's own size: no number to show.
    func testUncappedReembedNamesTheMode() {
        XCTAssertEqual(DeviceArtworkReadout.cell(mode: .compatReembed, maxDimension: nil, folderArt: false).value, "RE-EMBED")
        XCTAssertEqual(DeviceArtworkReadout.cell(mode: .compatReembed, maxDimension: nil, folderArt: true).sub, "+ cover.jpg")
    }

    /// Keep ignores the cap: the art is copied as it is.
    func testKeepIgnoresTheCap() {
        XCTAssertEqual(DeviceArtworkReadout.cell(mode: .preserve, maxDimension: 600, folderArt: false).value, "KEEP")
    }
}
#endif
