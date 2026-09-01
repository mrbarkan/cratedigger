#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// Column k shows facet k's values among the tracks surviving columns 0..<k.
/// That sentence is the whole browser; these pin it.
final class BrowserCascadeTests: XCTestCase {

    // MARK: - Fixture

    private static func make(_ title: String, artist: String, album: String, genre: String?,
                             year: Int, format: String = "FLAC", number: Int = 1) -> LoadedTrack {
        LoadedTrack(
            track: AudioTrack(fileURL: URL(fileURLWithPath: "/Music/\(artist)/\(album)/\(title).flac"),
                              title: title, artist: artist, album: album, formatName: format, year: year,
                              trackNumber: number),
            metadata: ConversionMetadata(genre: genre)
        )
    }

    private lazy var soWhat = Self.make("So What", artist: "Miles Davis", album: "Kind of Blue", genre: "Jazz", year: 1959)
    private lazy var blueInGreen = Self.make("Blue in Green", artist: "Miles Davis", album: "Kind of Blue", genre: "Jazz", year: 1959, number: 2)
    private lazy var pharaoh = Self.make("Pharaoh's Dance", artist: "Miles Davis", album: "Bitches Brew", genre: "Jazz", year: 1970, format: "MP3")
    private lazy var human = Self.make("Human Behaviour", artist: "Björk", album: "Debut", genre: "Pop", year: 1993)
    private lazy var venus = Self.make("Venus as a Boy", artist: "Björk", album: "Debut", genre: "Electronic", year: 1993, number: 2)
    private lazy var kindOfBlue = Album(id: "miles::kob", artistID: "miles", artistName: "Miles Davis", title: "Kind of Blue",
                                        year: 1959, artworkHash: nil, tracks: [soWhat, blueInGreen])
    private lazy var bitchesBrew = Album(id: "miles::bb", artistID: "miles", artistName: "Miles Davis", title: "Bitches Brew",
                                         year: 1970, artworkHash: nil, tracks: [pharaoh])
    private lazy var debut = Album(id: "bjork::debut", artistID: "bjork", artistName: "Björk", title: "Debut",
                                   year: 1993, artworkHash: nil, tracks: [human, venus])
    private lazy var miles = Artist(id: "miles", name: "Miles Davis", albums: [kindOfBlue, bitchesBrew])
    private lazy var bjork = Artist(id: "bjork", name: "Björk", albums: [debut])
    private lazy var index = LibraryIndex(artists: [miles, bjork],
                                          allTracks: [soWhat, blueInGreen, pharaoh, human, venus],
                                          albumCount: 3, totalSizeBytes: 0)

    private var context: FacetContext { FacetContext(index: index) }

    private func columns(_ view: BrowserView,
                         anchors: [String?] = [],
                         multi: BrowserSelection.MultiSelection? = nil,
                         sorts: BrowserSorts = .defaults) -> [ColumnContent] {
        BrowserCascade.columns(view: view, in: index,
                               selection: BrowserSelection(anchors: anchors, multiSelection: multi),
                               sorts: sorts, context: context)
    }

    private func titles(_ content: ColumnContent) -> [String] {
        switch content {
        case .artists(let a): return a.map(\.name)
        case .albums(let a):  return a.map(\.title)
        case .tracks(let t):  return t.map(\.track.title)
        case .values(let v):  return v.map(\.title)
        }
    }

    // MARK: - Population

    func testColumnZeroIsTheWholeIndex() {
        let cols = columns(.classic)
        XCTAssertEqual(cols.count, 3)
        XCTAssertEqual(titles(cols[0]), ["Björk", "Miles Davis"], "artist sort, by name")
    }

    func testAColumnWithNothingSelectedPassesEverythingThrough() {
        let cols = columns(.classic)
        XCTAssertEqual(titles(cols[1]).sorted(), ["Bitches Brew", "Debut", "Kind of Blue"])
        XCTAssertEqual(cols[2].count, 5)
    }

    func testAnAnchorNarrowsTheColumnsToItsRight() {
        let cols = columns(.classic, anchors: ["miles", "miles::kob", nil])
        XCTAssertEqual(titles(cols[1]), ["Kind of Blue", "Bitches Brew"], "album sort, by year")
        XCTAssertEqual(titles(cols[2]), ["So What", "Blue in Green"])
    }

    func testAMultiSelectionNarrowsByEveryMemberOfTheSet() {
        let both = BrowserSelection.MultiSelection(column: 0, ids: ["miles", "bjork"])
        let cols = columns(.classic, anchors: ["miles", nil, nil], multi: both)
        XCTAssertEqual(cols[1].count, 3, "the set wins over the anchor")
    }

    /// An Album row is the index's album, whole, not a rebuilt one.
    func testAnAlbumColumnResolvesToTheIndexObjects() {
        let cols = columns(BrowserView([.genre, .album, .track]), anchors: ["jazz", nil, nil])
        guard case .albums(let albums) = cols[1] else { return XCTFail("expected albums") }
        XCTAssertEqual(albums, [kindOfBlue, bitchesBrew])
        XCTAssertEqual(albums.first?.tracks.count, 2, "whole album, whatever survived inside it")
    }

    // MARK: - Value columns

    func testAValueColumnCountsTracksUnderEachKey() {
        let cols = columns(BrowserView([.genre, .track]))
        guard case .values(let genres) = cols[0] else { return XCTFail("expected values") }
        XCTAssertEqual(genres.map { "\($0.title) \($0.count)" }, ["Electronic 1", "Jazz 3", "Pop 1"], "by title")
    }

    func testAValueColumnCanSortByCount() {
        var sorts = BrowserSorts.defaults
        sorts.value = BrowserSort(field: .count, ascending: false)
        let cols = columns(BrowserView([.genre, .track]), sorts: sorts)
        XCTAssertEqual(titles(cols[0]).first, "Jazz")
    }

