#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// The library search. `BrowserFilter` decides what a query means and
/// `LibraryIndex.filtered(by:)` decides what survives it, so between them they
/// are the whole feature: the browser just draws whatever comes back.
final class BrowserFilterTests: XCTestCase {

    // MARK: - Fixtures

    private func track(
        _ title: String,
        artist: String = "Miles Davis",
        album: String = "Kind of Blue",
        albumArtist: String? = nil,
        path: String? = nil,
        format: String? = nil
    ) -> LoadedTrack {
        let url = URL(fileURLWithPath: path ?? "/Music/\(artist)/\(album)/\(title).flac")
        return LoadedTrack(
            track: AudioTrack(fileURL: url, title: title, artist: artist, album: album,
                              formatName: format),
            metadata: ConversionMetadata(albumArtist: albumArtist)
        )
    }

    private func album(_ title: String,
                       artist: String = "Miles Davis",
                       tracks: [LoadedTrack],
                       versions: [Album]? = nil) -> Album {
        Album(
            id: "\(artist)::\(title)",
            artistID: artist,
            artistName: artist,
            title: title,
            year: nil,
            artworkHash: nil,
            tracks: tracks,
            versions: versions
        )
    }

    private func index(_ artists: [Artist]) -> LibraryIndex {
        LibraryIndex(
            artists: artists,
            allTracks: artists.flatMap { $0.albums.flatMap(\.tracks) },
            albumCount: artists.reduce(0) { $0 + $1.albums.count },
            totalSizeBytes: 1234
        )
    }

    /// Two artists, two albums each, so a filter has something to prune at
    /// every level.
    private func library() -> LibraryIndex {
        let blue = album("Kind of Blue", tracks: [track("So What"), track("Blue in Green")])
        let bitches = album("Bitches Brew", tracks: [
            track("Pharaoh's Dance", album: "Bitches Brew"),
            track("Spanish Key", album: "Bitches Brew")
        ])
        let miles = Artist(id: "Miles Davis", name: "Miles Davis", albums: [blue, bitches])

        let debut = album("Debut", artist: "Björk", tracks: [
            track("Human Behaviour", artist: "Björk", album: "Debut"),
            track("Venus as a Boy", artist: "Björk", album: "Debut")
        ])
        let bjork = Artist(id: "Björk", name: "Björk", albums: [debut])
        return index([miles, bjork])
    }

    private func filter(_ query: String) -> BrowserFilter {
        BrowserFilter(query: query)
    }

    private func titles(_ index: LibraryIndex) -> [String] {
        index.allTracks.map(\.track.title)
    }

    // MARK: - Activity

    func testAnEmptyQueryIsInactive() {
        XCTAssertFalse(BrowserFilter().isActive)
        XCTAssertFalse(filter("   ").isActive)
        XCTAssertTrue(filter("mil").isActive)
    }

    func testAnInactiveFilterPrunesNothing() {
        let all = library()
        let same = all.filtered(by: BrowserFilter())
        XCTAssertEqual(same.artists.count, 2)
        XCTAssertEqual(same.allTracks.count, 6)
        XCTAssertEqual(same.albumCount, 3)
    }

    // MARK: - Matching a track

    func testMatchingIgnoresCase() {
        XCTAssertTrue(filter("SO WHAT").matches(track("So What")))
    }

    func testMatchingIgnoresDiacritics() {
        let bjork = track("Human Behaviour", artist: "Björk", album: "Debut")
        XCTAssertTrue(filter("bjork").matches(bjork))
        XCTAssertTrue(filter("björk").matches(bjork))
    }

    func testEveryTokenMustMatchSomething() {
        let soWhat = track("So What")
        XCTAssertTrue(filter("mil blue").matches(soWhat), "artist and album, one token each")
        XCTAssertFalse(filter("mil green").matches(soWhat), "second token matches nothing")
    }

    func testTitleMatches() {
        XCTAssertTrue(filter("pharaoh").matches(track("Pharaoh's Dance")))
    }

    func testArtistMatches() {
        XCTAssertTrue(filter("davis").matches(track("So What")))
    }

    func testAlbumMatches() {
        XCTAssertTrue(filter("kind of").matches(track("So What")))
    }

    /// Compilations tag every track to a different artist, so the album artist
    /// is the only field that finds them.
    func testAlbumArtistMatches() {
        let compilation = track("Song", artist: "Someone Else", album: "A Comp",
                                albumArtist: "Various Artists")
        XCTAssertTrue(filter("various").matches(compilation))
    }

    /// A folder name that appears in no tag: the path is what finds a rip you
    /// filed by hand.
    func testFilePathMatches() {
        let ripped = track("Untitled", artist: "", album: "",
                           path: "/Music/Bootlegs/1975 Osaka/a1.flac")
        XCTAssertTrue(filter("osaka").matches(ripped))
    }

    func testFormatMatches() {
        let dsd = track("So What", format: "DSD64")
        XCTAssertTrue(filter("dsd").matches(dsd))
    }

    /// With no probed format name, the extension is the format.
    func testFormatFallsBackToTheFileExtension() {
        XCTAssertTrue(filter("flac").matches(track("So What")))
    }

    // MARK: - Pruning the index

