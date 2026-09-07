#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// What each facet makes of a track: the key selection and persistence store,
/// and the title the row draws.
final class BrowserFacetTests: XCTestCase {

    private func track(_ title: String = "T",
                       artist: String = "Miles Davis",
                       album: String = "Kind of Blue",
                       albumArtist: String? = nil,
                       genre: String? = nil,
                       year: Int? = nil,
                       format: String? = nil,
                       ext: String = "flac") -> LoadedTrack {
        LoadedTrack(
            track: AudioTrack(fileURL: URL(fileURLWithPath: "/Music/\(artist)/\(album)/\(title).\(ext)"),
                              title: title, artist: artist, album: album, formatName: format, year: year),
            metadata: ConversionMetadata(albumArtist: albumArtist, genre: genre)
        )
    }

    /// One artist, one album, so the artist/album facets have something to
    /// resolve to.
    private func context(for tracks: [LoadedTrack], ratings: [String: Int] = [:]) -> FacetContext {
        let album = Album(id: "miles::kob", artistID: "miles", artistName: "Miles Davis",
                          title: "Kind of Blue", year: 1959, artworkHash: nil, tracks: tracks)
        let index = LibraryIndex(
            artists: [Artist(id: "miles", name: "Miles Davis", albums: [album])],
            allTracks: tracks, albumCount: 1, totalSizeBytes: 0)
        return FacetContext(index: index, ratingByPath: ratings)
    }

    func testArtistAndAlbumResolveToTheIndexObjects() {
        let t = track()
        let ctx = context(for: [t])
        XCTAssertEqual(BrowserFacet.artist.value(of: t, context: ctx), FacetValue(id: "miles", title: "Miles Davis"))
        XCTAssertEqual(BrowserFacet.album.value(of: t, context: ctx), FacetValue(id: "miles::kob", title: "Kind of Blue"))
    }

    func testTrackIsItsOwnKey() {
        let t = track("So What")
        XCTAssertEqual(BrowserFacet.track.value(of: t, context: context(for: [t])),
                       FacetValue(id: t.track.id.uuidString, title: "So What"))
    }

    func testGenreFoldsTheKeyAndKeepsTheTitle() {
        let rock = track(genre: "Rock")
        let ROCK = track(genre: "ROCK")
        let ctx = context(for: [rock, ROCK])
        XCTAssertEqual(BrowserFacet.genre.value(of: rock, context: ctx).id,
                       BrowserFacet.genre.value(of: ROCK, context: ctx).id, "one row, not two")
        XCTAssertEqual(BrowserFacet.genre.value(of: rock, context: ctx).title, "Rock")
    }

    func testBlankGenreHasAName() {
        let t = track(genre: nil)
        XCTAssertEqual(BrowserFacet.genre.value(of: t, context: context(for: [t])).title, "No Genre")
    }

    /// Tags that draw as nothing — a stray newline, a control character, a
    /// BOM — must not become blank rows with a count and no name.
    func testAnInvisibleGenreCountsAsMissing() {
        for junk in ["\n", "\u{0}", "\u{FEFF}", " \t "] {
            let t = track(genre: junk)
            XCTAssertEqual(BrowserFacet.genre.value(of: t, context: context(for: [t])).title, "No Genre",
                           "genre \(junk.unicodeScalars.map { String($0.value) })")
        }
    }

    func testYearAndDecade() {
        let t = track(year: 1977)
        let ctx = context(for: [t])
        XCTAssertEqual(BrowserFacet.year.value(of: t, context: ctx), FacetValue(id: "1977", title: "1977"))
        XCTAssertEqual(BrowserFacet.decade.value(of: t, context: ctx), FacetValue(id: "1970", title: "1970s"))
    }

    func testMissingYearHasAName() {
        let t = track(year: nil)
        let ctx = context(for: [t])
        XCTAssertEqual(BrowserFacet.year.value(of: t, context: ctx).title, "Unknown Year")
        XCTAssertEqual(BrowserFacet.decade.value(of: t, context: ctx).title, "Unknown Decade")
    }

    func testFormatPrefersTheProbedNameAndFallsBackToTheExtension() {
        let dsd = track(format: "DSD64", ext: "dsf")
        let bare = track(format: nil, ext: "mp3")
        let ctx = context(for: [dsd, bare])
        XCTAssertEqual(BrowserFacet.format.value(of: dsd, context: ctx).title, "DSD64")
        XCTAssertEqual(BrowserFacet.format.value(of: bare, context: ctx).title, "MP3")
    }

    func testAlbumArtistFallsBackToTheTrackArtist() {
        let various = track(artist: "Someone", albumArtist: "Various Artists")
        let plain = track(artist: "Björk", albumArtist: nil)
        let ctx = context(for: [various, plain])
        XCTAssertEqual(BrowserFacet.albumArtist.value(of: various, context: ctx).title, "Various Artists")
        XCTAssertEqual(BrowserFacet.albumArtist.value(of: plain, context: ctx).title, "Björk")
    }

    func testRatingReadsTheListeningStoreAndUnratedHasAName() {
        let rated = track("Rated")
        let unrated = track("Unrated")
        let ctx = context(for: [rated, unrated],
                          ratings: [rated.track.fileURL.standardizedFileURL.path: 4])
        XCTAssertEqual(BrowserFacet.rating.value(of: rated, context: ctx), FacetValue(id: "4", title: "★★★★☆"))
        XCTAssertEqual(BrowserFacet.rating.value(of: unrated, context: ctx), FacetValue(id: "0", title: "Unrated"))
    }

    func testEveryFacetHasATitle() {
        for facet in BrowserFacet.allCases {
            XCTAssertFalse(facet.title.isEmpty, "\(facet) has no column title")
        }
    }
}
#endif
