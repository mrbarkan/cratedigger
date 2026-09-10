#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class AmbientRingBufferTests: XCTestCase {

    private func write(_ ring: AmbientRingBuffer, _ values: [Float]) {
        values.withUnsafeBufferPointer { ring.write($0.baseAddress!, frameCount: values.count) }
    }

    private func read(_ ring: AmbientRingBuffer, _ count: Int) -> [Float] {
        var out = [Float](repeating: -1, count: count)
        out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frameCount: count) }
        return out
    }

    private func ramp(_ range: Range<Int>) -> [Float] { range.map(Float.init) }

    /// The delay setting is how much sits in the buffer before any of it plays.
    func testStaysSilentUntilTheDelayTargetHasBuffered() {
        let ring = AmbientRingBuffer(capacityFrames: 64, targetFrames: 8)
        write(ring, ramp(0..<5))
        XCTAssertEqual(read(ring, 4), [0, 0, 0, 0])
        XCTAssertEqual(ring.fillFrames, 5, "priming must not consume what it is waiting for")
        write(ring, ramp(5..<10))
        XCTAssertEqual(read(ring, 4), [0, 1, 2, 3])
    }

    func testUnderrunPadsWithSilenceAndWaitsForTheTargetAgain() {
        let ring = AmbientRingBuffer(capacityFrames: 64, targetFrames: 4)
        write(ring, ramp(0..<6))
        XCTAssertEqual(read(ring, 4), [0, 1, 2, 3])
        XCTAssertEqual(read(ring, 4), [4, 5, 0, 0])
        write(ring, [10, 11, 12])
        XCTAssertEqual(read(ring, 2), [0, 0], "three frames is under the target of four")
        write(ring, [13])
        XCTAssertEqual(read(ring, 2), [10, 11])
    }

    /// The input side outrunning a stalled output must never grow the delay
    /// past the buffer: the oldest audio goes first.
    func testOverflowDropsTheOldestAudio() {
        let ring = AmbientRingBuffer(capacityFrames: 8, targetFrames: 1)
        write(ring, ramp(0..<10))
        XCTAssertEqual(ring.fillFrames, 8)
        XCTAssertEqual(read(ring, 8), ramp(2..<10))
    }

    /// Two clocks drift. When the mic runs well ahead of the output, skip back
    /// to the delay target instead of letting the lag creep up.
    func testRunningFarAheadSkipsBackToTheTarget() {
        let ring = AmbientRingBuffer(capacityFrames: 64, targetFrames: 10)
        write(ring, ramp(0..<40))
        XCTAssertEqual(read(ring, 4), [26, 27, 28, 29])
        XCTAssertEqual(ring.fillFrames, 10)
    }

    // MARK: - Counters, for judging how clean Ambient sounds

    /// Running dry mid-stream is an audible gap, and worth counting.
    func testRunningDryMidStreamCountsAsAnUnderrun() {
        let ring = AmbientRingBuffer(capacityFrames: 64, targetFrames: 4)
        write(ring, ramp(0..<6))
        _ = read(ring, 4)
        _ = read(ring, 4)
        XCTAssertEqual(ring.underruns, 1)
    }

    /// The silence while the delay first fills is by design, not a gap.
    func testWaitingForTheTargetIsNotAnUnderrun() {
        let ring = AmbientRingBuffer(capacityFrames: 64, targetFrames: 8)
        write(ring, ramp(0..<5))
        _ = read(ring, 4)
        _ = read(ring, 4)
        XCTAssertEqual(ring.underruns, 0)
    }

    func testAudioDroppedOnOverflowCountsAsSkipped() {
        let ring = AmbientRingBuffer(capacityFrames: 8, targetFrames: 1)
        write(ring, ramp(0..<10))
        XCTAssertEqual(ring.skippedFrames, 2)
        write(ring, ramp(10..<13))
        XCTAssertEqual(ring.skippedFrames, 5)
    }

    func testCatchingUpWithDriftCountsAsSkipped() {
        let ring = AmbientRingBuffer(capacityFrames: 64, targetFrames: 10)
        write(ring, ramp(0..<40))
        _ = read(ring, 4)
        XCTAssertEqual(ring.skippedFrames, 26)
    }
}
#endif
