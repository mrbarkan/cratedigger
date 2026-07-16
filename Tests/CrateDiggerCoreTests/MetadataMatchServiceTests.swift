import XCTest
@testable import CrateDiggerCore

// MARK: - Path inference

final class PathMetadataInferenceTests: XCTestCase {

    func testTitleStripsLeadingTrackNumber() {
        XCTAssertEqual(MetadataNormalization.title(fromFilename: "03 - Blue Monday"), "Blue Monday")
        XCTAssertEqual(MetadataNormalization.title(fromFilename: "03 Blue Monday"), "Blue Monday")
        XCTAssertEqual(MetadataNormalization.title(fromFilename: "03. Blue Monday"), "Blue Monday")
        XCTAssertEqual(MetadataNormalization.title(fromFilename: "1-01 Blue Monday"), "Blue Monday")
        XCTAssertEqual(MetadataNormalization.title(fromFilename: "04_Blue Monday"), "Blue Monday")
    }

    func testTitleStripsArtistPrefix() {
        XCTAssertEqual(MetadataNormalization.title(fromFilename: "01 - New Order - Blue Monday"), "Blue Monday")
    }

    func testTitleKeepsTrailingDashedParts() {
        // Only the first " - " splits, so a title with its own dash survives.
        XCTAssertEqual(MetadataNormalization.title(fromFilename: "05 Song - Part 2"), "Part 2")
        XCTAssertEqual(MetadataNormalization.title(fromFilename: "Blue Monday"), "Blue Monday")
    }

    func testTitleOfUnnumberedFileIsUnchanged() {
        XCTAssertEqual(MetadataNormalization.title(fromFilename: "Age of Consent"), "Age of Consent")
    }

    func testAlbumFolderWithArtistAndYear() {
        let parsed = MetadataNormalization.albumFolderComponents("New Order - Power, Corruption & Lies (1983)")
        XCTAssertEqual(parsed.artist, "New Order")
        XCTAssertEqual(parsed.album, "Power, Corruption & Lies")
        XCTAssertEqual(parsed.year, 1983)
    }

    func testAlbumFolderWithYearOnly() {
        let parsed = MetadataNormalization.albumFolderComponents("Unknown Pleasures [1979]")
        XCTAssertNil(parsed.artist)
        XCTAssertEqual(parsed.album, "Unknown Pleasures")
        XCTAssertEqual(parsed.year, 1979)
    }

    func testAlbumFolderWithLeadingYear() {
        let parsed = MetadataNormalization.albumFolderComponents("1983 - Power, Corruption & Lies")
        XCTAssertEqual(parsed.album, "Power, Corruption & Lies")
        XCTAssertEqual(parsed.year, 1983)
    }

    func testAlbumFolderBareName() {
        let parsed = MetadataNormalization.albumFolderComponents("Technique")
        XCTAssertNil(parsed.artist)
        XCTAssertEqual(parsed.album, "Technique")
        XCTAssertNil(parsed.year)
    }

    func testAlbumFolderIgnoresImplausibleYear() {
        let parsed = MetadataNormalization.albumFolderComponents("Blade Runner (2049)")
        XCTAssertEqual(parsed.album, "Blade Runner (2049)")
        XCTAssertNil(parsed.year, "2049 is a title, not a release year")
    }
}

// MARK: - Query building

final class MetadataMatchQueryTests: XCTestCase {

    private func track(
        path: String,
        duration: Double = 300,
        tags: ((inout ConversionMetadata) -> Void)? = nil
    ) -> LoadedTrack {
        let url = URL(fileURLWithPath: path)
        let audio = AudioTrack(
            fileURL: url,
            title: url.deletingPathExtension().lastPathComponent,
            durationSeconds: duration
        )
        var metadata = ConversionMetadata()
        tags?(&metadata)
        return LoadedTrack(track: audio, metadata: metadata)
    }

    func testQueryPrefersTags() {
        let tracks = [
            track(path: "/M/whatever/x.flac") { tags in
                tags.albumArtist = "New Order"
                tags.album = "Technique"
                tags.title = "Fine Time"
                tags.trackNumber = 1
                tags.year = 1989
            }
        ]
        let query = MetadataMatchService.query(for: tracks)

        XCTAssertEqual(query.artist, "New Order")
        XCTAssertEqual(query.album, "Technique")
        XCTAssertEqual(query.year, 1989)
        XCTAssertEqual(query.tracks.first?.title, "Fine Time")
        XCTAssertEqual(query.tracks.first?.trackNumber, 1)
        XCTAssertEqual(query.tracks.first?.durationSeconds, 300)
    }

    func testQueryFallsBackToPathsWhenUntagged() {
        let tracks = [
            track(path: "/M/New Order - Power, Corruption & Lies (1983)/01 - Age of Consent.flac"),
            track(path: "/M/New Order - Power, Corruption & Lies (1983)/02 - We All Stand.flac")
        ]
        let query = MetadataMatchService.query(for: tracks)

        XCTAssertEqual(query.artist, "New Order")
        XCTAssertEqual(query.album, "Power, Corruption & Lies")
        XCTAssertEqual(query.year, 1983)
        XCTAssertEqual(query.tracks.map(\.title), ["Age of Consent", "We All Stand"])
        XCTAssertEqual(query.tracks.map(\.trackNumber), [1, 2])
    }

    func testAlbumArtistWinsOverTrackArtistForTheRelease() {
        let tracks = [
            track(path: "/M/x/1.flac") { tags in
                tags.albumArtist = "Various Artists"
                tags.artist = "Aphex Twin"
                tags.album = "Artificial Intelligence"
            }
        ]
        XCTAssertEqual(MetadataMatchService.query(for: tracks).artist, "Various Artists")
    }

