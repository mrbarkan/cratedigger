#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class ListeningStatsTests: XCTestCase {

    private let added = Date(timeIntervalSince1970: 1_700_000_000)

    func testANewTrackHasNoHistoryButKnowsWhenItArrived() {
        let stats = ListeningStats(dateAdded: added)
        XCTAssertEqual(stats.playCount, 0)
        XCTAssertEqual(stats.skipCount, 0)
        XCTAssertNil(stats.lastPlayed)
        XCTAssertEqual(stats.dateAdded, added)
        XCTAssertEqual(stats.rating, 0)
        XCTAssertFalse(stats.isRated, "0 means unrated, not rated zero")
    }

    func testRecordingAPlayCountsItAndStampsTheDate() {
        var stats = ListeningStats(dateAdded: added)
        let when = Date(timeIntervalSince1970: 1_700_000_500)
        stats.recordPlay(at: when)
        XCTAssertEqual(stats.playCount, 1)
        XCTAssertEqual(stats.lastPlayed, when)
        stats.recordPlay(at: when.addingTimeInterval(60))
        XCTAssertEqual(stats.playCount, 2)
    }

    func testASkipDoesNotCountAsAPlayAndDoesNotStampLastPlayed() {
        var stats = ListeningStats(dateAdded: added)
        stats.recordSkip()
        XCTAssertEqual(stats.skipCount, 1)
        XCTAssertEqual(stats.playCount, 0)
        XCTAssertNil(stats.lastPlayed, "you did not listen to it")
    }

    func testRatingIsClampedToTheFiveStarsTheUICanShow() {
        var stats = ListeningStats(dateAdded: added)
        stats.rating = 9
        XCTAssertEqual(stats.rating, 5)
        stats.rating = -3
        XCTAssertEqual(stats.rating, 0)
        stats.rating = 4
        XCTAssertTrue(stats.isRated)
    }

    func testRoundTripsThroughJSON() throws {
        var stats = ListeningStats(dateAdded: added)
        stats.recordPlay(at: added)
        stats.rating = 3
        let data = try JSONEncoder().encode(stats)
        XCTAssertEqual(try JSONDecoder().decode(ListeningStats.self, from: data), stats)
    }
}
#endif
