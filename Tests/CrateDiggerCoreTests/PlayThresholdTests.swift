#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

/// Pins the exact rule the app has always used for Last.fm. These tests exist
/// so the extraction in Task 1 cannot quietly change when a track scrobbles.
final class PlayThresholdTests: XCTestCase {

    func testHalfOfAShortTrackCounts() {
        // 200s track: half is 100s, which is under the 240s cap.
        XCTAssertTrue(PlayThreshold.isPlayed(elapsed: 100, duration: 200))
        XCTAssertFalse(PlayThreshold.isPlayed(elapsed: 99, duration: 200))
    }

    func testLongTrackCapsAtFourMinutes() {
        // 3600s track: half would be 1800s, but four minutes is enough.
        XCTAssertTrue(PlayThreshold.isPlayed(elapsed: 240, duration: 3600))
        XCTAssertFalse(PlayThreshold.isPlayed(elapsed: 239, duration: 3600))
    }

    func testThirtySecondFloorBeatsTheHalfRule() {
        // 40s interlude: half is 20s, but nothing under 30s is ever a play.
        XCTAssertFalse(PlayThreshold.isPlayed(elapsed: 20, duration: 40))
        XCTAssertFalse(PlayThreshold.isPlayed(elapsed: 29.9, duration: 40))
        XCTAssertTrue(PlayThreshold.isPlayed(elapsed: 30, duration: 40))
    }

    func testZeroAndNegativeInputsAreNotPlays() {
        XCTAssertFalse(PlayThreshold.isPlayed(elapsed: 0, duration: 0))
        XCTAssertFalse(PlayThreshold.isPlayed(elapsed: -5, duration: 200))
        XCTAssertFalse(PlayThreshold.isPlayed(elapsed: 100, duration: 0))
    }

    // MARK: - Skips

    /// The regression this rule exists for: a 20s skit can never be a play, so
    /// "not played" as a stand-in for "skipped" gave it a skip every single time
    /// it ran to its end.
    func testShortTrackHeardToTheEndIsNotASkip() {
        XCTAssertFalse(PlayThreshold.isSkipped(elapsed: 20, duration: 20))
        // Tick accumulation lands just short of the real duration.
        XCTAssertFalse(PlayThreshold.isSkipped(elapsed: 19.4, duration: 20))
        XCTAssertFalse(PlayThreshold.isPlayed(elapsed: 20, duration: 20),
                       "and it is still not a play — the two rules are independent")
    }

    func testShortTrackAbandonedEarlyIsASkip() {
        XCTAssertTrue(PlayThreshold.isSkipped(elapsed: 3, duration: 20))
        XCTAssertTrue(PlayThreshold.isSkipped(elapsed: 15.9, duration: 20))
    }

    func testLongTrackAbandonedEarlyIsASkip() {
        XCTAssertTrue(PlayThreshold.isSkipped(elapsed: 10, duration: 300))
    }

    func testLongTrackHeardOutIsNotASkip() {
        XCTAssertFalse(PlayThreshold.isSkipped(elapsed: 240, duration: 300))
        XCTAssertFalse(PlayThreshold.isSkipped(elapsed: 300, duration: 300))
    }

    func testZeroAndNegativeInputsAreNotSkips() {
        XCTAssertFalse(PlayThreshold.isSkipped(elapsed: 0, duration: 200))
        XCTAssertFalse(PlayThreshold.isSkipped(elapsed: -5, duration: 200))
        XCTAssertFalse(PlayThreshold.isSkipped(elapsed: 100, duration: 0))
    }
}
#endif