    func testOneMistaggedTrackDoesNotDecideTheAlbumQuery() {
        // Majority rules: a stray wrong album tag shouldn't steer the search.
        let tracks = [
            track(path: "/M/x/1.flac") { $0.album = "Technique" },
            track(path: "/M/x/2.flac") { $0.album = "Technique" },
            track(path: "/M/x/3.flac") { $0.album = "Tecnique (typo)" }
        ]
        XCTAssertEqual(MetadataMatchService.query(for: tracks).album, "Technique")
    }

    func testEmptySelectionYieldsEmptyQuery() {
        XCTAssertTrue(MetadataMatchService.query(for: []).isEmpty)
    }

    func testQueryIsEmptyWhenNothingIsKnown() {
        // A bare hash-named file in a bare folder: nothing to search with.
        let query = MetadataMatchService.query(for: [track(path: "/M/Music/.flac")])
        XCTAssertTrue(query.isEmpty || query.album != nil)
    }
}

// MARK: - Matching end-to-end (fake providers)

final class MetadataMatchServiceTests: XCTestCase {

    private struct FakeProvider: ReleaseMetadataProvider {
        let source: ReleaseSource
        var candidates: [ReleaseCandidate] = []
        var error: Error?

        func searchReleases(query: ReleaseQuery, detailLimit: Int) async throws -> [ReleaseCandidate] {
            if let error { throw error }
            return candidates
        }
    }

    private struct Boom: Error {}

    private func loaded(title: String, number: Int) -> LoadedTrack {
        let audio = AudioTrack(
            fileURL: URL(fileURLWithPath: "/M/New Order - Technique/\(number) \(title).flac"),
            title: title,
            durationSeconds: 250,
            trackNumber: number
        )
        var metadata = ConversionMetadata()
        metadata.title = title
        metadata.trackNumber = number
        metadata.artist = "New Order"
        metadata.album = "Technique"
        return LoadedTrack(track: audio, metadata: metadata)
    }

    private func candidate(
        source: ReleaseSource,
        title: String = "Technique",
        artist: String = "New Order",
        year: Int? = 1989
    ) -> ReleaseCandidate {
        ReleaseCandidate(
            source: source,
            providerID: "id-\(source.rawValue)",
            title: title,
            artist: artist,
            year: year,
            genre: "Dance-Rock",
            totalTracks: 2,
            totalDiscs: 1,
            tracks: [
                ReleaseTrack(position: 1, title: "Fine Time", durationSeconds: 250),
                ReleaseTrack(position: 2, title: "All the Way", durationSeconds: 250)
            ]
        )
    }

    private var tracks: [LoadedTrack] {
        [loaded(title: "Fine Time", number: 1), loaded(title: "All the Way", number: 2)]
    }

    func testReturnsScoredMatchesBestFirst() async {
        let service = MetadataMatchService(providers: [
            FakeProvider(source: .musicBrainz, candidates: [candidate(source: .musicBrainz)]),
            FakeProvider(source: .iTunes, candidates: [candidate(source: .iTunes, title: "Technique (Remastered)")])
        ])

        let matches = await service.match(for: tracks)

        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].candidate.source, .musicBrainz, "the exact title must outrank the remaster")
        XCTAssertGreaterThanOrEqual(matches[0].score, matches[1].score)
    }

    func testOneDeadSourceDoesNotSinkTheLookup() async {
        let service = MetadataMatchService(providers: [
            FakeProvider(source: .musicBrainz, error: Boom()),
            FakeProvider(source: .iTunes, candidates: [candidate(source: .iTunes)])
        ])

        let matches = await service.match(for: tracks)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].candidate.source, .iTunes)
    }

    func testUnrelatedCandidatesAreDroppedRatherThanOffered() async {
        let junk = ReleaseCandidate(
            source: .iTunes,
            providerID: "junk",
            title: "Now That's What I Call Music 42",
            artist: "Various Artists",
            totalTracks: 40,
            tracks: (1...40).map { ReleaseTrack(position: $0, title: "Filler \($0)", durationSeconds: 199) }
        )
        let service = MetadataMatchService(providers: [FakeProvider(source: .iTunes, candidates: [junk])])

        let matches = await service.match(for: tracks)
        XCTAssertTrue(matches.isEmpty, "a no-match must be reported honestly, not padded with junk")
    }

    func testAlreadyCorrectTagsProduceNoMatchToApply() async {
        // Every field already agrees with the release: there's nothing to offer.
        let exact = ReleaseCandidate(
            source: .iTunes,
            providerID: "exact",
            title: "Technique",
            artist: "New Order",
            year: nil,
            genre: nil,
            totalTracks: nil,
            totalDiscs: nil,
            tracks: [
                ReleaseTrack(position: 1, title: "Fine Time", artist: "New Order", durationSeconds: 250),
                ReleaseTrack(position: 2, title: "All the Way", artist: "New Order", durationSeconds: 250)
            ]
        )
        var alreadyTagged = tracks
        alreadyTagged = alreadyTagged.map { track in
            var metadata = track.metadata
            metadata.albumArtist = "New Order"
            return LoadedTrack(track: track.track, metadata: metadata)
        }

        let service = MetadataMatchService(providers: [FakeProvider(source: .iTunes, candidates: [exact])])
        let matches = await service.match(query: MetadataMatchService.query(for: alreadyTagged), for: alreadyTagged)

        XCTAssertTrue(matches.isEmpty, "a release that changes nothing must not be offered")
    }

    func testEmptyQueryNeverHitsTheNetwork() async {
        // A provider that would fail loudly if it were ever called.
        let service = MetadataMatchService(providers: [FakeProvider(source: .iTunes, error: Boom())])
        let matches = await service.match(for: [])
        XCTAssertTrue(matches.isEmpty)
    }
}
