import XCTest
@testable import CrateDiggerCore

/// Which artists the background worker looks up, and in what order.
final class ArtistLookupSchedulerTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let day: TimeInterval = 86_400
    private let scheduler = ArtistLookupScheduler()

    private func profile(_ name: String, _ identity: ArtistProfile.Identity, checkedDaysAgo days: Double?) -> ArtistProfile {
        ArtistProfile(foldedKey: PodBoxArtName.folded(name), displayName: name, identity: identity,
                      checkedAt: days.map { now.addingTimeInterval(-$0 * day) })
    }

    private func due(_ artists: [(name: String, trackCount: Int)], _ profiles: [ArtistProfile] = [],
                     priority: [String] = []) -> [String] {
        let byKey = Dictionary(uniqueKeysWithValues: profiles.map { ($0.foldedKey, $0) })
        return scheduler.due(artists: artists, profiles: { byKey[PodBoxArtName.folded($0)] }, priority: priority,
                             now: now)
    }

    func testMostTracksFirst() {
        XCTAssertEqual(due([("Air", 12), ("Björk", 140), ("Can", 60)]), ["Björk", "Can", "Air"])
        // Two spellings of one artist are one, their tracks counted together.
        XCTAssertEqual(due([("The Beatles", 30), ("Can", 50), ("Beatles", 25)]), ["The Beatles", "Can"])
    }

    func testPriorityGoesFirst() {
        let confirmed = profile("Air", .confirmed(musicBrainzID: "a", wikidataID: nil), checkedDaysAgo: 1)
        // A fresh record is not due, except as a priority; a priority comes once.
        XCTAssertEqual(due([("Air", 12), ("Björk", 140), ("Can", 60)], [confirmed]), ["Björk", "Can"])
        XCTAssertEqual(due([("Air", 12), ("Björk", 140), ("Can", 60)], [confirmed], priority: ["Can", "Air", "air"]),
                       ["Can", "Air", "Björk"])
        // A priority name from outside the list (the iPod's now playing) is still looked up.
        XCTAssertEqual(due([("Björk", 140)], priority: ["Stereolab"]), ["Stereolab", "Björk"])
    }

    func testConfirmedRefreshAfter180Days() {
        let artists: [(name: String, trackCount: Int)] = [("Air", 1)]
        let id = ArtistProfile.Identity.confirmed(musicBrainzID: "a", wikidataID: "Q1")
        XCTAssertEqual(due(artists, [profile("Air", id, checkedDaysAgo: 179)]), [])
        XCTAssertEqual(due(artists, [profile("Air", id, checkedDaysAgo: 181)]), ["Air"])
        XCTAssertEqual(due(artists, [profile("Air", id, checkedDaysAgo: nil)]), ["Air"])
        XCTAssertEqual(ArtistLookupScheduler.confirmedRefresh, 180 * 86_400)
    }

    func testNotFoundRetryAfter30Days() {
        let artists: [(name: String, trackCount: Int)] = [("Air", 1)]
        XCTAssertEqual(due(artists, [profile("Air", .notFound, checkedDaysAgo: 29)]), [])
        XCTAssertEqual(due(artists, [profile("Air", .notFound, checkedDaysAgo: 31)]), ["Air"])
        XCTAssertEqual(ArtistLookupScheduler.notFoundRetry, 30 * 86_400)
        // Never looked up (a profile the migration or the owner made) is due.
        XCTAssertEqual(due(artists, [profile("Air", .unknown, checkedDaysAgo: nil)]), ["Air"])
        // So is an identity reset (Look Up Again, a deleted MusicBrainz id), however recent.
        XCTAssertEqual(due(artists, [profile("Air", .unknown, checkedDaysAgo: 0)]), ["Air"])
    }

    func testUncertainAndRejectedNeverAutomatic() {
        let artists: [(name: String, trackCount: Int)] = [("Boston", 9), ("Air", 3)]
        let held = [profile("Boston", .uncertain([ArtistIdentityCandidate(musicBrainzID: "b", name: "Boston")]),
                            checkedDaysAgo: 400),
                    profile("Air", .rejected, checkedDaysAgo: 400)]
        XCTAssertEqual(due(artists, held), [])
        // Not even clicked: the page asks, and "None of these" stands until Look Up Again.
        XCTAssertEqual(due(artists, held, priority: ["Boston", "Air"]), [])
    }

    func testVariousAndUnknownAreNeverLookedUp() async {
        for name in ["Various Artists", "various artists", "VA", "Unknown Artist", "[unknown]", "Unknown Album Artist",
                     "", "   ", "!!!", "—"] {
            XCTAssertFalse(ArtistLookupScheduler.isLookedUp(name), name)
        }
        XCTAssertTrue(ArtistLookupScheduler.isLookedUp("Massive Attack"))
        XCTAssertTrue(ArtistLookupScheduler.isLookedUp("Unknown Mortal Orchestra"))
        XCTAssertEqual(due([("Various Artists", 900), ("Unknown Artist", 400), ("", 50), ("Air", 1)],
                           priority: ["Various Artists", "Unknown Artist"]),
                       ["Air"])

        // The run refuses them as well, before any request.
        let fetcher = FakePictureFetcher()
        let run = ArtistLookupRun(info: ArtistInfoClient(fetcher: fetcher, gate: MusicBrainzGate(interval: .zero),
                                                         wikimediaSpacing: .zero),
                                  pictures: ArtistPictureFinder(sources: [], fetcher: fetcher), fetcher: fetcher,
                                  spacing: .zero)
        do {
            _ = try await run.lookUp(name: "Various Artists", libraryAlbumTitles: [], libraryPicture: nil,
                                     existing: nil, lane: .background, now: now)
            XCTFail("looked up Various Artists")
        } catch {
            XCTAssertEqual(error as? ArtistLookupError, .notLookedUp("Various Artists"))
        }
        XCTAssertTrue(fetcher.requests.isEmpty)
    }

    func testAnyPauseStops() {
        XCTAssertFalse(ArtistLookupPauses().isPaused)
        let each: [WritableKeyPath<ArtistLookupPauses, Bool>] = [
            \.disabled, \.scanning, \.transferring, \.hidden, \.lowPower, \.offline, \.libraryDisconnected,
        ]
        for path in each {
            var pauses = ArtistLookupPauses()
            pauses[keyPath: path] = true
            XCTAssertTrue(pauses.isPaused, "\(path)")
        }
    }
}
