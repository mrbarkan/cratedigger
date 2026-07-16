import XCTest
@testable import CrateDiggerCore

final class StringSimilarityTests: XCTestCase {
    func testIdenticalStringsScoreOne() {
        XCTAssertEqual(StringSimilarity.score("Blue Monday", "Blue Monday"), 1.0, accuracy: 0.001)
    }

    func testCaseAndPunctuationAreIgnored() {
        XCTAssertEqual(StringSimilarity.score("Power, Corruption & Lies", "power corruption and lies"), 1.0, accuracy: 0.05)
    }

    func testLeadingArticleIsIgnored() {
        XCTAssertGreaterThan(StringSimilarity.score("The Beatles", "Beatles"), 0.95)
    }

    func testTypoStillScoresHigh() {
        XCTAssertGreaterThan(StringSimilarity.score("Unknown Pleasures", "Unkown Pleasures"), 0.85)
    }

    func testUnrelatedStringsScoreLow() {
        XCTAssertLessThan(StringSimilarity.score("Blue Monday", "Enter Sandman"), 0.4)
    }

    func testEmptyStringsAreNotAMatch() {
        XCTAssertEqual(StringSimilarity.score("", "anything"), 0.0)
    }
}

final class ReleaseScorerTests: XCTestCase {

    private func candidate(
        title: String = "Power, Corruption & Lies",
        artist: String = "New Order",
        year: Int? = 1983,
        genre: String? = "Post-Punk",
        totalTracks: Int? = 3,
        tracks: [ReleaseTrack]? = nil
    ) -> ReleaseCandidate {
        ReleaseCandidate(
            source: .musicBrainz,
            providerID: "mbid-1",
            title: title,
            artist: artist,
            year: year,
            genre: genre,
            totalTracks: totalTracks,
            totalDiscs: 1,
            tracks: tracks ?? [
                ReleaseTrack(position: 1, title: "Age of Consent", durationSeconds: 305),
                ReleaseTrack(position: 2, title: "We All Stand", durationSeconds: 315),
                ReleaseTrack(position: 3, title: "The Village", durationSeconds: 250)
            ]
        )
    }

    private func query(
        artist: String? = "New Order",
        album: String? = "Power, Corruption & Lies",
        tracks: [QueryTrack]? = nil
    ) -> ReleaseQuery {
        ReleaseQuery(
            artist: artist,
            album: album,
            tracks: tracks ?? [
                QueryTrack(title: "Age of Consent", trackNumber: 1, durationSeconds: 305),
                QueryTrack(title: "We All Stand", trackNumber: 2, durationSeconds: 315),
                QueryTrack(title: "The Village", trackNumber: 3, durationSeconds: 250)
            ]
        )
    }

    // MARK: - Scoring

    func testExactReleaseScoresNearOne() {
        XCTAssertGreaterThan(ReleaseScorer.score(candidate(), against: query()), 0.95)
    }

    /// A wrong artist must lose to the right one, but shouldn't be *disqualified*
    /// on its own: when the album, every track title, and every runtime agree,
    /// the likeliest story is a mistagged artist on the right release — which is
    /// precisely what FIX TAGS is for. Ranking is what has to be right here.
    func testWrongArtistRanksBelowRightArtist() {
        XCTAssertLessThan(
            ReleaseScorer.score(candidate(artist: "Depeche Mode"), against: query()),
            ReleaseScorer.score(candidate(), against: query())
        )
    }

    func testWrongAlbumRanksBelowRightAlbum() {
        XCTAssertLessThan(
            ReleaseScorer.score(candidate(title: "Technique"), against: query()),
            ReleaseScorer.score(candidate(), against: query())
        )
    }

    /// The disqualifying case: nothing lines up. This must fall under the bar
    /// so the user is told "no match" instead of being offered garbage.
    func testUnrelatedReleaseFallsBelowMinimumScore() {
        let unrelated = ReleaseCandidate(
            source: .iTunes,
            providerID: "x",
            title: "Enter the Wu-Tang (36 Chambers)",
            artist: "Wu-Tang Clan",
            year: 1993,
            totalTracks: 12,
            tracks: (1...12).map { ReleaseTrack(position: $0, title: "Chamber \($0)", durationSeconds: 180) }
        )
        XCTAssertLessThan(ReleaseScorer.score(unrelated, against: query()), MetadataMatchService.minimumScore)
    }

