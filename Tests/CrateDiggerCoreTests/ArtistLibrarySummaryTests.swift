import XCTest
@testable import CrateDiggerCore

/// What the library holds of each artist, for the artist page: nothing fetched.
final class ArtistLibrarySummaryTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
    private let day: TimeInterval = 86_400

    private func track(_ path: String, title: String, artist: String = "Air", albumArtist: String? = nil,
                       album: String = "Moon Safari", seconds: Double = 200, format: String? = "FLAC") -> LoadedTrack {
        LoadedTrack(track: AudioTrack(fileURL: URL(fileURLWithPath: path), title: title, artist: artist, album: album,
                                      durationSeconds: seconds, formatName: format),
                    metadata: ConversionMetadata(title: title, artist: artist, albumArtist: albumArtist, album: album))
    }

    /// An index by hand: one artist per entry, its albums and their tracks.
    private func index(_ artists: [(name: String, albums: [(title: String, tracks: [LoadedTrack])])]) -> LibraryIndex {
        let built = artists.map { artist in
            Artist(id: artist.name.lowercased(), name: artist.name, albums: artist.albums.map { album in
                Album(id: artist.name + "::" + album.title, artistID: artist.name.lowercased(), artistName: artist.name,
                      title: album.title, year: nil, artworkHash: nil, tracks: album.tracks)
            })
        }
        let tracks = artists.flatMap { $0.albums.flatMap(\.tracks) }
        return LibraryIndex(artists: built, allTracks: tracks, albumCount: built.reduce(0) { $0 + $1.albums.count },
                            totalSizeBytes: 0)
    }

    private func stats(_ loaded: LoadedTrack, plays: Int = 0, lastPlayed: Date? = nil,
                       added: Date) -> (String, ListeningStats) {
        (ListeningStore.key(for: loaded.track.fileURL),
         ListeningStats(playCount: plays, lastPlayed: lastPlayed, dateAdded: added))
    }

    func testCountsAndTotalTime() throws {
        let a = [track("/m/Air/Moon/1.flac", title: "La Femme", seconds: 300),
                 track("/m/Air/Moon/2.flac", title: "Sexy Boy", seconds: 299.5)]
        let b = [track("/m/Air/Talkie/1.flac", title: "Venus", album: "Talkie Walkie", seconds: 240)]
        let summary = try XCTUnwrap(ArtistLibrarySummary.all(
            index: index([("Air", [("Moon Safari", a), ("Talkie Walkie", b)])]), listening: [:], crates: [:])["air"])
        XCTAssertEqual(summary.albumCount, 2)
        XCTAssertEqual(summary.trackCount, 3)
        XCTAssertEqual(summary.totalSeconds, 839.5, accuracy: 0.001)
        XCTAssertEqual(summary.totalPlays, 0)
        XCTAssertNil(summary.lastPlayed)
        XCTAssertNil(summary.firstAdded)
        XCTAssertEqual(summary.topTracks, [])
    }

    func testDominantFormatThreshold() throws {
        func summary(flac: Int, mp3: Int) throws -> ArtistLibrarySummary {
            let tracks = (0..<flac).map { track("/m/f\($0).flac", title: "F\($0)", format: "FLAC") }
                + (0..<mp3).map { track("/m/m\($0).mp3", title: "M\($0)", format: "MP3") }
            return try XCTUnwrap(ArtistLibrarySummary.all(index: index([("Air", [("A", tracks)])]), listening: [:],
                                                          crates: [:])["air"])
        }
        let mostly = try summary(flac: 6, mp3: 4)
        XCTAssertEqual(mostly.dominantFormat, "FLAC")
        XCTAssertEqual(mostly.formatCounts.map(\.0), ["FLAC", "MP3"])
        XCTAssertEqual(mostly.formatCounts.map(\.1), [6, 4])
        let mixed = try summary(flac: 5, mp3: 4)
        XCTAssertNil(mixed.dominantFormat, "56% is not mostly")
        XCTAssertEqual(mixed.formatCounts.map(\.0), ["FLAC", "MP3"])
        // A track with no format name is known by its extension.
        let bare = try XCTUnwrap(ArtistLibrarySummary.all(
            index: index([("Air", [("A", [track("/m/x.ogg", title: "X", format: nil)])])]),
            listening: [:], crates: [:])["air"])
        XCTAssertEqual(bare.dominantFormat, "OGG")
    }

    func testDatesAddedFromListening() throws {
        let tracks = [track("/m/1.flac", title: "One"), track("/m/2.flac", title: "Two"), track("/m/3.flac", title: "Three")]
        let listening = Dictionary(uniqueKeysWithValues: [
            stats(tracks[0], added: base.addingTimeInterval(5 * day)),
            stats(tracks[1], added: base),
            stats(tracks[2], added: base.addingTimeInterval(90 * day)),
        ])
        let summary = try XCTUnwrap(ArtistLibrarySummary.all(index: index([("Air", [("A", tracks)])]),
                                                             listening: listening, crates: [:])["air"])
        XCTAssertEqual(summary.firstAdded, base)
        XCTAssertEqual(summary.latestAdded, base.addingTimeInterval(90 * day))
    }

    func testCratesListed() throws {
        let air = [track("/m/Air/1.flac", title: "One"), track("/m/Air/2.flac", title: "Two")]
        let can = [track("/m/Can/1.flac", title: "Vitamin C", artist: "Can")]
        let crates: [String: Set<String>] = [
            "Personal Crate": ["/m/Air/1.flac", "/m/Can/1.flac"],
            "Chill": ["/m/Air/2.flac"],
            "Krautrock": ["/m/Can/1.flac"],
            "Empty": [],
        ]
        let all = ArtistLibrarySummary.all(index: index([("Air", [("A", air)]), ("Can", [("Ege Bamyasi", can)])]),
                                           listening: [:], crates: crates)
        XCTAssertEqual(all["air"]?.crateNames, ["Chill", "Personal Crate"])
        XCTAssertEqual(all["can"]?.crateNames, ["Krautrock", "Personal Crate"])
    }

    func testTopTracksByPlays() throws {
        let tracks = (0..<8).map { track("/m/\($0).flac", title: "T\($0)") }
        let plays = [3, 9, 0, 3, 12, 1, 3, 2]
        var listening: [String: ListeningStats] = [:]
        for (index, loaded) in tracks.enumerated() {
            let (key, value) = stats(loaded, plays: plays[index],
                                     lastPlayed: plays[index] > 0 ? base.addingTimeInterval(Double(index) * day) : nil,
                                     added: base)
            listening[key] = value
        }
        let summary = try XCTUnwrap(ArtistLibrarySummary.all(index: index([("Air", [("A", tracks)])]),
                                                             listening: listening, crates: [:])["air"])
        // 12, 9, then the three 3s by last played (6 is the latest), five in all.
        XCTAssertEqual(summary.topTracks, [4, 1, 6, 3, 0].map { tracks[$0].track.id })
        XCTAssertEqual(summary.totalPlays, plays.reduce(0, +))
        XCTAssertEqual(summary.lastPlayed, base.addingTimeInterval(7 * day))
    }

    func testCompilationGroupsByAlbumArtist() throws {
        let tracks = [
            track("/m/Comp/1.flac", title: "One", artist: "Air", albumArtist: "Various Artists", album: "Late Night"),
            track("/m/Comp/2.flac", title: "Two", artist: "Can", albumArtist: "Various Artists", album: "Late Night"),
            track("/m/MA/1.flac", title: "Teardrop", artist: "Massive Attack feat. Elizabeth Fraser",
                  albumArtist: "Massive Attack", album: "Mezzanine"),
            track("/m/MA/2.flac", title: "Angel", artist: "Massive Attack", albumArtist: "Massive Attack",
                  album: "Mezzanine"),
        ]
        let all = ArtistLibrarySummary.all(index: LibraryIndex.build(from: tracks), listening: [:], crates: [:])
        XCTAssertEqual(all["variousartists"]?.trackCount, 2)
        XCTAssertNil(all["air"])
        XCTAssertNil(all["can"])
        XCTAssertEqual(all["massiveattack"]?.trackCount, 2)
        XCTAssertEqual(all["massiveattack"]?.albumCount, 1)
        XCTAssertNil(all[PodBoxArtName.folded("Massive Attack feat. Elizabeth Fraser")])
    }

    func testSpellingsThatFoldAlikeAreOneArtist() throws {
        let all = ArtistLibrarySummary.all(
            index: index([("The Beatles", [("Revolver", [track("/m/b1.flac", title: "Taxman")])]),
                          ("Beatles", [("Help!", [track("/m/b2.flac", title: "Help!")])])]),
            listening: [:], crates: [:])
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all["beatles"]?.albumCount, 2)
        XCTAssertEqual(all["beatles"]?.trackCount, 2)
    }

    func testSummaryForFourteenThousandTracksUnder100ms() {
        var artists: [(name: String, albums: [(title: String, tracks: [LoadedTrack])])] = []
        var listening: [String: ListeningStats] = [:]
        var crate: Set<String> = []
        for a in 0..<1_400 {
            var albums: [(title: String, tracks: [LoadedTrack])] = []
            for b in 0..<2 {
                let tracks = (0..<5).map { t -> LoadedTrack in
                    let path = "/Volumes/Music/Artist \(a)/Album \(b)/\(t).flac"
                    return track(path, title: "Track \(t)", artist: "Artist \(a)", album: "Album \(b)",
                                 format: t % 3 == 0 ? "MP3" : "FLAC")
                }
                for (t, loaded) in tracks.enumerated() {
                    let (key, value) = stats(loaded, plays: (a + t) % 7, lastPlayed: base, added: base)
                    listening[key] = value
                    if t == 0 { crate.insert(key) }
                }
                albums.append(("Album \(b)", tracks))
            }
            artists.append(("Artist \(a)", albums))
        }
        let library = index(artists)
        XCTAssertEqual(library.allTracks.count, 14_000)
        let crates = ["Personal Crate": crate, "Everything": Set(listening.keys)]

        _ = ArtistLibrarySummary.all(index: library, listening: listening, crates: crates) // warm up
        let clock = ContinuousClock()
        var result: [String: ArtistLibrarySummary] = [:]
        let elapsed = clock.measure {
            result = ArtistLibrarySummary.all(index: library, listening: listening, crates: crates)
        }
        XCTAssertEqual(result.count, 1_400)
        XCTAssertEqual(result["artist7"]?.crateNames, ["Everything", "Personal Crate"])
        XCTAssertLessThan(elapsed, .milliseconds(100), "took \(elapsed)")
    }
}
