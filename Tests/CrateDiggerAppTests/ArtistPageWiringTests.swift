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

    private func columns(_ browser: BrowserState, in index: LibraryIndex? = nil) -> [ColumnContent] {
        let index = index ?? library
        return BrowserCascade.columns(view: browser.view, in: index, selection: browser.selection,
                                      sorts: browser.sorts, context: FacetContext(index: index))
    }

    /// One browser change as the view model's `browser` didSet sees it.
    private func change(_ page: inout ArtistPageSelection, _ browser: inout BrowserState, gallery: Bool = false,
                        _ edit: (inout BrowserState) -> Void) {
        let old = browser
        edit(&browser)
        page.browserChanged(from: old, to: browser, columns: columns(browser), gallery: gallery)
    }

    func testFocusOnArtistColumnSetsInspectedArtist() throws {
        var browser = BrowserState()
        browser.view = .classic
        var page = ArtistPageSelection()
        let portishead = try XCTUnwrap(library.artists.first { $0.name == "Portishead" })
        change(&page, &browser) {
            $0.selectArtist(portishead, command: false, shift: false, ordered: self.library.artists)
            $0.focusedColumn = 0
        }
        XCTAssertEqual(page.artistName, "Portishead")

        // The `focusedColumn` setter: focus moves, then the browser changes.
        page.focusMoved()
        change(&page, &browser) { $0.focusedColumn = 1 }
        XCTAssertNil(page.artistName, "the album column brings the album page back")

        page.focusMoved()
        change(&page, &browser) { $0.focusedColumn = 0 }
        XCTAssertEqual(page.artistName, "Portishead")
        page.resolve(browser: browser, columns: columns(browser), gallery: true)
        XCTAssertNil(page.artistName, "the gallery has no artist column to focus")
    }

    func testShowArtistThenFocusAlbumClearsIt() {
        var browser = BrowserState()
        browser.view = BrowserView([.album, .track])
        var page = ArtistPageSelection()
        change(&page, &browser) { $0.focusedColumn = 1 }
        XCTAssertNil(page.artistName)

        page.show("Air")
        page.resolve(browser: browser, columns: columns(browser), gallery: false)
        XCTAssertEqual(page.artistName, "Air", "Show Artist reaches the page in a view with no artist column")
        page.resolve(browser: browser, columns: columns(browser), gallery: true)
        XCTAssertEqual(page.artistName, "Air")

        page.focusMoved()
        change(&page, &browser) { $0.focusedColumn = 0 }
        XCTAssertNil(page.artistName)
    }

    func testAChosenRowClearsShowArtistToo() throws {
        var browser = BrowserState()
        browser.view = .classic
        var page = ArtistPageSelection()
        page.show("Air")
        let dummy = try XCTUnwrap(library.allAlbums.first { $0.title == "Dummy" })
        // An arrow key in the album column: the selection moves, focus does not.
        change(&page, &browser) {
            $0.selectAlbum(dummy, command: false, shift: false, ordered: self.library.allAlbums, flat: false)
        }
        XCTAssertNil(page.explicitArtist)
        page.show("   ")
        XCTAssertNil(page.explicitArtist, "a blank name shows nobody")
    }

    /// The gallery's album click: `selectAlbum` ends "Show Artist" first,
    /// even when the album clicked is the one already selected.
    func testAGalleryClickOnTheSelectedAlbumEndsShowArtist() throws {
        var browser = BrowserState()
        browser.view = .classic
        var page = ArtistPageSelection()
        let dummy = try XCTUnwrap(library.allAlbums.first { $0.title == "Dummy" })
        change(&page, &browser, gallery: true) {
            $0.selectAlbum(dummy, command: false, shift: false, ordered: self.library.allAlbums, flat: true)
        }
        page.show("Air")
        page.resolve(browser: browser, columns: columns(browser), gallery: true)
        XCTAssertEqual(page.artistName, "Air")

        page.selectionChanged()
        change(&page, &browser, gallery: true) {
            $0.selectAlbum(dummy, command: false, shift: false, ordered: self.library.allAlbums, flat: true)
        }
        XCTAssertNil(page.artistName, "the album page comes back")
    }

    func testCompilationArtistNameComesFromItsRow() {
        let compilation = LibraryIndex.build(from: [
            track("/m/VA/Comp/1.flac", artist: "Horace Andy", album: "Comp"),
            track("/m/VA/Comp/2.flac", artist: "Tricky", album: "Comp"),
        ])
        var browser = BrowserState()
        browser.view = BrowserView([.albumArtist, .album, .track])
        let tricky = compilation.allTracks.first { $0.track.artist == "Tricky" }!
        let key = BrowserFacet.albumArtist.key(of: tricky, context: FacetContext(index: compilation))
        let old = browser
        browser.select(column: 0, id: key, command: false, shift: false, ordered: [key])
        browser.focusedColumn = 0
        var page = ArtistPageSelection()
        page.browserChanged(from: old, to: browser, columns: columns(browser, in: compilation), gallery: false)
        XCTAssertEqual(page.artistName, "Tricky")
    }
}
#endif
