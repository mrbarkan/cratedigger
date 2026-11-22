#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class PlaybackMeterScaleTests: XCTestCase {

    private func linear(dB: Double) -> Double { pow(10, dB / 20) }

    func testFullVolumeLeavesTheBandsAlone() {
        XCTAssertEqual(PlaybackMeterScale.spectrum([0.2, 0.6, 1.0], volume: 1), [0.2, 0.6, 1.0])
    }

    /// The bands are already a dB window, so turning down takes the same
    /// number of dB off each bar. Multiplying by the linear volume took 42%
    /// of every bar's height for a 5 dB nudge of the fader.
    func testTurningDownLowersEachBarByItsDecibels() {
        let window = Double(SpectrumProcessor.ceilDB - SpectrumProcessor.floorDB)
        let bands = PlaybackMeterScale.spectrum([0.9, 0.5], volume: linear(dB: -5))
        XCTAssertEqual(bands[0], 0.9 - 5 / window, accuracy: 1e-9)
        XCTAssertEqual(bands[1], 0.5 - 5 / window, accuracy: 1e-9)
    }

    func testABarNeverGoesBelowDark() {
        XCTAssertEqual(PlaybackMeterScale.spectrum([0.1], volume: linear(dB: -40)), [0])
    }

    func testMutedIsDark() {
        XCTAssertEqual(PlaybackMeterScale.spectrum([0.8, 1.0], volume: 0), [0, 0])
    }
}
#endif
