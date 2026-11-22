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

    private func columns(_ browser: BrowserState) -> [ColumnContent] {
        BrowserCascade.columns(view: browser.view, in: library, selection: browser.selection, sorts: browser.sorts,
                               context: FacetContext(index: library))
    }

    func testArtistColumnFocusShowsArtist() throws {
        XCTAssertTrue(ArtistPageFocus.showsArtist(view: .classic, focusedColumn: 0, explicitArtist: nil))
        var browser = state(.classic, focused: 0)
        let air = try XCTUnwrap(library.artists.first { $0.name == "Air" })
        browser.selectedArtistID = air.id
        XCTAssertEqual(ArtistPageFocus.artistName(view: browser.view, state: browser, columns: columns(browser),
                                                  explicitArtist: nil), "Air")
        // Nothing picked in the artist column yet: no artist to show.
        let empty = state(.classic, focused: 0)
        XCTAssertNil(ArtistPageFocus.artistName(view: empty.view, state: empty, columns: columns(empty), explicitArtist: nil))
    }

    func testAlbumArtistColumnFocusShowsArtist() {
        let view = BrowserView([.albumArtist, .album, .track])
        XCTAssertTrue(ArtistPageFocus.showsArtist(view: view, focusedColumn: 0, explicitArtist: nil))
        var browser = state(view, focused: 0)
        let key = BrowserFacet.albumArtist.key(of: library.allTracks.first { $0.track.album == "Mezzanine" }!,
                                               context: FacetContext(index: library))
        browser.select(column: 0, id: key, command: false, shift: false, ordered: [key])
        XCTAssertEqual(ArtistPageFocus.artistName(view: view, state: browser, columns: columns(browser), explicitArtist: nil),
                       "Massive Attack")
    }

    /// A compilation's track artist with no album-artist tag has a row in
    /// the Album Artist column but no artist bucket in the index: the name
    /// comes from the row itself.
    func testAlbumArtistRowWithNoBucketUsesTheRowsName() {
        let compilation = LibraryIndex.build(from: [
            track("/m/VA/Comp/1.flac", artist: "Horace Andy", album: "Comp"),
            track("/m/VA/Comp/2.flac", artist: "Tricky", album: "Comp"),
        ])
        let view = BrowserView([.albumArtist, .album, .track])
        let context = FacetContext(index: compilation)
        var browser = state(view, focused: 0)
        let tricky = compilation.allTracks.first { $0.track.artist == "Tricky" }!
        let key = BrowserFacet.albumArtist.key(of: tricky, context: context)
        browser.select(column: 0, id: key, command: false, shift: false, ordered: [key])
        let drawn = BrowserCascade.columns(view: view, in: compilation, selection: browser.selection,
                                           sorts: browser.sorts, context: context)
        XCTAssertEqual(ArtistPageFocus.artistName(view: view, state: browser, columns: drawn, explicitArtist: nil),
                       "Tricky")
        XCTAssertNil(ArtistPageFocus.artistName(view: view, state: browser, columns: [], explicitArtist: nil),
                     "no column drawn yet: nobody")
    }

    func testAlbumColumnFocusShowsAlbum() throws {
        XCTAssertFalse(ArtistPageFocus.showsArtist(view: .classic, focusedColumn: 1, explicitArtist: nil))
        XCTAssertFalse(ArtistPageFocus.showsArtist(view: .classic, focusedColumn: 2, explicitArtist: nil))
        // Clicking an artist fills the album anchor too: focus, not the anchors, decides.
        var browser = state(.classic, focused: 1)
        browser.selectedArtistID = try XCTUnwrap(library.artists.first).id
        XCTAssertNil(ArtistPageFocus.artistName(view: browser.view, state: browser, columns: columns(browser),
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
        XCTAssertEqual(ArtistPageFocus.artistName(view: view, state: browser, columns: columns(browser), explicitArtist: "Air"),
                       "Air")
        // "Show Artist" wins over an artist column's own anchor until focus moves.
        var classic = state(.classic, focused: 0)
        classic.selectedArtistID = library.artists.first { $0.name == "Air" }?.id
        XCTAssertEqual(ArtistPageFocus.artistName(view: .classic, state: classic, columns: columns(classic),
                                                  explicitArtist: "Massive Attack"), "Massive Attack")
        // An empty explicit name is no artist.
        XCTAssertFalse(ArtistPageFocus.showsArtist(view: view, focusedColumn: 1, explicitArtist: ""))
    }
}
