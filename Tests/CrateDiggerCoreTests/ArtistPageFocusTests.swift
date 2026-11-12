import XCTest
@testable import CrateDiggerCore

/// When INFO shows the artist page, and for whom (spec §1).
final class ArtistPageFocusTests: XCTestCase {
    private func track(_ path: String, artist: String, albumArtist: String? = nil, album: String) -> LoadedTrack {
        LoadedTrack(track: AudioTrack(fileURL: URL(fileURLWithPath: path), title: "T", artist: artist, album: album),
                    metadata: ConversionMetadata(title: "T", artist: artist, albumArtist: albumArtist, album: album))
    }

    private lazy var library = LibraryIndex.build(from: [
        track("/m/Air/Moon Safari/1.flac", artist: "Air", album: "Moon Safari"),
        track("/m/MA/Mezzanine/1.flac", artist: "Massive Attack feat. Liz Fraser", albumArtist: "Massive Attack",
              album: "Mezzanine"),
    ])

    private func state(_ view: BrowserView, focused: Int) -> BrowserState {
        var state = BrowserState()
        state.view = view
        state.focusedColumn = focused
        return state
    }

    func testArtistColumnFocusShowsArtist() throws {
        XCTAssertTrue(ArtistPageFocus.showsArtist(view: .classic, focusedColumn: 0, explicitArtist: nil))
        var browser = state(.classic, focused: 0)
        let air = try XCTUnwrap(library.artists.first { $0.name == "Air" })
        browser.selectedArtistID = air.id
        XCTAssertEqual(ArtistPageFocus.artistName(view: browser.view, state: browser, index: library,
                                                  explicitArtist: nil), "Air")
        // Nothing picked in the artist column yet: no artist to show.
        let empty = state(.classic, focused: 0)
        XCTAssertNil(ArtistPageFocus.artistName(view: empty.view, state: empty, index: library, explicitArtist: nil))
    }

    func testAlbumArtistColumnFocusShowsArtist() {
        let view = BrowserView([.albumArtist, .album, .track])
        XCTAssertTrue(ArtistPageFocus.showsArtist(view: view, focusedColumn: 0, explicitArtist: nil))
        var browser = state(view, focused: 0)
        let key = BrowserFacet.albumArtist.key(of: library.allTracks.first { $0.track.album == "Mezzanine" }!,
                                               context: FacetContext(index: library))
        browser.select(column: 0, id: key, command: false, shift: false, ordered: [key])
        XCTAssertEqual(ArtistPageFocus.artistName(view: view, state: browser, index: library, explicitArtist: nil),
                       "Massive Attack")
    }

    func testAlbumColumnFocusShowsAlbum() throws {
        XCTAssertFalse(ArtistPageFocus.showsArtist(view: .classic, focusedColumn: 1, explicitArtist: nil))
        XCTAssertFalse(ArtistPageFocus.showsArtist(view: .classic, focusedColumn: 2, explicitArtist: nil))
        // Clicking an artist fills the album anchor too: focus, not the anchors, decides.
        var browser = state(.classic, focused: 1)
        browser.selectedArtistID = try XCTUnwrap(library.artists.first).id
        XCTAssertNil(ArtistPageFocus.artistName(view: browser.view, state: browser, index: library,
                                                explicitArtist: nil))
        // A focus left past the end of a narrower view reads as its last column.
        XCTAssertFalse(ArtistPageFocus.showsArtist(view: BrowserView([.album, .track]), focusedColumn: 2,
                                                   explicitArtist: nil))
        XCTAssertTrue(ArtistPageFocus.showsArtist(view: BrowserView([.artist]), focusedColumn: 2, explicitArtist: nil))
    }

    func testExplicitArtistInViewWithoutArtistColumn() {
        let view = BrowserView([.genre, .track])
        XCTAssertFalse(ArtistPageFocus.showsArtist(view: view, focusedColumn: 1, explicitArtist: nil))
        XCTAssertTrue(ArtistPageFocus.showsArtist(view: view, focusedColumn: 1, explicitArtist: "Air"))
        let browser = state(view, focused: 1)
        XCTAssertEqual(ArtistPageFocus.artistName(view: view, state: browser, index: library, explicitArtist: "Air"),
                       "Air")
        // "Show Artist" wins over an artist column's own anchor until focus moves.
        var classic = state(.classic, focused: 0)
        classic.selectedArtistID = library.artists.first { $0.name == "Air" }?.id
        XCTAssertEqual(ArtistPageFocus.artistName(view: .classic, state: classic, index: library,
                                                  explicitArtist: "Massive Attack"), "Massive Attack")
        // An empty explicit name is no artist.
        XCTAssertFalse(ArtistPageFocus.showsArtist(view: view, focusedColumn: 1, explicitArtist: ""))
    }
}
