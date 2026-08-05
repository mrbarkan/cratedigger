#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class SleepModeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testTimedModeCountsDown() {
        let mode = SleepMode.after(minutes: 30)
        XCTAssertEqual(mode.remainingSeconds(now: start, start: start), 1800)
        XCTAssertEqual(mode.remainingSeconds(now: start.addingTimeInterval(600), start: start), 1200)
        XCTAssertEqual(mode.remainingSeconds(now: start.addingTimeInterval(1800), start: start), 0)
    }

    func testCountdownNeverGoesNegative() {
        let mode = SleepMode.after(minutes: 1)
        XCTAssertEqual(mode.remainingSeconds(now: start.addingTimeInterval(9_999), start: start), 0)
    }

    func testElapsedOnlyOnceTheDeadlinePasses() {
        let mode = SleepMode.after(minutes: 15)
        XCTAssertFalse(mode.hasElapsed(now: start.addingTimeInterval(899), start: start))
        XCTAssertTrue(mode.hasElapsed(now: start.addingTimeInterval(900), start: start))
        XCTAssertTrue(mode.hasElapsed(now: start.addingTimeInterval(901), start: start))
    }

    /// Event-driven modes have no deadline and must never fire on the clock —
    /// otherwise "after this album" would cut off mid-track.
    func testEventDrivenModesHaveNoDeadlineAndNeverElapse() {
        for mode in [SleepMode.endOfTrack, .endOfQueue] {
            XCTAssertNil(mode.deadline(from: start), "\(mode) must not be clock-driven")
            XCTAssertNil(mode.remainingSeconds(now: start.addingTimeInterval(99_999), start: start))
            XCTAssertFalse(mode.hasElapsed(now: start.addingTimeInterval(99_999), start: start))
        }
    }

    func testOffIsNeverArmed() {
        XCTAssertFalse(SleepMode.off.isArmed)
        XCTAssertNil(SleepMode.off.deadline(from: start))
        XCTAssertNil(SleepMode.off.statusLabel(now: start, start: start))
        for mode in [SleepMode.after(minutes: 5), .endOfTrack, .endOfQueue] {
            XCTAssertTrue(mode.isArmed)
        }
    }

    func testZeroOrNegativeMinutesIsNotAValidDeadline() {
        XCTAssertNil(SleepMode.after(minutes: 0).deadline(from: start))
        XCTAssertNil(SleepMode.after(minutes: -5).deadline(from: start))
    }

    func testStatusLabels() {
        XCTAssertEqual(SleepMode.after(minutes: 30).statusLabel(now: start, start: start), "30:00")
        XCTAssertEqual(SleepMode.endOfTrack.statusLabel(now: start, start: start), "END OF TRACK")
        XCTAssertEqual(SleepMode.endOfQueue.statusLabel(now: start, start: start), "END OF QUEUE")
    }

    func testClockLabelCrossesTheHourCorrectly() {
        XCTAssertEqual(SleepMode.clockLabel(0), "0:00")
        XCTAssertEqual(SleepMode.clockLabel(59), "0:59")
        XCTAssertEqual(SleepMode.clockLabel(600), "10:00")
        XCTAssertEqual(SleepMode.clockLabel(3599), "59:59")
        XCTAssertEqual(SleepMode.clockLabel(3600), "1:00:00")
        XCTAssertEqual(SleepMode.clockLabel(5400), "1:30:00")
    }

    func testCodableRoundTrip() throws {
        for mode in [SleepMode.off, .after(minutes: 45), .endOfTrack, .endOfQueue] {
            let data = try JSONEncoder().encode(mode)
            XCTAssertEqual(try JSONDecoder().decode(SleepMode.self, from: data), mode)
        }
    }
}
#endif
