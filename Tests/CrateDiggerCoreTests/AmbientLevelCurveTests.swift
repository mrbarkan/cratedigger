#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class AmbientLevelCurveTests: XCTestCase {

    func testUnitySitsAtTheMark() {
        XCTAssertEqual(AmbientLevelCurve.unityPosition, 60.0 / 72.0, accuracy: 0.0001)
        XCTAssertEqual(AmbientLevelCurve.amplitude(forPosition: AmbientLevelCurve.unityPosition), 1.0, accuracy: 0.001)
        XCTAssertEqual(AmbientLevelCurve.label(forPosition: AmbientLevelCurve.unityPosition), "0 dB")
    }

    /// A laptop mic across the room is quiet, so the top of travel is real boost,
    /// well past the +5 dB the VOLUME fader allows.
    func testTopOfTravelIsTwelveDecibelsOfGain() {
        XCTAssertEqual(AmbientLevelCurve.amplitude(forPosition: 1), pow(10, 12.0 / 20), accuracy: 0.001)
        XCTAssertEqual(AmbientLevelCurve.label(forPosition: 1), "+12 dB")
    }

    func testBottomIsSilentAndTheTaperOnlyRises() {
        XCTAssertEqual(AmbientLevelCurve.amplitude(forPosition: 0), 0)
        XCTAssertEqual(AmbientLevelCurve.label(forPosition: 0), "−∞")
        var previous = 0.0
        for step in 1...100 {
            let amplitude = AmbientLevelCurve.amplitude(forPosition: Double(step) / 100)
            XCTAssertGreaterThan(amplitude, previous, "position \(step)%")
            previous = amplitude
        }
    }
}
#endif