    func testTrackCountMismatchLowersScore() {
        let wrongCount = candidate(
            totalTracks: 12,
            tracks: (1...12).map { ReleaseTrack(position: $0, title: "Track \($0)", durationSeconds: 200) }
        )
        XCTAssertLessThan(
            ReleaseScorer.score(wrongCount, against: query()),
            ReleaseScorer.score(candidate(), against: query())
        )
    }

    func testDurationAgreementRaisesScoreOverADisagreeingRelease() {
        // Same names, wildly different runtimes: a different edition/rip.
        let wrongDurations = candidate(tracks: [
            ReleaseTrack(position: 1, title: "Age of Consent", durationSeconds: 90),
            ReleaseTrack(position: 2, title: "We All Stand", durationSeconds: 95),
            ReleaseTrack(position: 3, title: "The Village", durationSeconds: 88)
        ])
        XCTAssertLessThan(
            ReleaseScorer.score(wrongDurations, against: query()),
            ReleaseScorer.score(candidate(), against: query())
        )
    }

    func testScoresWithoutAlbumInQuery() {
        // Untagged album name: the remaining signals must still produce a score.
        let score = ReleaseScorer.score(candidate(), against: query(album: nil))
        XCTAssertGreaterThan(score, 0.6)
        XCTAssertLessThanOrEqual(score, 1.0)
    }

    // MARK: - Track mapping

    private func loaded(
        title: String,
        trackNumber: Int?,
        duration: Double = 300,
        metadata: ((inout ConversionMetadata) -> Void)? = nil
    ) -> LoadedTrack {
        let url = URL(fileURLWithPath: "/Music/Album/\(title).flac")
        let track = AudioTrack(
            fileURL: url,
            title: title,
            durationSeconds: duration,
            trackNumber: trackNumber
        )
        var tags = ConversionMetadata()
        tags.title = title
        tags.trackNumber = trackNumber
        metadata?(&tags)
        return LoadedTrack(track: track, metadata: tags)
    }

    func testMapsTracksByNumberWhenPresent() {
        let tracks = [
            loaded(title: "wrong name c", trackNumber: 3),
            loaded(title: "wrong name a", trackNumber: 1)
        ]
        let proposals = ReleaseScorer.proposals(from: candidate(), for: tracks)

        // Track numbers win over (garbage) titles.
        XCTAssertEqual(proposals[0].proposed.title, "The Village")
        XCTAssertEqual(proposals[1].proposed.title, "Age of Consent")
    }

    func testMapsTracksByTitleWhenNumbersAreMissing() {
        let tracks = [
            loaded(title: "The Village", trackNumber: nil),
            loaded(title: "Age of Consent", trackNumber: nil)
        ]
        let proposals = ReleaseScorer.proposals(from: candidate(), for: tracks)

        XCTAssertEqual(proposals[0].proposed.trackNumber, 3)
        XCTAssertEqual(proposals[1].proposed.trackNumber, 1)
    }

    func testFallsBackToPositionWhenNothingElseMatches() {
        let tracks = [
            loaded(title: "zzz", trackNumber: nil),
            loaded(title: "qqq", trackNumber: nil)
        ]
        let proposals = ReleaseScorer.proposals(from: candidate(), for: tracks)
        XCTAssertEqual(proposals[0].proposed.trackNumber, 1)
        XCTAssertEqual(proposals[1].proposed.trackNumber, 2)
    }

    func testEachReleaseTrackIsUsedAtMostOnce() {
        // Two files with the same title must not both claim track 1.
        let tracks = [
            loaded(title: "Age of Consent", trackNumber: nil),
            loaded(title: "Age of Consent", trackNumber: nil)
        ]
        let proposals = ReleaseScorer.proposals(from: candidate(), for: tracks)
        let numbers = proposals.compactMap { $0.proposed.trackNumber }
        XCTAssertEqual(Set(numbers).count, numbers.count, "a release track was proposed twice")
    }

