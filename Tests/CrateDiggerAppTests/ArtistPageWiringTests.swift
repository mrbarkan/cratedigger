#if canImport(XCTest)
import CrateDiggerCore
import XCTest
@testable import CrateDiggerApp

/// The view model's half of "when INFO shows the artist page" (spec §1):
/// the focused column decides, "Show Artist" overrides it until the owner
/// clicks a row or moves between columns.
final class ArtistPageWiringTests: XCTestCase {
    private func track(_ path: String, artist: String, album: String) -> LoadedTrack {
        LoadedTrack(track: AudioTrack(fileURL: URL(fileURLWithPath: path), title: "T", artist: artist, album: album),
                    metadata: ConversionMetadata(title: "T", artist: artist, album: album))
    }

    private lazy var library = LibraryIndex.build(from: [
        track("/m/Air/Moon Safari/1.flac", artist: "Air", album: "Moon Safari"),
        track("/m/Portishead/Dummy/1.flac", artist: "Portishead", album: "Dummy"),
    ])

    func testFocusOnArtistColumnSetsInspectedArtist() throws {
        var browser = BrowserState()
        browser.view = .classic
        browser.selectedArtistID = try XCTUnwrap(library.artists.first { $0.name == "Portishead" }).id
        browser.focusedColumn = 0
        let page = ArtistPageSelection()
        XCTAssertEqual(page.artistName(browser: browser, index: library, gallery: false), "Portishead")

        browser.focusedColumn = 1
        XCTAssertNil(page.artistName(browser: browser, index: library, gallery: false),
                     "the album column brings the album page back")
        browser.focusedColumn = 0
        XCTAssertNil(page.artistName(browser: browser, index: library, gallery: true),
                     "the gallery has no artist column to focus")
    }

    func testShowArtistThenFocusAlbumClearsIt() {
        var browser = BrowserState()
        browser.view = BrowserView([.album, .track])
        browser.focusedColumn = 1
        var page = ArtistPageSelection()
        XCTAssertNil(page.artistName(browser: browser, index: library, gallery: false))

        page.show("Air")
        XCTAssertEqual(page.artistName(browser: browser, index: library, gallery: false), "Air",
                       "Show Artist reaches the page in a view with no artist column")
        XCTAssertEqual(page.artistName(browser: browser, index: library, gallery: true), "Air")

        page.focusMoved()
        browser.focusedColumn = 0
        XCTAssertNil(page.artistName(browser: browser, index: library, gallery: false))
    }

    func testAChosenRowClearsShowArtistToo() {
        var page = ArtistPageSelection()
        page.show("Air")
        page.selectionChanged()
        XCTAssertNil(page.explicitArtist)
        page.show("   ")
        XCTAssertNil(page.explicitArtist, "a blank name shows nobody")
    }
}
#endif
