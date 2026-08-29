#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// Selection has been the most-touched state in the app and the least tested.
/// These are its first tests.
final class BrowserStateTests: XCTestCase {

    private func track(_ name: String) -> LoadedTrack {
        let url = URL(fileURLWithPath: "/Music/Album/\(name).flac")
        return LoadedTrack(
            track: AudioTrack(fileURL: url, title: name, artist: "A", album: "Album"),
            metadata: ConversionMetadata()
        )
    }

    /// `Album` has no defaults for year/artworkHash, so they are spelled out.
    private func album(_ id: String, tracks: [LoadedTrack] = []) -> Album {
        Album(
            id: id,
            artistID: "artist",
            artistName: "A",
            title: id,
            year: nil,
            artworkHash: nil,
            tracks: tracks
        )
    }

    private func artist(_ id: String, albums: [Album] = []) -> Artist {
        Artist(id: id, name: id, albums: albums)
    }

    // MARK: - Mutual exclusivity

    func testPickingAnAlbumClearsArtistAndTrackSelections() {
        var state = BrowserState()
        let albums = [album("a1"), album("a2")]
        state.selectArtist(artist("ar1"), command: false, shift: false, ordered: [artist("ar1")])
        XCTAssertFalse(state.selectedArtistIDs.isEmpty)

        state.selectAlbum(albums[0], command: false, shift: false, ordered: albums, flat: false)

        XCTAssertTrue(state.selectedArtistIDs.isEmpty, "you pick artists or records, never both")
        XCTAssertTrue(state.selectedTrackIDs.isEmpty)
        XCTAssertEqual(state.selectedAlbumIDs, ["a1"])
    }

    func testPickingATrackClearsArtistAndAlbumSelections() {
        var state = BrowserState()
        let albums = [album("a1")]
        state.selectAlbum(albums[0], command: false, shift: false, ordered: albums, flat: false)

        let tracks = [track("one"), track("two")]
        state.selectTrack(tracks[0], command: false, shift: false, ordered: tracks)

        XCTAssertTrue(state.selectedAlbumIDs.isEmpty)
        XCTAssertTrue(state.selectedArtistIDs.isEmpty)
        XCTAssertEqual(state.selectedTrackIDs, [tracks[0].track.id])
    }

    // MARK: - Modifiers

    func testCommandClickTogglesOneItemWithoutClearingTheRest() {
        var state = BrowserState()
        let albums = [album("a1"), album("a2"), album("a3")]
        state.selectAlbum(albums[0], command: false, shift: false, ordered: albums, flat: false)
        state.selectAlbum(albums[2], command: true, shift: false, ordered: albums, flat: false)
        XCTAssertEqual(state.selectedAlbumIDs, ["a1", "a3"])

        state.selectAlbum(albums[2], command: true, shift: false, ordered: albums, flat: false)
        XCTAssertEqual(state.selectedAlbumIDs, ["a1"], "command-clicking a picked item unpicks it")
    }

    func testShiftClickSelectsTheRangeFromTheAnchor() {
        var state = BrowserState()
        let albums = [album("a1"), album("a2"), album("a3"), album("a4")]
        state.selectAlbum(albums[0], command: false, shift: false, ordered: albums, flat: false)
        state.selectAlbum(albums[2], command: false, shift: true, ordered: albums, flat: false)
        XCTAssertEqual(state.selectedAlbumIDs, ["a1", "a2", "a3"])
    }

    func testShiftRangeWorksBackwards() {
        var state = BrowserState()
        let albums = [album("a1"), album("a2"), album("a3"), album("a4")]
        state.selectAlbum(albums[3], command: false, shift: false, ordered: albums, flat: false)
        state.selectAlbum(albums[1], command: false, shift: true, ordered: albums, flat: false)
        XCTAssertEqual(state.selectedAlbumIDs, ["a2", "a3", "a4"])
    }

    // MARK: - Anchors and drill-down

    func testSelectingAnArtistDrillsIntoItsFirstAlbumAndTrack() {
        var state = BrowserState()
        let inner = track("first")
        let a = artist("ar1", albums: [album("a1", tracks: [inner])])
        state.selectArtist(a, command: false, shift: false, ordered: [a])
        XCTAssertEqual(state.selectedArtistID, "ar1")
        XCTAssertEqual(state.selectedAlbumID, "a1")
        XCTAssertEqual(state.selectedTrackID, inner.track.id)
    }

    func testFlatAlbumSelectionAlsoSetsTheArtistAnchor() {
        var state = BrowserState()
        let al = album("a1")
        state.selectAlbum(al, command: false, shift: false, ordered: [al], flat: true)
        XCTAssertEqual(state.selectedArtistID, al.artistID)
    }

    func testIsSelectedCountsBothTheAnchorAndTheSet() {
        var state = BrowserState()
        state.selectedAlbumID = "anchor"
        XCTAssertTrue(state.isAlbumSelected("anchor"))
        state.selectedAlbumIDs = ["other"]
        XCTAssertTrue(state.isAlbumSelected("other"))
    }

    func testClearMultiSelectionLeavesTheAnchorsAlone() {
        var state = BrowserState()
        let albums = [album("a1"), album("a2")]
        state.selectAlbum(albums[0], command: false, shift: false, ordered: albums, flat: false)
        state.clearMultiSelection()
        XCTAssertTrue(state.selectedAlbumIDs.isEmpty)
        XCTAssertEqual(state.selectedAlbumID, "a1", "the browser still has to show something")
    }

    // MARK: - Sort

    func testSortDefaultsMatchWhatTheBrowserHasAlwaysShown() {
        let state = BrowserState()
        XCTAssertEqual(state.trackSort.field, .trackNumber)
        XCTAssertTrue(state.trackSort.ascending)
        XCTAssertEqual(state.albumSort.field, .year)
        XCTAssertEqual(state.artistSort.field, .name)
    }

    func testChangingSortLeavesSelectionUntouched() {
        var state = BrowserState()
        let albums = [album("a1")]
        state.selectAlbum(albums[0], command: false, shift: false, ordered: albums, flat: false)
        let before = state.selectedAlbumIDs
        state.trackSort.field = .title
        state.trackSort.ascending = false
        XCTAssertEqual(state.selectedAlbumIDs, before)
    }
}
#endif
