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
    private let trackC = URL(fileURLWithPath: "/Music/C/03.flac")

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

        // Written out of insertion order (B then A), so this only holds if
        // .sortedKeys is actually doing something: without it, same-process
        // Dictionary iteration order happens to be stable and this assertion
        // would pass by accident. Match on the filename rather than the full
        // path: JSONEncoder escapes "/" as "\/", so the raw path string is
        // never a literal substring of the encoded text.
        let text = try XCTUnwrap(String(data: first, encoding: .utf8))
        let aRange = try XCTUnwrap(text.range(of: trackA.lastPathComponent))
        let bRange = try XCTUnwrap(text.range(of: trackB.lastPathComponent))
        XCTAssertLessThan(aRange.lowerBound, bRange.lowerBound, "sortedKeys must place the A path before the B path")

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

    func testRepointOnATieMergesRatingAndSkipInsteadOfDroppingOne() throws {
        let store = ListeningStore(fileURL: fileURL)
        let old = ListeningStore.key(for: trackA)
        let new = ListeningStore.key(for: trackB)
        let earlier = Date(timeIntervalSince1970: 1_600_000_000)
        let later = Date(timeIntervalSince1970: 1_650_000_000)

        // Moving row: rated, never played, added earlier.
        store.statsOrCreate(path: old, now: earlier)
        store.setRating(4, path: old)

        // Destination row: skipped once, never played, added later.
        store.statsOrCreate(path: new, now: later)
        store.recordSkip(path: new)

        store.repoint(from: old, to: new)

        let merged = try XCTUnwrap(store.stats(path: new))
        XCTAssertEqual(merged.playCount, 0)
        XCTAssertEqual(merged.rating, 4, "the moving row's rating must not be dropped on a tie")
        XCTAssertEqual(merged.skipCount, 1, "the destination row's skip must not be dropped on a tie")
        XCTAssertEqual(merged.dateAdded, earlier, "dateAdded must take the earlier of the two rows")
    }

    private func freshFileURL() -> URL {
        folder.appendingPathComponent("cdplays-\(UUID().uuidString).json")
    }

    func testRepointingManyPairsIsIndependentOfTheOrderTheyArrive() throws {
        let x = ListeningStore.key(for: trackA)
        let y = ListeningStore.key(for: trackB)
        let z = ListeningStore.key(for: trackC)

        // A swap: A moves X to Y while B moves Z to X. Whichever pair is applied
        // first must not decide who keeps which history. A `[String: String]`
        // literal can't test this — dictionary enumeration order depends on hash
        // buckets, not on how the literal was written, so two differently-written
        // literals with the same keys iterate identically. `orderedPairs` is the
        // only entry point that can actually be driven in two different orders.
        for ordering in [[(x, y), (z, x)], [(z, x), (x, y)]] {
            let store = ListeningStore(fileURL: freshFileURL())
            store.recordPlay(path: x, at: now)
            store.recordPlay(path: x, at: now)
            store.recordPlay(path: x, at: now)
            store.recordPlay(path: z, at: now)

            store.repoint(orderedPairs: ordering)

            XCTAssertEqual(store.stats(path: y)?.playCount, 3, "A's history follows A")
            XCTAssertEqual(store.stats(path: x)?.playCount, 1, "B's history follows B")
        }
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
