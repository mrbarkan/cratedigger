import XCTest
@testable import CrateDiggerCore

/// The tap's *measurement* needs real audio, so what's checked here is the part
/// that can silently break the meter: the CoreAudio lifecycle. `start()` must be
/// idempotent, `stop()` must be safe to call unpaired (both happen — `stopRadio`
/// runs on failures that never started a stream), and neither may leave levels
/// pinned at a stale value.
final class ProcessOutputLevelTapTests: XCTestCase {

    func testRestsAtSilenceBeforeStarting() {
        let tap = ProcessOutputLevelTap()
        let levels = tap.currentLevels()
        XCTAssertEqual(levels.left, 0)
        XCTAssertEqual(levels.right, 0)
        XCTAssertTrue(tap.currentBands().allSatisfy { $0 == 0 })
    }

    func testStartAndStopAreIdempotent() {
        let tap = ProcessOutputLevelTap()
        tap.start()
        tap.start()
        tap.stop()
        tap.stop()
        // A second cycle must work too — radio starts and stops many times a session.
        tap.start()
        tap.stop()

        let levels = tap.currentLevels()
        XCTAssertEqual(levels.left, 0)
        XCTAssertEqual(levels.right, 0)
    }

    func testStopWithoutStartIsSafe() {
        let tap = ProcessOutputLevelTap()
        tap.stop()
        XCTAssertEqual(tap.currentBands().count, SpectrumProcessor.bandCount)
    }
}
