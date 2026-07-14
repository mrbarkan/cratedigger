#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class AlbumArtCatalogTests: XCTestCase {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/album/\(name)") }

    func testOrderingCoverBookletInlayTrayDiscBack() {
        let urls = [
            url("back.jpg"), url("disc.png"), url("inlay.jpg"),
            url("cover.jpg"), url("booklet_02.jpg"), url("booklet_01.jpg")
        ]
        let pages = AlbumArtCatalog.pages(imageURLs: urls, manifest: nil)
        XCTAssertEqual(pages.map(\.kind), [.cover, .bookletPage, .bookletPage, .inlay, .tray, .disc, .back])
        // Booklet pages are natural-sorted by filename.
        XCTAssertEqual(pages.filter { $0.kind == .bookletPage }.map { $0.imageURL?.lastPathComponent },
                       ["booklet_01.jpg", "booklet_02.jpg"])
    }

    func testTrayComposedOnlyWhenInlayAndDiscBothPresent() {
        let discOnly = AlbumArtCatalog.pages(imageURLs: [url("cover.jpg"), url("cd.png")], manifest: nil)
        XCTAssertFalse(discOnly.contains { $0.kind == .tray })

        let both = AlbumArtCatalog.pages(imageURLs: [url("insert.jpg"), url("cd.png")], manifest: nil)
        let tray = both.first { $0.kind == .tray }
        XCTAssertNotNil(tray)
        XCTAssertEqual(tray?.imageURL?.lastPathComponent, "insert.jpg") // inlay is the background
        XCTAssertEqual(tray?.overlayURL?.lastPathComponent, "cd.png")   // disc composited on top
    }

    func testManifestRoleOverridesFilename() {
        // A file named "cover.jpg" tagged as the inlay must be filed as inlay.
        let manifest = ArtworkManifest(roles: ["cover.jpg": .inlay, "art.png": .disc])
        let pages = AlbumArtCatalog.pages(imageURLs: [url("cover.jpg"), url("art.png")], manifest: manifest)
        XCTAssertEqual(pages.first { $0.imageURL?.lastPathComponent == "cover.jpg" }?.kind, .inlay)
        XCTAssertTrue(pages.contains { $0.kind == .tray }) // inlay + disc → tray
    }

    func testMainCoverPrecedesAltCover() {
        // "cover_alt.jpg" filename-sorts BEFORE "cover.jpg" (underscore vs dot),
        // so the alt must be bucketed separately or it becomes the first cover page.
        let manifest = ArtworkManifest(roles: ["cover.jpg": .cover, "cover_alt.jpg": .altCover])
        let pages = AlbumArtCatalog.pages(imageURLs: [url("cover_alt.jpg"), url("cover.jpg")], manifest: manifest)
        XCTAssertEqual(pages.map { $0.imageURL?.lastPathComponent }, ["cover.jpg", "cover_alt.jpg"])
        XCTAssertEqual(pages.map(\.kind), [.cover, .cover])
    }

    func testDiscSideLabelFromManifest() {
        let manifest = ArtworkManifest(roles: ["side.png": .disc], discSides: ["side.png": "A"])
        let pages = AlbumArtCatalog.pages(imageURLs: [url("side.png")], manifest: manifest)
        XCTAssertEqual(pages.first { $0.kind == .disc }?.label, "Disc (A)")
    }

    func testInlayDetectedByFilenameKeywords() {
        for name in ["tray.jpg", "inside.png", "inlet.jpg", "insert.jpeg"] {
            let pages = AlbumArtCatalog.pages(imageURLs: [url(name)], manifest: nil)
            XCTAssertEqual(pages.first?.kind, .inlay, "\(name) should classify as inlay")
        }
    }
}
#endif
