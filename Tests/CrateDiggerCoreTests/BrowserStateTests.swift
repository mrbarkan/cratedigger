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
        // selectArtist never touches selectedTrackIDs, so give it a live value
        // directly, otherwise the assertion below would hold from the initial
        // state whether or not selectAlbum actually clears it.
        state.selectedTrackIDs = [UUID()]

        state.selectAlbum(albums[0], command: false, shift: false, ordered: albums, flat: false)

        XCTAssertTrue(state.selectedArtistIDs.isEmpty, "you pick artists or records, never both")
        XCTAssertTrue(state.selectedTrackIDs.isEmpty)
        XCTAssertEqual(state.selectedAlbumIDs, ["a1"])
    }

    func testPickingATrackClearsArtistAndAlbumSelections() {
        var state = BrowserState()
        state.selectArtist(artist("ar1"), command: false, shift: false, ordered: [artist("ar1")])
        XCTAssertFalse(state.selectedArtistIDs.isEmpty)
        // Populate the album set directly rather than through selectAlbum,
        // which would itself clear selectedArtistIDs and hide what we're
        // actually trying to prove: that selectTrack does this clearing too.
        state.selectedAlbumIDs = ["a1"]

        let tracks = [track("one"), track("two")]
        state.selectTrack(tracks[0], command: false, shift: false, ordered: tracks)

        XCTAssertTrue(state.selectedAlbumIDs.isEmpty)
        XCTAssertTrue(state.selectedArtistIDs.isEmpty)
        XCTAssertEqual(state.selectedTrackIDs, [tracks[0].track.id])
    }

    func testSelectingAnArtistClearsAlbumAndTrackSelections() {
        var state = BrowserState()
        let albums = [album("a1")]
        state.selectAlbum(albums[0], command: false, shift: false, ordered: albums, flat: false)
        XCTAssertFalse(state.selectedAlbumIDs.isEmpty)

        let tracks = [track("one"), track("two")]
        state.selectTrack(tracks[0], command: false, shift: false, ordered: tracks)
        XCTAssertFalse(state.selectedTrackIDs.isEmpty)
        // selectTrack already clears the album set as a side effect of its own
        // contract (proven above), so put a live value back directly to prove
        // selectArtist clears a populated album set on its own, not just an
        // already-empty one.
        state.selectedAlbumIDs = ["a1"]

        state.selectArtist(artist("ar1"), command: false, shift: false, ordered: [artist("ar1")])

        XCTAssertTrue(state.selectedAlbumIDs.isEmpty, "selecting an artist clears a live album selection")
        XCTAssertTrue(state.selectedTrackIDs.isEmpty, "selecting an artist clears a live track selection")
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

    // MARK: - Select all

    func testSelectAllArtistsClearsOtherSetsKeepsAnExistingAnchorAndNoOpsOnEmpty() {
        var state = BrowserState()
        let artists = [artist("ar1"), artist("ar2")]
        state.selectedAlbumIDs = ["a1"]
        state.selectedTrackIDs = [UUID()]

        state.selectAllArtists(artists)
        XCTAssertEqual(state.selectedArtistIDs, ["ar1", "ar2"])
        XCTAssertTrue(state.selectedAlbumIDs.isEmpty, "bulk select clears the other columns too")
        XCTAssertTrue(state.selectedTrackIDs.isEmpty)
        XCTAssertEqual(state.selectedArtistID, "ar1", "no prior anchor, so select-all picks one")

        // a pre-existing anchor from outside the selected list is left alone
        state.selectedArtistID = "existing"
        state.selectAllArtists(artists)
        XCTAssertEqual(state.selectedArtistID, "existing", "a pre-existing anchor survives a select-all")

        // empty input changes nothing
        state.selectAllArtists([])
        XCTAssertEqual(state.selectedArtistIDs, ["ar1", "ar2"], "empty input is a no-op")

        // one column owns the set: picking in another column moves it there
        state.selectedAlbumIDs = ["a1"]
        XCTAssertEqual(state.selectedAlbumIDs, ["a1"])
        XCTAssertTrue(state.selectedArtistIDs.isEmpty, "the set moved to the other column")
    }

    func testSelectAllAlbumsClearsOtherSetsKeepsAnExistingAnchorAndNoOpsOnEmpty() {
        var state = BrowserState()
        let albums = [album("a1"), album("a2")]
        state.selectedArtistIDs = ["ar1"]
        state.selectedTrackIDs = [UUID()]

        state.selectAllAlbums(albums)
        XCTAssertEqual(state.selectedAlbumIDs, ["a1", "a2"])
        XCTAssertTrue(state.selectedArtistIDs.isEmpty, "bulk select clears the other columns too")
        XCTAssertTrue(state.selectedTrackIDs.isEmpty)
        XCTAssertEqual(state.selectedAlbumID, "a1", "no prior anchor, so select-all picks one")

        // a pre-existing anchor from outside the selected list is left alone
        state.selectedAlbumID = "existing"
        state.selectAllAlbums(albums)
        XCTAssertEqual(state.selectedAlbumID, "existing", "a pre-existing anchor survives a select-all")

        // empty input changes nothing
        state.selectAllAlbums([])
        XCTAssertEqual(state.selectedAlbumIDs, ["a1", "a2"], "empty input is a no-op")

        // one column owns the set: picking in another column moves it there
        state.selectedArtistIDs = ["ar1"]
        XCTAssertEqual(state.selectedArtistIDs, ["ar1"])
        XCTAssertTrue(state.selectedAlbumIDs.isEmpty, "the set moved to the other column")
    }

    func testSelectAllTracksClearsOtherSetsKeepsAnExistingAnchorAndNoOpsOnEmpty() {
        var state = BrowserState()
        let tracks = [track("one"), track("two")]
        state.selectedArtistIDs = ["ar1"]
        state.selectedAlbumIDs = ["a1"]

        state.selectAllTracks(tracks)
        XCTAssertEqual(state.selectedTrackIDs, Set(tracks.map { $0.track.id }))
        XCTAssertTrue(state.selectedArtistIDs.isEmpty, "bulk select clears the other columns too")
        XCTAssertTrue(state.selectedAlbumIDs.isEmpty)
        XCTAssertEqual(state.selectedTrackID, tracks[0].track.id, "no prior anchor, so select-all picks one")

        // a pre-existing anchor from outside the selected list is left alone
        let existingAnchor = UUID()
        state.selectedTrackID = existingAnchor
        state.selectAllTracks(tracks)
        XCTAssertEqual(state.selectedTrackID, existingAnchor, "a pre-existing anchor survives a select-all")

        // empty input changes nothing
        state.selectAllTracks([])
        XCTAssertEqual(state.selectedTrackIDs, Set(tracks.map { $0.track.id }), "empty input is a no-op")

        // one column owns the set: picking in another column moves it there
        state.selectedArtistIDs = ["ar1"]
        XCTAssertEqual(state.selectedArtistIDs, ["ar1"])
        XCTAssertTrue(state.selectedTrackIDs.isEmpty, "the set moved to the other column")
    }

    // MARK: - Sort

    func testSortDefaultsMatchWhatTheBrowserHasAlwaysShown() {
        let state = BrowserState()
        XCTAssertEqual(state.trackSort.field, .trackNumber)
        XCTAssertTrue(state.trackSort.ascending)
        XCTAssertEqual(state.albumSort.field, .year)
        XCTAssertTrue(state.albumSort.ascending)
        XCTAssertEqual(state.artistSort.field, .name)
        XCTAssertTrue(state.artistSort.ascending)
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

    // MARK: - Re-anchoring

    /// An index built the way the browser sees one: two artists, one album
    /// each, one track each.
    private func indexFixture() -> LibraryIndex {
        let t1 = track("one")
        let t2 = track("two")
        let a1 = album("a1", tracks: [t1])
        let a2 = album("a2", tracks: [t2])
        return LibraryIndex(
            artists: [
                Artist(id: "ar1", name: "ar1", albums: [a1]),
                Artist(id: "ar2", name: "ar2", albums: [a2])
            ],
            allTracks: [t1, t2],
            albumCount: 2,
            totalSizeBytes: 0
        )
    }

    func testReanchorKeepsAnchorsTheIndexStillContains() {
        let index = indexFixture()
        var state = BrowserState()
        state.selectedArtistID = "ar2"
        state.selectedAlbumID = "a2"
        state.selectedTrackID = index.allTracks[1].track.id

        state.reanchor(in: index)

        XCTAssertEqual(state.selectedArtistID, "ar2")
        XCTAssertEqual(state.selectedAlbumID, "a2")
        XCTAssertEqual(state.selectedTrackID, index.allTracks[1].track.id)
    }

    func testReanchorMovesAMissingAnchorToTheFirstSurvivor() {
        let index = indexFixture()
        var state = BrowserState()
        state.selectedArtistID = "gone"
        state.selectedAlbumID = "gone"
        state.selectedTrackID = UUID()

        state.reanchor(in: index)

        XCTAssertEqual(state.selectedArtistID, "ar1")
        XCTAssertEqual(state.selectedAlbumID, "a1")
        XCTAssertEqual(state.selectedTrackID, index.allTracks[0].track.id)
    }

    /// A selection you cannot see can still be converted, retagged or added to
    /// a crate. Hiding rows has to drop it.
    func testReanchorClearsTheMultiSelection() {
        var state = BrowserState()
        state.selectedArtistIDs = ["ar1"]
        state.selectedAlbumIDs = ["a1"]
        state.selectedTrackIDs = [UUID()]

        state.reanchor(in: indexFixture())

        XCTAssertTrue(state.selectedArtistIDs.isEmpty)
        XCTAssertTrue(state.selectedAlbumIDs.isEmpty)
        XCTAssertTrue(state.selectedTrackIDs.isEmpty)
    }

    /// A member pressing is a legal album anchor: resolving it as missing would
    /// bounce the browser off the version row the user just clicked.
    func testReanchorKeepsAVersionMemberAsTheAlbumAnchor() {
        let member = album("member", tracks: [track("m1")])
        let release = Album(id: "group::r", artistID: "ar1", artistName: "ar1",
                            title: "R", year: nil, artworkHash: nil,
                            tracks: member.tracks, versions: [member])
        let index = LibraryIndex(
            artists: [Artist(id: "ar1", name: "ar1", albums: [release])],
            allTracks: member.tracks, albumCount: 1, totalSizeBytes: 0
        )
        var state = BrowserState()
        state.selectedAlbumID = "member"

        state.reanchor(in: index)

        XCTAssertEqual(state.selectedAlbumID, "member")
    }

    func testReanchorOnAnEmptyIndexClearsEveryAnchor() {
        var state = BrowserState()
        state.selectedArtistID = "ar1"
        state.selectedAlbumID = "a1"
        state.selectedTrackID = UUID()

        state.reanchor(in: .empty)

        XCTAssertNil(state.selectedArtistID)
        XCTAssertNil(state.selectedAlbumID)
        XCTAssertNil(state.selectedTrackID)
    }

    // MARK: - Generic columns

    /// The same two-artist index, browsed as Genre · Artist · Track. Both
    /// tracks are untagged, so there is one genre row.
    private func genreView() -> (BrowserState, LibraryIndex) {
        var state = BrowserState()
        state.view = BrowserView([.genre, .artist, .track])
        return (state, indexFixture())
    }

    func testSettingTheViewReshapesTheAnchors() {
        var state = BrowserState()
        XCTAssertEqual(state.selection.anchors.count, 3)
        state.view = BrowserView([.genre, .track])
        XCTAssertEqual(state.selection.anchors.count, 2)
        XCTAssertNil(state.selection.multiSelection, "a new shape drops the set")
    }

    func testAClickClearsTheAnchorsToItsRight() {
        var (state, _) = genreView()
        state.selection.anchors = ["", "ar2", "x"]
        state.select(column: 0, id: "", command: false, shift: false, ordered: [""])
        XCTAssertEqual(state.selection.anchors[0], "")
        XCTAssertNil(state.selection.anchors[1])
        XCTAssertNil(state.selection.anchors[2])
    }

    func testReanchorFillsClearedAnchorsWithTheFirstRow() {
        var (state, index) = genreView()
        state.select(column: 0, id: "", command: false, shift: false, ordered: [""])
        let columns = state.reanchor(in: index)
        XCTAssertEqual(state.selection.anchors[1], "ar1", "first artist under the genre")
        XCTAssertEqual(state.selection.anchors[2], index.allTracks[0].track.id.uuidString)
        XCTAssertEqual(columns.count, 3, "reanchor hands back the columns it computed")
    }

    func testCommandClickInAnotherColumnMovesTheSet() {
        var (state, _) = genreView()
        state.select(column: 1, id: "ar1", command: true, shift: false, ordered: ["ar1", "ar2"])
        XCTAssertEqual(state.selection.multiSelection, .init(column: 1, ids: ["ar1"]))
        state.select(column: 0, id: "", command: true, shift: false, ordered: [""])
        XCTAssertEqual(state.selection.multiSelection?.column, 0, "one column owns the set")
    }

    func testShiftClickRangesOverTheColumnsOrder() {
        var (state, _) = genreView()
        state.select(column: 1, id: "ar1", command: false, shift: false, ordered: ["ar1", "ar2"])
        state.select(column: 1, id: "ar2", command: false, shift: true, ordered: ["ar1", "ar2"])
        XCTAssertEqual(state.selection.multiSelection?.ids, ["ar1", "ar2"])
    }

    func testSelectAllColumnTakesEveryRowAndAnchorsTheFirst() {
        var (state, _) = genreView()
        state.selectAll(column: 1, ids: ["ar1", "ar2"])
        XCTAssertEqual(state.selection.multiSelection, .init(column: 1, ids: ["ar1", "ar2"]))
        XCTAssertEqual(state.selection.anchors[1], "ar1")
    }

    /// The outside-in click: "Go to Current Song", the gallery, the condensed
    /// browser. Every column's anchor comes from the track.
    func testRevealSetsEveryAnchorFromTheTrack() {
        var (state, index) = genreView()
        let two = index.allTracks[1]
        state.reveal(track: two, in: index)
        XCTAssertEqual(state.selection.anchors, ["", "ar2", two.track.id.uuidString])
        XCTAssertNil(state.selection.multiSelection)
    }

    /// The old names keep working over the new state, so the ~120 call sites
    /// outside the browser do not move.
    func testLegacyNamesForwardOntoTheColumns() {
        var state = BrowserState()   // classic
        state.selectedArtistID = "ar1"
        state.selectedAlbumIDs = ["a1", "a2"]
        XCTAssertEqual(state.selection.anchors[0], "ar1")
        XCTAssertEqual(state.selection.multiSelection, .init(column: 1, ids: ["a1", "a2"]))
        XCTAssertEqual(state.selectedAlbumIDs, ["a1", "a2"])
        XCTAssertTrue(state.selectedArtistIDs.isEmpty, "the set belongs to the album column")
    }

    func testLegacyNamesAreEmptyWhenTheViewHasNoSuchColumn() {
        var state = BrowserState()
        state.view = BrowserView([.genre, .track])
        state.selectedArtistID = "ar1"
        XCTAssertNil(state.selectedArtistID, "nowhere to put it")
        XCTAssertTrue(state.selectedArtistIDs.isEmpty)
    }
}
#endif
