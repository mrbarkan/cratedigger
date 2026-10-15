#if canImport(XCTest)
import CoreGraphics
import XCTest
@testable import CrateDiggerCore

/// Every scene reads time through `BusySignalTiming`, so these pin the 8 fps
/// grid and the blink. The sketch's hash is pinned in `BusyNoiseTests`; the
/// redraw cadence (spec §11.1 lists it here) is pinned in
/// `BusySceneTests.testCadenceTicksTwicePerStepRunningAndPausesWhenStillOrSettled`,
/// since it is a function of a scene input.
final class BusySignalTimingTests: XCTestCase {
    func testQuantizedFloorsToEighths() {
        XCTAssertEqual(BusySignalTiming.quantized(0.124), 0)
        XCTAssertEqual(BusySignalTiming.quantized(0.125), 0.125)
        XCTAssertEqual(BusySignalTiming.quantized(1.99), 1.875)
        XCTAssertEqual(BusySignalTiming.step(1.99), 15)
    }

    func testDegenerateTimeReadsAsZero() {
        for t in [TimeInterval.nan, -3, .infinity, -.infinity] {
            XCTAssertEqual(BusySignalTiming.quantized(t), 0, "\(t)")
            XCTAssertEqual(BusySignalTiming.step(t), 0, "\(t)")
        }
    }

    func testBlinkTogglesEveryHalfSecondAtTwoHertz() {
        XCTAssertTrue(BusySignalTiming.blink(0))
        XCTAssertTrue(BusySignalTiming.blink(0.49))
        XCTAssertFalse(BusySignalTiming.blink(0.5))
        XCTAssertTrue(BusySignalTiming.blink(1.0))
    }
}
#endif