    func testTrackLevelMatchKeepsOnlyTheHits() {
        let hit = library().filtered(by: filter("so what"))
        XCTAssertEqual(titles(hit), ["So What"])
        XCTAssertEqual(hit.artists.count, 1)
        XCTAssertEqual(hit.artists.first?.albums.count, 1)
    }

    /// Searching a record's name has to give you the record, not the one track
    /// whose title happens to repeat it.
    func testAlbumLevelMatchKeepsEveryTrack() {
        let hit = library().filtered(by: filter("kind of blue"))
        XCTAssertEqual(titles(hit), ["So What", "Blue in Green"])
    }

    func testArtistLevelMatchKeepsEveryAlbum() {
        let hit = library().filtered(by: filter("miles davis"))
        XCTAssertEqual(hit.artists.count, 1)
        XCTAssertEqual(hit.artists.first?.albums.count, 2)
        XCTAssertEqual(hit.allTracks.count, 4)
    }

    func testNoMatchLeavesAnEmptyIndex() {
        let none = library().filtered(by: filter("zzzz"))
        XCTAssertTrue(none.artists.isEmpty)
        XCTAssertTrue(none.allTracks.isEmpty)
        XCTAssertEqual(none.albumCount, 0)
    }

    func testAlbumCountCountsSurvivingAlbums() {
        XCTAssertEqual(library().filtered(by: filter("blue")).albumCount, 1)
    }

    /// `totalSizeBytes` comes from stat-ing every file at build time. Pruning
    /// must not pretend to recompute it.
    func testTotalSizeIsCarriedOverUnchanged() {
        XCTAssertEqual(library().filtered(by: filter("so what")).totalSizeBytes, 1234)
    }

    func testTrackOrderIsPreserved() {
        let hit = library().filtered(by: filter("miles"))
        XCTAssertEqual(titles(hit), ["So What", "Blue in Green", "Pharaoh's Dance", "Spanish Key"])
    }

    // MARK: - The pre-folded cache

    /// A keystroke over fourteen thousand tracks is eighty thousand
    /// locale-aware searches, which is slow enough to feel. Folding each
    /// track's fields once and searching the result has to give the identical
    /// answer, or the fast path is a different feature.
    func testCachedHaystacksGiveTheSameResultAsFoldingEveryTime() {
        let all = library()
        let haystacks = LibraryIndex.searchHaystacks(for: all.allTracks)
        for query in ["mil", "blue", "bjork", "mil blue", "flac", "zzz", "venus"] {
            let slow = all.filtered(by: filter(query))
            let fast = all.filtered(by: filter(query), haystacks: haystacks)
            XCTAssertEqual(titles(fast), titles(slow), "query \(query)")
            XCTAssertEqual(fast.artists.count, slow.artists.count, "query \(query)")
        }
    }

    /// A track the cache has never seen (added since it was built) must still
    /// be matched, not silently dropped.
    func testATrackMissingFromTheCacheFallsBackToFolding() {
        let all = library()
        XCTAssertEqual(titles(all.filtered(by: filter("venus"), haystacks: [:])), ["Venus as a Boy"])
    }

    // MARK: - Version groups

    /// A grouped release: one synthesised album carrying two pressings, whose
    /// own `tracks` are the primary pressing's. `allTracks` holds every
    /// pressing's files, the way `LibraryIndex.build` leaves it.
    private func groupedLibrary() -> LibraryIndex {
        let original = album("Kind of Blue", tracks: [track("So What")])
        let gold = album("Kind of Blue [Gold CD]", tracks: [track("So What (Gold)")])
        let release = Album(
            id: "group::kob",
            artistID: "Miles Davis",
            artistName: "Miles Davis",
            title: "Kind of Blue",
            year: nil,
            artworkHash: nil,
            tracks: original.tracks,
            versions: [original, gold]
        )
        return LibraryIndex(
            artists: [Artist(id: "Miles Davis", name: "Miles Davis", albums: [release])],
            allTracks: original.tracks + gold.tracks,
            albumCount: 1,
            totalSizeBytes: 1234
        )
    }

    /// A hit inside one pressing keeps the release, carrying only that pressing.
    func testVersionGroupSurvivesOnAMemberHit() {
        let hit = groupedLibrary().filtered(by: filter("gold"))
        let release = hit.artists.first?.albums.first
        XCTAssertEqual(release?.versions?.count, 1)
        XCTAssertEqual(release?.versions?.first?.title, "Kind of Blue [Gold CD]")
        XCTAssertTrue(release?.tracks.isEmpty == true, "the primary pressing has no hit")
        XCTAssertEqual(titles(hit), ["So What (Gold)"], "a member's tracks are still in allTracks")
    }

    func testReleaseTitleHitKeepsEveryMemberWhole() {
        let hit = groupedLibrary().filtered(by: filter("kind of blue"))
        let release = hit.artists.first?.albums.first
        XCTAssertEqual(release?.versions?.count, 2)
        XCTAssertEqual(release?.tracks.count, 1)
    }

    func testAReleaseWithNoHitsAnywhereIsRemoved() {
        XCTAssertTrue(groupedLibrary().filtered(by: filter("zzzz")).artists.isEmpty)
    }
}
#endif