    // MARK: - Proposals

    func testProposalFillsEveryFieldFromTheRelease() {
        let proposals = ReleaseScorer.proposals(from: candidate(), for: [loaded(title: "Age of Consent", trackNumber: 1)])
        let proposed = proposals[0].proposed

        XCTAssertEqual(proposed.title, "Age of Consent")
        XCTAssertEqual(proposed.artist, "New Order")
        XCTAssertEqual(proposed.albumArtist, "New Order")
        XCTAssertEqual(proposed.album, "Power, Corruption & Lies")
        XCTAssertEqual(proposed.trackNumber, 1)
        XCTAssertEqual(proposed.trackTotal, 3)
        XCTAssertEqual(proposed.year, 1983)
        XCTAssertEqual(proposed.genre, "Post-Punk")
    }

    func testSingleDiscReleaseLeavesDiscTagsAlone() {
        // "Disc 1 of 1" on an ordinary album is noise, not a fix.
        let proposals = ReleaseScorer.proposals(from: candidate(), for: [loaded(title: "Age of Consent", trackNumber: 1)])
        XCTAssertNil(proposals[0].proposed.discNumber)
        XCTAssertNil(proposals[0].proposed.discTotal)
        XCTAssertFalse(proposals[0].changedFields.contains(.discNumber))
    }

    func testMultiDiscReleaseProposesDiscNumbers() {
        let doubleAlbum = ReleaseCandidate(
            source: .musicBrainz,
            providerID: "mbid-2",
            title: "1989",
            artist: "New Order",
            totalTracks: 2,
            totalDiscs: 2,
            tracks: [
                ReleaseTrack(position: 1, discNumber: 1, title: "Side One", durationSeconds: 300),
                ReleaseTrack(position: 1, discNumber: 2, title: "Side Two", durationSeconds: 300)
            ]
        )
        let proposals = ReleaseScorer.proposals(from: doubleAlbum, for: [loaded(title: "Side Two", trackNumber: nil)])

        XCTAssertEqual(proposals[0].proposed.discNumber, 2)
        XCTAssertEqual(proposals[0].proposed.discTotal, 2)
    }

    func testExistingDiscNumberIsStillCorrected() {
        // The file claims a disc, so keeping it right matters even on a single-disc release.
        let track = loaded(title: "Age of Consent", trackNumber: 1) { $0.discNumber = 3 }
        let proposals = ReleaseScorer.proposals(from: candidate(), for: [track])
        XCTAssertEqual(proposals[0].proposed.discNumber, 1)
    }

    func testChangedFieldsOnlyListsActualDifferences() {
        // Title + number already correct; everything else is new.
        let proposals = ReleaseScorer.proposals(from: candidate(), for: [loaded(title: "Age of Consent", trackNumber: 1)])
        let changed = proposals[0].changedFields

        XCTAssertFalse(changed.contains(.title), "title already matches; must not be listed as a change")
        XCTAssertFalse(changed.contains(.trackNumber))
        XCTAssertTrue(changed.contains(.album))
        XCTAssertTrue(changed.contains(.year))
    }

    func testProposalPreservesFieldsTheReleaseKnowsNothingAbout() {
        // A release with no genre/year must not blank out what the file has.
        let sparse = candidate(year: nil, genre: nil)
        let track = loaded(title: "Age of Consent", trackNumber: 1) { tags in
            tags.genre = "Synth-pop"
            tags.year = 1983
            tags.comment = "ripped from vinyl"
        }

        let proposals = ReleaseScorer.proposals(from: sparse, for: [track])

        XCTAssertEqual(proposals[0].proposed.genre, "Synth-pop")
        XCTAssertEqual(proposals[0].proposed.year, 1983)
        XCTAssertEqual(proposals[0].proposed.comment, "ripped from vinyl", "untouched fields must survive")
        XCTAssertFalse(proposals[0].changedFields.contains(.genre))
    }
}
