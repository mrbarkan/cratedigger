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

    func testDecodingClampsOutOfRangeRatings() throws {
        // Rating above 5 should be clamped to 5
        let aboveRangeJSON = #"{"playCount": 0, "skipCount": 0, "lastPlayed": null, "dateAdded": 1700000000.0, "rating": 9}"#
        let statsAbove = try JSONDecoder().decode(ListeningStats.self, from: aboveRangeJSON.data(using: .utf8)!)
        XCTAssertEqual(statsAbove.rating, 5, "rating 9 should be clamped to 5 on decode")

        // Rating below 0 should be clamped to 0
        let belowRangeJSON = #"{"playCount": 0, "skipCount": 0, "lastPlayed": null, "dateAdded": 1700000000.0, "rating": -3}"#
        let statsBelow = try JSONDecoder().decode(ListeningStats.self, from: belowRangeJSON.data(using: .utf8)!)
        XCTAssertEqual(statsBelow.rating, 0, "rating -3 should be clamped to 0 on decode")
    }
}

final class ListeningStorePersistenceTests: XCTestCase {

    private var folder: URL!
    private var fileURL: URL!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdplays-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("library.cdplays")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private let trackA = URL(fileURLWithPath: "/Music/A/01.flac")
    private let trackB = URL(fileURLWithPath: "/Music/B/02.flac")

    func testAPlaySurvivesAReload() throws {
        let store = ListeningStore(fileURL: fileURL)
        store.recordPlay(path: ListeningStore.key(for: trackA), at: now)
        try store.save()

        let reopened = ListeningStore(fileURL: fileURL)
        let stats = try XCTUnwrap(reopened.stats(path: ListeningStore.key(for: trackA)))
        XCTAssertEqual(stats.playCount, 1)
        XCTAssertEqual(stats.lastPlayed, now)
    }

    func testUnchangedStoreReSerializesToIdenticalBytes() throws {
        let store = ListeningStore(fileURL: fileURL)
        store.recordPlay(path: ListeningStore.key(for: trackB), at: now)
        store.recordPlay(path: ListeningStore.key(for: trackA), at: now)
        try store.save()
        let first = try Data(contentsOf: fileURL)

        // Reload and save again with no edits: backup dedup depends on this.
        let reopened = ListeningStore(fileURL: fileURL)
        reopened.setRating(3, path: ListeningStore.key(for: trackA))
        reopened.setRating(0, path: ListeningStore.key(for: trackA))
        try reopened.save()
        XCTAssertEqual(try Data(contentsOf: fileURL), first)
    }

    func testSavingWithNothingToWriteDoesNotTouchTheFile() throws {
        let store = ListeningStore(fileURL: fileURL)
        store.recordPlay(path: ListeningStore.key(for: trackA), at: now)
        try store.save()
        let stamp = try FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date

        let reopened = ListeningStore(fileURL: fileURL)
        try reopened.save()
        let after = try FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        XCTAssertEqual(stamp, after)
    }

    func testRepointCarriesStatsToTheNewPath() throws {
        let store = ListeningStore(fileURL: fileURL)
        let old = ListeningStore.key(for: trackA)
        let new = ListeningStore.key(for: trackB)
        store.recordPlay(path: old, at: now)
        store.setRating(5, path: old)

        store.repoint(from: old, to: new)

        XCTAssertNil(store.stats(path: old))
        let moved = try XCTUnwrap(store.stats(path: new))
        XCTAssertEqual(moved.playCount, 1)
        XCTAssertEqual(moved.rating, 5)
    }

    func testRepointOntoAnExistingRowKeepsTheRicherHistory() throws {
        let store = ListeningStore(fileURL: fileURL)
        let old = ListeningStore.key(for: trackA)
        let new = ListeningStore.key(for: trackB)
        store.recordPlay(path: old, at: now)
        store.recordPlay(path: old, at: now)
        store.recordPlay(path: new, at: now)

        store.repoint(from: old, to: new)

        // Two plays beat one: a move must never lose history to a stale row.
        XCTAssertEqual(store.stats(path: new)?.playCount, 2)
    }

    func testRemoveDropsARowForgotten() throws {
        let store = ListeningStore(fileURL: fileURL)
        store.recordPlay(path: ListeningStore.key(for: trackA), at: now)
        store.recordPlay(path: ListeningStore.key(for: trackB), at: now)

        store.remove(path: ListeningStore.key(for: trackB))

        XCTAssertEqual(store.count, 1)
        XCTAssertNotNil(store.stats(path: ListeningStore.key(for: trackA)))
        XCTAssertNil(store.stats(path: ListeningStore.key(for: trackB)))
    }

    func testBackfillStampsOnlyPathsWithNoRowYet() throws {
        let store = ListeningStore(fileURL: fileURL)
        let a = ListeningStore.key(for: trackA)
        let b = ListeningStore.key(for: trackB)
        store.recordPlay(path: a, at: now)
        let existingAdded = try XCTUnwrap(store.stats(path: a)).dateAdded

        let backfillDate = Date(timeIntervalSince1970: 1_600_000_000)
        store.backfill(paths: [a, b], dateAdded: backfillDate)

        XCTAssertEqual(store.stats(path: a)?.dateAdded, existingAdded, "must not rewrite a known row")
        XCTAssertEqual(store.stats(path: b)?.dateAdded, backfillDate)
        XCTAssertEqual(store.stats(path: b)?.playCount, 0)
    }

    func testAnUnreadableFileIsNotOverwritten() throws {
        try Data("this is not json".utf8).write(to: fileURL)
        let store = ListeningStore(fileURL: fileURL)
        store.recordPlay(path: ListeningStore.key(for: trackA), at: now)

        XCTAssertThrowsError(try store.save())
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("this is not json".utf8))
    }
}
#endif