    func testValueRowsNarrowTheNextColumn() {
        let cols = columns(BrowserView([.decade, .artist, .track]), anchors: ["1990", nil, nil])
        XCTAssertEqual(titles(cols[1]), ["Björk"])
        XCTAssertEqual(cols[2].count, 2)
    }

    /// `Genre: Pop · Album: Debut · Track` lists only Debut's pop track. That
    /// is what a cascade means, and what makes `Genre · Track` useful.
    func testTheTrackColumnIsNarrowedByEveryColumnToItsLeft() {
        let cols = columns(BrowserView([.genre, .album, .track]), anchors: ["pop", "bjork::debut", nil])
        XCTAssertEqual(titles(cols[2]), ["Human Behaviour"])
    }

    func testABlankFacetGetsANamedRow() {
        let untagged = Self.make("Loose", artist: "Nobody", album: "Nothing", genre: nil, year: 2000)
        let loose = Album(id: "n::n", artistID: "nobody", artistName: "Nobody", title: "Nothing",
                          year: 2000, artworkHash: nil, tracks: [untagged])
        let idx = LibraryIndex(artists: [Artist(id: "nobody", name: "Nobody", albums: [loose])],
                               allTracks: [untagged], albumCount: 1, totalSizeBytes: 0)
        let cols = BrowserCascade.columns(view: BrowserView([.genre, .track]), in: idx,
                                          selection: BrowserSelection(), sorts: .defaults,
                                          context: FacetContext(index: idx))
        XCTAssertEqual(titles(cols[0]), ["No Genre"])
    }

    // MARK: - Version groups

    /// A member pressing can be the selection: the Album column narrows by
    /// containment, so anchoring the member lists that pressing's tracks.
    func testAVersionMemberAnchorNarrowsToThatPressing() {
        let gold = Self.make("So What (Gold)", artist: "Miles Davis", album: "Kind of Blue", genre: "Jazz", year: 1959)
        let goldAlbum = Album(id: "miles::kob::gold", artistID: "miles", artistName: "Miles Davis",
                              title: "Kind of Blue [Gold]", year: 1959, artworkHash: nil, tracks: [gold])
        let release = Album(id: "group::kob", artistID: "miles", artistName: "Miles Davis", title: "Kind of Blue",
                            year: 1959, artworkHash: nil, tracks: kindOfBlue.tracks, versions: [kindOfBlue, goldAlbum])
        let idx = LibraryIndex(artists: [Artist(id: "miles", name: "Miles Davis", albums: [release])],
                               allTracks: kindOfBlue.tracks + [gold], albumCount: 1, totalSizeBytes: 0)
        let cols = BrowserCascade.columns(view: .classic, in: idx,
                                          selection: BrowserSelection(anchors: ["miles", "miles::kob::gold", nil]),
                                          sorts: .defaults, context: FacetContext(index: idx))
        XCTAssertEqual(titles(cols[2]), ["So What (Gold)"])
    }

    // MARK: - Sorting

    func testTheTrackColumnHonoursTheTrackSort() {
        var sorts = BrowserSorts.defaults
        sorts.track = BrowserSort(field: .title, ascending: false)
        let cols = columns(.table, sorts: sorts)
        XCTAssertEqual(titles(cols[0]).first, "Venus as a Boy")
    }

    // MARK: - What the selection means

    private func selected(_ view: BrowserView, anchors: [String?],
                          multi: BrowserSelection.MultiSelection? = nil) -> [String] {
        BrowserCascade.selectedTracks(view: view, in: index,
                                      selection: BrowserSelection(anchors: anchors, multiSelection: multi),
                                      context: context).map(\.track.title)
    }

    func testASingleTrackClickIsThatTrack() {
        XCTAssertEqual(selected(.classic, anchors: ["miles", "miles::kob", soWhat.track.id.uuidString]), ["So What"])
    }

    func testAnAlbumLeafIsTheAlbumsSurvivingTracks() {
        XCTAssertEqual(selected(BrowserView([.artist, .album]), anchors: ["miles", "miles::kob"]),
                       ["So What", "Blue in Green"])
    }

    func testAValueLeafIsItsTracks() {
        XCTAssertEqual(selected(BrowserView([.artist, .genre]), anchors: ["bjork", "pop"]), ["Human Behaviour"])
    }

    func testAMultiSelectionResolvesToTheUnion() {
        let two = BrowserSelection.MultiSelection(column: 2, ids: [soWhat.track.id.uuidString, pharaoh.track.id.uuidString])
        XCTAssertEqual(selected(.classic, anchors: ["miles", nil, nil], multi: two).sorted(),
                       ["Pharaoh's Dance", "So What"])
    }

    /// ⌘A on the Album column selects every album in the source, not just the
    /// anchored artist's. A set is what the user picked, literally, so the
    /// anchors to its left do not narrow it.
    func testASetIsResolvedLiterallyNotThroughTheAnchorsToItsLeft() {
        let allAlbums = BrowserSelection.MultiSelection(column: 1, ids: ["miles::kob", "bjork::debut"])
        XCTAssertEqual(selected(.classic, anchors: ["miles", "miles::kob", soWhat.track.id.uuidString], multi: allAlbums).sorted(),
                       ["Blue in Green", "Human Behaviour", "So What", "Venus as a Boy"])
    }

    // MARK: - Ids

    func testContentIDsFollowDisplayOrder() {
        let cols = columns(.classic, anchors: ["miles", nil, nil])
        XCTAssertEqual(cols[1].ids, ["miles::kob", "miles::bb"])
        XCTAssertEqual(cols[0].ids, ["bjork", "miles"])
    }
}
#endif
