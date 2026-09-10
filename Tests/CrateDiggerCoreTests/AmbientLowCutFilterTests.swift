#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class AmbientLowCutFilterTests: XCTestCase {

    private let sampleRate = 48_000.0

    private func sine(_ frequency: Double, seconds: Double = 1, amplitude: Float = 0.5) -> [Float] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    /// RMS of the second half, after the filter has settled.
    private func settledRMS(_ samples: [Float]) -> Float {
        let tail = samples[(samples.count / 2)...]
        return (tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count)).squareRoot()
    }

    private func filtered(_ input: [Float], enabled: Bool = true) -> [Float] {
        var filter = AmbientLowCutFilter(sampleRate: sampleRate)
        filter.isEnabled = enabled
        var output = input
        output.withUnsafeMutableBufferPointer { filter.process($0.baseAddress!, frameCount: $0.count) }
        return output
    }

    /// Mains hum and fridge drone sit around 50 to 60 Hz: most of it goes.
    func testHumIsCutByMostOfItsLevel() {
        let input = sine(50)
        XCTAssertLessThan(settledRMS(filtered(input)) / settledRMS(input), 0.3)
    }

    /// Voices and doorbells live well above the cut and come through intact.
    func testVoiceBandPassesUntouched() {
        let input = sine(1_000)
        XCTAssertEqual(settledRMS(filtered(input)) / settledRMS(input), 1, accuracy: 0.05)
    }

    func testASteadyOffsetDecaysToNothing() {
        let output = filtered([Float](repeating: 0.4, count: Int(sampleRate)))
        XCTAssertLessThan(abs(output.last!), 0.01)
    }

    func testSwitchedOffItReturnsTheInputExactly() {
        let input = sine(50, seconds: 0.1)
        XCTAssertEqual(filtered(input, enabled: false), input)
    }

    /// Audio arrives one IO buffer at a time; the filter's memory has to carry
    /// across calls or every buffer boundary clicks.
    func testSplittingTheAudioIntoBuffersChangesNothing() {
        let input = sine(80, seconds: 0.1)
        let whole = filtered(input)

        var filter = AmbientLowCutFilter(sampleRate: sampleRate)
        var chunked = input
        chunked.withUnsafeMutableBufferPointer { buffer in
            let half = buffer.count / 2
            filter.process(buffer.baseAddress!, frameCount: half)
            filter.process(buffer.baseAddress! + half, frameCount: buffer.count - half)
        }

        for (a, b) in zip(whole, chunked) { XCTAssertEqual(a, b, accuracy: 1e-6) }
    }
}
#endif
