#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class LibraryIndexSortTests: XCTestCase {

    private func track(
        title: String,
        artist: String = "X",
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        duration: Double = 0
    ) -> LoadedTrack {
        let audio = AudioTrack(
            fileURL: URL(fileURLWithPath: "/m/\(title).flac"),
            title: title,
            artist: artist,
            album: "Album",
            durationSeconds: duration,
            year: 2020,
            trackNumber: trackNumber,
            discNumber: discNumber
        )
        let metadata = ConversionMetadata(
            title: title,
            artist: artist,
            album: "Album",
            trackNumber: trackNumber,
            discNumber: discNumber,
            year: 2020
        )
        return LoadedTrack(track: audio, metadata: metadata)
    }

    func testTrackNumberSortIsDiscAware() {
        let tracks = [
            track(title: "D2T1", trackNumber: 1, discNumber: 2),
            track(title: "D1T2", trackNumber: 2, discNumber: 1),
            track(title: "D1T1", trackNumber: 1, discNumber: 1)
        ]
        let sorted = LibraryIndex.sortedTracks(tracks, by: .trackNumber, ascending: true)
        XCTAssertEqual(sorted.map(\.track.title), ["D1T1", "D1T2", "D2T1"])
    }

    func testTitleSortAscendingAndDescending() {
        let tracks = [
            track(title: "Banana", trackNumber: 1),
            track(title: "apple", trackNumber: 2),
            track(title: "Cherry", trackNumber: 3)
        ]
        let asc = LibraryIndex.sortedTracks(tracks, by: .title, ascending: true)
        XCTAssertEqual(asc.map(\.track.title), ["apple", "Banana", "Cherry"])

        let desc = LibraryIndex.sortedTracks(tracks, by: .title, ascending: false)
        XCTAssertEqual(desc.map(\.track.title), ["Cherry", "Banana", "apple"])
    }

    func testDurationSort() {
        let tracks = [
            track(title: "Long", trackNumber: 1, duration: 300),
            track(title: "Short", trackNumber: 2, duration: 60),
            track(title: "Mid", trackNumber: 3, duration: 180)
        ]
        let asc = LibraryIndex.sortedTracks(tracks, by: .duration, ascending: true)
        XCTAssertEqual(asc.map(\.track.title), ["Short", "Mid", "Long"])
    }

    func testArtistSortWithNaturalTiebreak() {
        // Same artist → falls back to disc/track natural order.
        let tracks = [
            track(title: "Beta", artist: "Zed", trackNumber: 2),
            track(title: "Alpha", artist: "Zed", trackNumber: 1),
            track(title: "Gamma", artist: "Ann", trackNumber: 9)
        ]
        let asc = LibraryIndex.sortedTracks(tracks, by: .artist, ascending: true)
        XCTAssertEqual(asc.map(\.track.title), ["Gamma", "Alpha", "Beta"])
    }

    func testSortIsStableForEqualKeys() {
        // Equal duration → deterministic natural-order tiebreak (track number).
        let tracks = [
            track(title: "Third", trackNumber: 3, duration: 100),
            track(title: "First", trackNumber: 1, duration: 100),
            track(title: "Second", trackNumber: 2, duration: 100)
        ]
        let sorted = LibraryIndex.sortedTracks(tracks, by: .duration, ascending: true)
        XCTAssertEqual(sorted.map(\.track.title), ["First", "Second", "Third"])
    }

    // MARK: - Album / artist sorting

    private func album(_ title: String, year: Int?) -> Album {
        Album(id: title, artistID: "a", artistName: "A", title: title, year: year, artworkHash: nil, tracks: [])
    }

    func testSortedAlbumsByYearNilLast() {
        let albums = [album("New", year: 2020), album("NoYear", year: nil), album("Old", year: 1999)]
        let asc = LibraryIndex.sortedAlbums(albums, by: .year, ascending: true)
        XCTAssertEqual(asc.map(\.title), ["Old", "New", "NoYear"])
        let desc = LibraryIndex.sortedAlbums(albums, by: .year, ascending: false)
        XCTAssertEqual(desc.first?.title, "NoYear") // reversed: nil-last becomes first
    }

    func testSortedAlbumsByTitle() {
        let albums = [album("Zoo", year: 2001), album("apple", year: 2002), album("Mango", year: 2003)]
        let asc = LibraryIndex.sortedAlbums(albums, by: .title, ascending: true)
        XCTAssertEqual(asc.map(\.title), ["apple", "Mango", "Zoo"])
    }

    private func artist(_ name: String, albumCount: Int) -> Artist {
        let albums = (0..<albumCount).map {
            Album(id: "\(name)-\($0)", artistID: name, artistName: name, title: "Al\($0)", year: 2000, artworkHash: nil, tracks: [])
        }
        return Artist(id: name, name: name, albums: albums)
    }

    func testSortedArtistsByName() {
        let artists = [artist("Zed", albumCount: 1), artist("Ann", albumCount: 5), artist("Unknown Artist", albumCount: 2)]
        let asc = LibraryIndex.sortedArtists(artists, by: .name, ascending: true)
        // Unknown Artist always sorts last under name ordering.
        XCTAssertEqual(asc.map(\.name), ["Ann", "Zed", "Unknown Artist"])
    }

    func testSortedArtistsByAlbumCount() {
        let artists = [artist("Zed", albumCount: 1), artist("Ann", albumCount: 5), artist("Mid", albumCount: 3)]
        let desc = LibraryIndex.sortedArtists(artists, by: .albumCount, ascending: false)
        XCTAssertEqual(desc.map(\.name), ["Ann", "Mid", "Zed"])
    }
}
#endif
