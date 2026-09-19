#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class VolumeCurveTests: XCTestCase {

    func testUnityAtEmbossedMark() {
        // The "0" mark sits at the unity position; there it's exactly 0 dB / amp 1.0,
        // split into player.volume 1.0 + no makeup gain.
        XCTAssertEqual(VolumeCurve.decibels(forPosition: VolumeCurve.unityPosition), 0, accuracy: 0.001)
        XCTAssertEqual(VolumeCurve.amplitude(forPosition: VolumeCurve.unityPosition), 1.0, accuracy: 0.001)
        XCTAssertEqual(VolumeCurve.playerVolume(forPosition: VolumeCurve.unityPosition), 1.0, accuracy: 0.001)
        XCTAssertEqual(VolumeCurve.makeupGain(forPosition: VolumeCurve.unityPosition), 1.0, accuracy: 0.001)
        XCTAssertEqual(VolumeCurve.label(forPosition: VolumeCurve.unityPosition), "0 dB")
        XCTAssertEqual(VolumeCurve.unityPosition, 60.0 / 65.0, accuracy: 0.0001)
    }

    func testBoostAboveUnity() {
        // Top of travel is real +5 dB gain (≈1.778× linear).
        XCTAssertEqual(VolumeCurve.decibels(forPosition: 1.0), 5, accuracy: 0.001)
        XCTAssertEqual(VolumeCurve.amplitude(forPosition: 1.0), pow(10, 5.0 / 20), accuracy: 0.001)
        XCTAssertEqual(VolumeCurve.label(forPosition: 1.0), "+5 dB")
        // Split: player.volume caps at 1.0, the >0 dB part becomes makeup gain (>1).
        XCTAssertEqual(VolumeCurve.playerVolume(forPosition: 1.0), 1.0, accuracy: 0.001)
        XCTAssertGreaterThan(VolumeCurve.makeupGain(forPosition: 1.0), 1.5)
        // Invariants across the whole travel.
        for i in 0...100 {
            let p = Double(i) / 100
            XCTAssertLessThanOrEqual(VolumeCurve.playerVolume(forPosition: p), 1.0)
            XCTAssertGreaterThanOrEqual(VolumeCurve.makeupGain(forPosition: p), 1.0)
        }
    }

    func testSilenceAndMonotonicTaper() {
        XCTAssertEqual(VolumeCurve.amplitude(forPosition: 0), 0)
        XCTAssertEqual(VolumeCurve.label(forPosition: 0), "−∞")
        // dB-linear below unity → monotonically increasing amplitude.
        XCTAssertLessThan(VolumeCurve.amplitude(forPosition: 0.3), VolumeCurve.amplitude(forPosition: 0.6))
        XCTAssertLessThan(VolumeCurve.amplitude(forPosition: 0.6), VolumeCurve.amplitude(forPosition: 0.9))
        // Half-ish travel is well below unity (a real fader taper, not linear).
        XCTAssertLessThan(VolumeCurve.amplitude(forPosition: 0.5), 0.2)
    }

    func testPercentIsOneHundredAtUnity() {
        XCTAssertEqual(VolumeCurve.percent(forPosition: VolumeCurve.unityPosition), 100)
        XCTAssertEqual(VolumeCurve.percent(forPosition: 0), 0)
        XCTAssertEqual(VolumeCurve.percent(forPosition: 1), 108)
        XCTAssertEqual(VolumeCurve.percent(forPosition: VolumeCurve.unityPosition / 2), 50)
    }

    func testReadoutInBothUnits() {
        XCTAssertEqual(VolumeCurve.readout(forPosition: 0, unit: .decibels), "VOL  MUTE")
        XCTAssertEqual(VolumeCurve.readout(forPosition: 0, unit: .percent), "VOL  MUTE")
        XCTAssertEqual(VolumeCurve.readout(forPosition: VolumeCurve.unityPosition, unit: .decibels), "VOL  0 dB")
        XCTAssertEqual(VolumeCurve.readout(forPosition: VolumeCurve.unityPosition, unit: .percent), "VOL  100%")
        XCTAssertEqual(VolumeCurve.readout(forPosition: 1, unit: .decibels), "VOL  +5 dB")
        XCTAssertEqual(VolumeCurve.readout(forPosition: 1, unit: .percent), "VOL  108%")
    }

    func testReadoutCapsAtUnityWhenBoostIsUnavailable() {
        // Streams and DSD never receive the makeup gain, so the number must not claim it.
        XCTAssertEqual(VolumeCurve.readout(forPosition: 1, unit: .decibels, boostAvailable: false), "VOL  0 dB")
        XCTAssertEqual(VolumeCurve.readout(forPosition: 1, unit: .percent, boostAvailable: false), "VOL  100%")
        XCTAssertEqual(VolumeCurve.readout(forPosition: 0.5, unit: .percent, boostAvailable: false),
                       VolumeCurve.readout(forPosition: 0.5, unit: .percent))
    }

    func testSteppingLandsOnUnityWhenCrossingIt() {
        let u = VolumeCurve.unityPosition
        XCTAssertEqual(VolumeCurve.stepped(from: 0.90, by: 0.05), u, accuracy: 0.0001)   // up across
        XCTAssertEqual(VolumeCurve.stepped(from: 0.95, by: -0.05), u, accuracy: 0.0001)  // down across
        XCTAssertEqual(VolumeCurve.stepped(from: u, by: 0.05), u + 0.05, accuracy: 0.0001) // leaving it is free
        XCTAssertEqual(VolumeCurve.stepped(from: 0.50, by: 0.05), 0.55, accuracy: 0.0001)
        XCTAssertEqual(VolumeCurve.stepped(from: 0.98, by: 0.05), 1)
        XCTAssertEqual(VolumeCurve.stepped(from: 0.02, by: -0.05), 0)
    }
}
#endif
