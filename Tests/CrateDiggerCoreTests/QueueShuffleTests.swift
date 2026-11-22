#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class QueueShuffleTests: XCTestCase {

    // MARK: Shuffle on

    func testShufflingPutsThePlayingItemFirstAndKeepsEveryItem() {
        var rng = SeededGenerator(seed: 7)
        let order = QueueShuffle.shuffledOrder(count: 8, current: 5, using: &rng)
        XCTAssertEqual(order.first, 5, "the playing track stays on the deck, at the head")
        XCTAssertEqual(order.sorted(), Array(0..<8), "a permutation: nothing lost, nothing doubled")
    }

    func testShufflingWithNothingPlayingIsStillAPermutation() {
        var rng = SeededGenerator(seed: 3)
        let order = QueueShuffle.shuffledOrder(count: 5, current: nil, using: &rng)
        XCTAssertEqual(order.sorted(), Array(0..<5))
    }

    func testShufflingAnEmptyQueueIsEmpty() {
        var rng = SeededGenerator(seed: 1)
        XCTAssertEqual(QueueShuffle.shuffledOrder(count: 0, current: nil, using: &rng), [])
    }

    // MARK: Shuffle off

    func testUnshufflingRestoresTheSourceOrder() {
        // Album order A…E, dealt as C A E B D.
        let ids = ["C", "A", "E", "B", "D"]
        let order = QueueShuffle.unshuffledOrder(ids: ids, sourceOrder: ["A", "B", "C", "D", "E"])
        XCTAssertEqual(order.map { ids[$0] }, ["A", "B", "C", "D", "E"])
    }

    func testAQueuedTrackTravelsWithTheTrackItFollowed() {
        // X was Play-Next'ed behind B; it has no place in the album's order.
        let ids = ["C", "B", "X", "A"]
        let order = QueueShuffle.unshuffledOrder(ids: ids, sourceOrder: ["A", "B", "C"])
        XCTAssertEqual(order.map { ids[$0] }, ["A", "B", "X", "C"])
    }

    func testWithNoSourceOrderTheQueueStaysAsItIs() {
        let ids = ["C", "A", "B"]
        let order = QueueShuffle.unshuffledOrder(ids: ids, sourceOrder: [String]())
        XCTAssertEqual(order, [0, 1, 2])
    }

    func testATrackQueuedTwiceKeepsBothCopies() {
        let ids = ["B", "A", "B"]
        let order = QueueShuffle.unshuffledOrder(ids: ids, sourceOrder: ["A", "B"])
        XCTAssertEqual(order.map { ids[$0] }, ["A", "B", "B"])
        XCTAssertEqual(order.sorted(), [0, 1, 2])
    }
}

/// SplitMix64: a deterministic generator so a shuffle can be pinned.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
#endif
