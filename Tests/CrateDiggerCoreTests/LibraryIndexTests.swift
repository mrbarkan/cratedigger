#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class LibraryIndexTests: XCTestCase {

    private func loaded(album: String, format: String, title: String = "One More Time",
                        artist: String = "Daft Punk", year: Int = 2001) -> LoadedTrack {
        let url = URL(fileURLWithPath: "/tmp/\(album)/\(title).\(format)")
        let t = AudioTrack(fileURL: url, title: title, artist: artist, album: album,
                           formatName: format, bitrateKbps: 900, sampleRateHz: 44100, year: year)
        return LoadedTrack(track: t, metadata: ConversionMetadata())
    }

    func testFoldsGroupedVersionsIntoOneRelease() {
        let planner = OutputPathPlanner()
        let us = loaded(album: "Discovery", format: "flac")
        let jp = loaded(album: "Discovery (JP)", format: "flac")
        let kUS = planner.albumFolderKey(for: us)
        let kJP = planner.albumFolderKey(for: jp)
        let group = AlbumGroup(id: "g1", name: "Discovery", artistID: "daft punk",
                               originalYear: 1999, primaryKey: kUS,
                               members: [VersionMember(key: kUS, editionLabel: "US"),
                                         VersionMember(key: kJP, editionLabel: "JP")])
        let index = LibraryIndex.build(from: [us, jp], groups: [group])

        let albums = index.allAlbums
        XCTAssertEqual(albums.count, 1)
        let release = albums[0]
        XCTAssertTrue(release.isVersionGroup)
        XCTAssertEqual(release.title, "Discovery")
        XCTAssertEqual(release.originalYear, 1999)
        XCTAssertEqual(release.versions?.count, 2)
        XCTAssertEqual(release.versions?.compactMap(\.editionLabel).sorted(), ["JP", "US"])
        XCTAssertEqual(index.allTracks.count, 2)
    }

    func testDissolvesGroupWithFewerThanTwoLiveMembers() {
        let planner = OutputPathPlanner()
        let us = loaded(album: "Discovery", format: "flac")
        let kUS = planner.albumFolderKey(for: us)
        let ghost = AlbumFolderKey(artistBucket: "Daft Punk", album: "Gone", year: "2001")
        let group = AlbumGroup(id: "g1", name: "Discovery", artistID: "daft punk",
                               originalYear: 1999, primaryKey: kUS,
                               members: [VersionMember(key: kUS), VersionMember(key: ghost)])
        let index = LibraryIndex.build(from: [us], groups: [group])
        XCTAssertEqual(index.allAlbums.count, 1)
        XCTAssertFalse(index.allAlbums[0].isVersionGroup)
    }

    func testReleaseSortsByOriginalYear() {
        let planner = OutputPathPlanner()
        let newer = loaded(album: "Random Access Memories", format: "flac", title: "Giorgio", year: 2013)
        let cd = loaded(album: "Discovery", format: "flac", year: 2001)
        let vinyl = loaded(album: "Discovery (Vinyl)", format: "flac", year: 2016)
        let kCD = planner.albumFolderKey(for: cd)
        let kVinyl = planner.albumFolderKey(for: vinyl)
        let group = AlbumGroup(id: "g1", name: "Discovery", artistID: "daft punk",
                               originalYear: 1999, primaryKey: kCD,
                               members: [VersionMember(key: kCD), VersionMember(key: kVinyl)])
        let index = LibraryIndex.build(from: [newer, cd, vinyl], groups: [group])
        let titles = index.artists[0].albums.map(\.title)
        // Release (originalYear 1999) sorts before RAM (2013).
        XCTAssertEqual(titles, ["Discovery", "Random Access Memories"])
    }

    func testAlbumOrVersionFindsPressing() {
        let planner = OutputPathPlanner()
        let us = loaded(album: "Discovery", format: "flac")
        let jp = loaded(album: "Discovery (JP)", format: "flac")
        let kUS = planner.albumFolderKey(for: us)
        let kJP = planner.albumFolderKey(for: jp)
        let group = AlbumGroup(id: "g1", name: "Discovery", artistID: "daft punk",
                               originalYear: 1999, primaryKey: kUS,
                               members: [VersionMember(key: kUS), VersionMember(key: kJP)])
        let index = LibraryIndex.build(from: [us, jp], groups: [group])
        let release = index.allAlbums[0]
        let pressing = release.versions![0]
        XCTAssertEqual(index.albumOrVersion(id: release.id)?.id, release.id)
        XCTAssertEqual(index.albumOrVersion(id: pressing.id)?.id, pressing.id)
        XCTAssertNil(index.albumOrVersion(id: "nope"))
    }

    func testBuildEmptyReturnsEmpty() {
        let index = LibraryIndex.build(from: [])
        XCTAssertTrue(index.artists.isEmpty)
        XCTAssertEqual(index.albumCount, 0)
        XCTAssertEqual(index.totalSizeBytes, 0)
    }

    func testAllAlbumsFlattensEveryArtist() {
        let tracks: [LoadedTrack] = [
            makeTrack(file: "/m/A/One/01.flac", title: "a1", artist: "Artist A", album: "One", year: 2001, trackNumber: 1),
            makeTrack(file: "/m/A/Two/01.flac", title: "a2", artist: "Artist A", album: "Two", year: 2002, trackNumber: 1),
            makeTrack(file: "/m/B/Three/01.flac", title: "b1", artist: "Artist B", album: "Three", year: 2003, trackNumber: 1)
        ]
        let index = LibraryIndex.build(from: tracks)
        XCTAssertEqual(index.artists.count, 2)
        XCTAssertEqual(index.allAlbums.count, 3)
        XCTAssertEqual(Set(index.allAlbums.map(\.title)), ["One", "Two", "Three"])
    }

    func testGroupsTracksByArtistAndAlbum() {
        let tracks: [LoadedTrack] = [
            makeTrack(file: "/m/A/Loose Pages/02.flac", title: "Cassiopeia Drift", artist: "Maggot Brain Quartet", album: "Loose Pages", year: 1974, trackNumber: 2),
            makeTrack(file: "/m/A/Loose Pages/01.flac", title: "Distant Receiver", artist: "Maggot Brain Quartet", album: "Loose Pages", year: 1974, trackNumber: 1),
            makeTrack(file: "/m/A/Blue Room/01.flac", title: "Window Seat", artist: "Maggot Brain Quartet", album: "Blue Room Sessions", year: 1976, trackNumber: 1),
            makeTrack(file: "/m/B/Atlas/01.flac", title: "Static", artist: "Nova Atlas", album: "Atlas", year: 2020, trackNumber: 1)
        ]

        let index = LibraryIndex.build(from: tracks)

        XCTAssertEqual(index.artists.count, 2)
        XCTAssertEqual(index.albumCount, 3)
        XCTAssertEqual(index.allTracks.count, 4)

        let mbq = try! XCTUnwrap(index.artists.first { $0.name == "Maggot Brain Quartet" })
        XCTAssertEqual(mbq.albums.count, 2)
        XCTAssertEqual(mbq.albums.reduce(0) { $0 + $1.trackCount }, 3)
        // Albums sorted by year asc
        XCTAssertEqual(mbq.albums.map(\.year), [1974, 1976])
        // Tracks within Loose Pages sorted by trackNumber
        let loose = mbq.albums[0]
        XCTAssertEqual(loose.tracks.map(\.track.trackNumber), [1, 2])
    }

    func testArtistsSortedAlphabeticallyUnknownLast() {
        let tracks: [LoadedTrack] = [
            makeTrack(file: "/m/c.flac", title: "C", artist: "", album: "Album C", year: 2010, trackNumber: 1),
            makeTrack(file: "/m/a.flac", title: "A", artist: "Aurelia Vance", album: "Drift", year: 2010, trackNumber: 1),
            makeTrack(file: "/m/b.flac", title: "B", artist: "Hana Yi",       album: "Roots", year: 2018, trackNumber: 1),
            makeTrack(file: "/m/d.flac", title: "D", artist: "kepler",        album: "K-One", year: 2024, trackNumber: 1)
        ]

        let index = LibraryIndex.build(from: tracks)
        let names = index.artists.map(\.name)
        XCTAssertEqual(names, ["Aurelia Vance", "Hana Yi", "kepler", "Unknown Artist"])
    }

    func testVariousArtistsCompilationStaysOneAlbum() {
        let tracks: [LoadedTrack] = [
            makeTrack(file: "/m/va/01.flac", title: "Track 1", artist: "Alpha", albumArtist: "Various Artists", album: "Sunday Morning", year: 2024, trackNumber: 1, compilation: true),
            makeTrack(file: "/m/va/02.flac", title: "Track 2", artist: "Bravo", albumArtist: "Various Artists", album: "Sunday Morning", year: 2024, trackNumber: 2, compilation: true),
            makeTrack(file: "/m/va/03.flac", title: "Track 3", artist: "Charlie", albumArtist: "Various Artists", album: "Sunday Morning", year: 2024, trackNumber: 3, compilation: true)
        ]

        let index = LibraryIndex.build(from: tracks)
        XCTAssertEqual(index.artists.count, 1)
        let va = try! XCTUnwrap(index.artists.first)
        XCTAssertEqual(va.name, "Various Artists")
        XCTAssertEqual(va.albums.count, 1)
        XCTAssertEqual(va.albums[0].tracks.count, 3)
        XCTAssertEqual(va.albums[0].tracks.map(\.track.trackNumber), [1, 2, 3])
    }

    func testEmptyArtistAndAlbumBucketUnderUnknownDefaults() {
        let tracks: [LoadedTrack] = [
            makeTrack(file: "/m/x.flac", title: "Drift", artist: "", album: "", year: nil, trackNumber: nil)
        ]

        let index = LibraryIndex.build(from: tracks)
        XCTAssertEqual(index.artists.count, 1)
        XCTAssertEqual(index.artists[0].name, "Unknown Artist")
        XCTAssertEqual(index.artists[0].albums.count, 1)
        XCTAssertEqual(index.artists[0].albums[0].title, "Unknown Album")
        XCTAssertNil(index.artists[0].albums[0].year)
        // ID is stable and contains both artist and album components
        let albumID = index.artists[0].albums[0].id
        XCTAssertTrue(albumID.contains("unknown"))
    }

    func testDiscThenTrackThenTitleSortWithinAlbum() {
        let tracks: [LoadedTrack] = [
            makeTrack(file: "/m/2-3.flac", title: "Z", artist: "X", album: "Y", year: 2020, trackNumber: 3, discNumber: 2),
            makeTrack(file: "/m/1-1.flac", title: "B", artist: "X", album: "Y", year: 2020, trackNumber: 1, discNumber: 1),
            makeTrack(file: "/m/1-2.flac", title: "A", artist: "X", album: "Y", year: 2020, trackNumber: 2, discNumber: 1),
            makeTrack(file: "/m/2-1.flac", title: "M", artist: "X", album: "Y", year: 2020, trackNumber: 1, discNumber: 2),
            makeTrack(file: "/m/no-num.flac", title: "Aardvark", artist: "X", album: "Y", year: 2020, trackNumber: nil, discNumber: nil)
        ]

        let index = LibraryIndex.build(from: tracks)
        let titles = index.artists[0].albums[0].tracks.map(\.track.title)
        // (disc ?? 1, track ?? .max): no-num lands at disc 1 / track Int.max → end of disc 1
        XCTAssertEqual(titles, ["B", "A", "Aardvark", "M", "Z"])
    }

    func testArtworkHashPromotedFromFirstNonNilTrack() {
        let tracks: [LoadedTrack] = [
            makeTrack(file: "/m/1.flac", title: "T1", artist: "X", album: "Y", year: 2020, trackNumber: 1, artworkHash: nil),
            makeTrack(file: "/m/2.flac", title: "T2", artist: "X", album: "Y", year: 2020, trackNumber: 2, artworkHash: "HASH-2"),
            makeTrack(file: "/m/3.flac", title: "T3", artist: "X", album: "Y", year: 2020, trackNumber: 3, artworkHash: "HASH-3")
        ]

        let index = LibraryIndex.build(from: tracks)
        XCTAssertEqual(index.artists[0].albums[0].artworkHash, "HASH-2")
    }

    func testAlbumIDIsStableAcrossRebuilds() {
        let tracks: [LoadedTrack] = [
            makeTrack(file: "/m/1.flac", title: "Cassiopeia Drift", artist: "Maggot Brain Quartet", album: "Loose Pages", year: 1974, trackNumber: 2),
            makeTrack(file: "/m/2.flac", title: "Distant Receiver", artist: "Maggot Brain Quartet", album: "Loose Pages", year: 1974, trackNumber: 1)
        ]

        let firstID = LibraryIndex.build(from: tracks).artists[0].albums[0].id
        let secondID = LibraryIndex.build(from: Array(tracks.reversed())).artists[0].albums[0].id
        XCTAssertEqual(firstID, secondID)
    }

    func testAlbumBookletScanning() throws {
        let fileManager = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        // 1. Initially, no booklet
        XCTAssertNil(AlbumBooklet.scan(in: tempDir))

        // 2. Create a booklet PDF file
        let pdfURL = tempDir.appendingPathComponent("booklet.pdf")
        try "dummy-pdf-content".write(to: pdfURL, atomically: true, encoding: .utf8)

        let bookletPdf = try XCTUnwrap(AlbumBooklet.scan(in: tempDir))
        if case .pdf(let url) = bookletPdf.source {
            XCTAssertEqual(url.lastPathComponent, "booklet.pdf")
        } else {
            XCTFail("Expected PDF source")
        }

        // Remove PDF to test image scanning
        try fileManager.removeItem(at: pdfURL)

        // 3. Create an Artwork folder with sequential images
        let artworkDir = tempDir.appendingPathComponent("Artwork")
        try fileManager.createDirectory(at: artworkDir, withIntermediateDirectories: true, attributes: nil)

        let p1 = artworkDir.appendingPathComponent("page_01.jpg")
        let p2 = artworkDir.appendingPathComponent("page_02.jpg")
        try "img1".write(to: p1, atomically: true, encoding: .utf8)
        try "img2".write(to: p2, atomically: true, encoding: .utf8)

        let bookletImages = try XCTUnwrap(AlbumBooklet.scan(in: tempDir))
        if case .images(let urls) = bookletImages.source {
            XCTAssertEqual(urls.count, 2)
            XCTAssertEqual(urls[0].lastPathComponent, "page_01.jpg")
            XCTAssertEqual(urls[1].lastPathComponent, "page_02.jpg")
        } else {
            XCTFail("Expected image array source")
        }
    }

    func testAlbumBookletCategorizationAndSorting() {
        let urls = [
            URL(fileURLWithPath: "/m/Artwork/cd.jpg"),
            URL(fileURLWithPath: "/m/Artwork/back.jpg"),
            URL(fileURLWithPath: "/m/Artwork/cover.jpg"),
            URL(fileURLWithPath: "/m/Artwork/page_02.jpg"),
            URL(fileURLWithPath: "/m/Artwork/inlay.jpg"),
            URL(fileURLWithPath: "/m/Artwork/page_01.jpg"),
        ]

        let sorted = AlbumBooklet.sortAndCategorizeBookletImages(urls)
        let filenames = sorted.map(\.lastPathComponent)

        // Expected physical order (excluding disc label scans):
        // 1. cover.jpg (front)
        // 2. page_01.jpg, page_02.jpg (generic/liner notes)
        // 3. inlay.jpg (inlay)
        // 4. back.jpg (back cover)
        XCTAssertEqual(filenames, [
            "cover.jpg",
            "page_01.jpg",
            "page_02.jpg",
            "inlay.jpg",
            "back.jpg"
        ])
    }
}

private func makeTrack(
    file: String,
    title: String,
    artist: String = "",
    albumArtist: String? = nil,
    album: String = "",
    year: Int? = nil,
    trackNumber: Int? = nil,
    discNumber: Int? = nil,
    compilation: Bool? = nil,
    artworkHash: String? = nil
) -> LoadedTrack {
    let metadata = ConversionMetadata(
        title: title,
        artist: artist.isEmpty ? nil : artist,
        albumArtist: albumArtist,
        album: album.isEmpty ? nil : album,
        compilation: compilation,
        trackNumber: trackNumber,
        discNumber: discNumber,
        year: year
    )
    let track = AudioTrack(
        fileURL: URL(fileURLWithPath: file),
        title: title,
        artist: artist,
        album: album,
        year: year,
        trackNumber: trackNumber,
        discNumber: discNumber,
        artworkSource: artworkHash == nil ? .none : .embedded,
        artworkHash: artworkHash
    )
    return LoadedTrack(track: track, metadata: metadata)
}
#endif
