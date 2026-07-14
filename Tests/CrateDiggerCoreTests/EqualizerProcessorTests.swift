#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class EqualizerProcessorTests: XCTestCase {

    private func sine(count: Int, frequency: Double = 1000, rate: Double = 44_100) -> [Float] {
        (0..<count).map { Float(sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    // MARK: - isActive (the tap's bypass gate)

    func testFlatCurveIsInactiveEvenWhenEnabled() {
        let eq = EqualizerProcessor()
        eq.update(enabled: true, gainsDB: Array(repeating: 0, count: EqualizerProcessor.bandCount))
        XCTAssertFalse(eq.isActive)
    }

    func testDisabledIsInactiveRegardlessOfGains() {
        let eq = EqualizerProcessor()
        eq.update(enabled: false, gainsDB: Array(repeating: 6, count: EqualizerProcessor.bandCount))
        XCTAssertFalse(eq.isActive)
    }

    func testSingleNonZeroBandActivates() {
        let eq = EqualizerProcessor()
        var gains = [Double](repeating: 0, count: EqualizerProcessor.bandCount)
        gains[4] = 3
        eq.update(enabled: true, gainsDB: gains)
        XCTAssertTrue(eq.isActive)
    }

    func testHairlineGainsStillCountAsFlat() {
        // Sub-0.05dB residue (e.g. a slider snapped "back to zero") must not
        // re-engage the cascade.
        let eq = EqualizerProcessor()
        eq.update(enabled: true, gainsDB: Array(repeating: 0.01, count: EqualizerProcessor.bandCount))
        XCTAssertFalse(eq.isActive)
    }

    // MARK: - Processing sanity

    func testFlatProcessingIsIdentity() {
        // The property that makes the bypass transparent: at 0dB each peaking
        // biquad is H(z)=1, so the cascade outputs the input. In float32 the 12
        // near-unit-circle sections add ~1e-4 of rounding noise (≈ -80dB) —
        // which also means the bypass is marginally *cleaner* than processing.
        let eq = EqualizerProcessor()
        eq.update(enabled: true, gainsDB: Array(repeating: 0, count: EqualizerProcessor.bandCount))
        let input = sine(count: 2048)
        var samples = input
        samples.withUnsafeMutableBufferPointer {
            eq.processInPlace($0.baseAddress!, stride: 1, frames: 2048, channel: 0)
        }
        let maxDelta = zip(samples, input).map { abs($0 - $1) }.max() ?? .infinity
        XCTAssertLessThan(maxDelta, 5e-3, "flat cascade must be audibly transparent (rounding noise only)")
    }

    func testBoostedProcessingChangesSamples() {
        let eq = EqualizerProcessor()
        eq.update(enabled: true, gainsDB: Array(repeating: 12, count: EqualizerProcessor.bandCount))
        let input = sine(count: 2048)
        var samples = input
        samples.withUnsafeMutableBufferPointer {
            eq.processInPlace($0.baseAddress!, stride: 1, frames: 2048, channel: 0)
        }
        let maxDelta = zip(samples, input).map { abs($0 - $1) }.max() ?? 0
        XCTAssertGreaterThan(maxDelta, 0.1, "a +12dB curve must audibly reshape the signal")
    }
}
#endif
