import XCTest
@testable import CrateDiggerCore

/// The follower measures a song's loudness against itself, so the matrix
/// swings with the music whatever level it was mastered at.
final class LoudnessFollowerTests: XCTestCase {

    private let tick: TimeInterval = 1.0 / 30

    /// Feeds `seconds` of `level(t)` at 30 fps and returns every drive.
    @discardableResult
    private func feed(_ follower: inout LoudnessFollower, seconds: Double, level: (Double) -> Double) -> [Double] {
        let ticks = Int((seconds / tick).rounded())
        return (0..<ticks).map { follower.drive(loudness: level(Double($0) * tick), dt: tick) }
    }

    func testConstantInputSettlesAtHalf() {
        var follower = LoudnessFollower()
        let drives = feed(&follower, seconds: 5) { _ in 0.4 }
        XCTAssertEqual(drives.first ?? -1, 0.5, accuracy: 1e-12, "the first reading seeds the mean")
        for drive in drives { XCTAssertEqual(drive, 0.5, accuracy: 1e-9) }
    }

    func testAStepUpDrivesHighThenRelaxesTowardHalf() {
        var follower = LoudnessFollower()
        feed(&follower, seconds: 5) { _ in 0.3 }
        let after = feed(&follower, seconds: 10) { _ in 0.45 }
        XCTAssertGreaterThan(after[0], 0.8, "a step up should read as loud")
        XCTAssertEqual(after.last ?? -1, 0.5, accuracy: 0.05, "and become the new normal")
        XCTAssertLessThan(after[Int(4 / tick)], after[0], "relaxing within a few seconds")
    }

    func testAStepDownDrivesLow() {
        var follower = LoudnessFollower()
        feed(&follower, seconds: 5) { _ in 0.5 }
        let after = feed(&follower, seconds: 1) { _ in 0.35 }
        XCTAssertLessThan(after[0], 0.2)
    }

    func testSilenceDrivesZero() {
        var follower = LoudnessFollower()
        XCTAssertTrue(follower.isSilent)
        XCTAssertEqual(follower.drive(loudness: 0, dt: tick), 0)
        feed(&follower, seconds: 2) { _ in 0.5 }
        XCTAssertFalse(follower.isSilent)
        XCTAssertEqual(follower.drive(loudness: 0, dt: tick), 0)
        XCTAssertEqual(follower.drive(loudness: 0.01, dt: tick), 0, "the tail of a fade is still silence")
        XCTAssertTrue(follower.isSilent)
        XCTAssertEqual(follower.drive(loudness: .nan, dt: tick), 0)
    }

    /// Without the re-seed, a song resuming at its old level would be measured
    /// against a mean dragged toward zero and pin the drive at 1 for seconds.
    func testResumingAfterSilenceDoesNotSaturate() {
        var follower = LoudnessFollower()
        feed(&follower, seconds: 5) { _ in 0.5 }
        feed(&follower, seconds: 3) { _ in 0 }
        let resumed = feed(&follower, seconds: 2) { _ in 0.5 }
        for drive in resumed { XCTAssertEqual(drive, 0.5, accuracy: 0.01) }
    }

    /// A first reading caught mid-attack seeds the mean low; the plain
    /// average over the first readings pulls it up within a fraction of a
    /// second instead of the whole time constant.
    func testALowFirstReadingIsForgottenQuickly() {
        var follower = LoudnessFollower()
        _ = follower.drive(loudness: 0.1, dt: tick)
        let drives = feed(&follower, seconds: 2) { _ in 0.5 }
        XCTAssertLessThan(drives[Int(0.5 / tick)], 0.75, "still pinned half a second in: \(drives.prefix(20))")
    }

    /// Loudness that swings around a level, as music does with its beats and
    /// phrases, must use most of the range, however small the swing.
    func testAnOscillatingInputSpansMostOfTheRange() {
        for (mean, swing) in [(0.5, 0.05), (0.3, 0.1), (0.55, 0.04)] {
            var follower = LoudnessFollower()
            feed(&follower, seconds: 5) { mean + swing * sin(2 * .pi * 1.3 * $0) }
            let drives = feed(&follower, seconds: 10) { mean + swing * sin(2 * .pi * 1.3 * $0) }
            let low = drives.min() ?? 0, high = drives.max() ?? 0
            XCTAssertLessThan(low, 0.2, "mean \(mean) swing \(swing)")
            XCTAssertGreaterThan(high, 0.8, "mean \(mean) swing \(swing)")
        }
    }

    /// A steady signal's jitter is not dynamics: the spread floor keeps it calm.
    func testTinyJitterStaysNearHalf() {
        var follower = LoudnessFollower()
        var seed: UInt64 = 42
        let drives = feed(&follower, seconds: 10) { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return 0.5 + (Double(seed >> 11) / Double(1 << 53) * 2 - 1) * 0.005
        }
        for drive in drives { XCTAssertEqual(drive, 0.5, accuracy: 0.06) }
    }

    func testDriveStaysInRangeOnWildInput() {
        var follower = LoudnessFollower()
        for step in 0..<600 {
            let loudness = step % 17 == 0 ? 0 : Double((step * 7919) % 101) / 100
            let drive = follower.drive(loudness: loudness, dt: step % 5 == 0 ? 0 : tick)
            XCTAssertTrue((0...1).contains(drive), "\(drive)")
        }
        XCTAssertTrue((0...1).contains(follower.drive(loudness: 0.9, dt: 3_600)))
    }

    /// A stop-time break dips under the gate for a moment. The song's
    /// statistics are held through it, so the hit that ends the break reads
    /// as loud against the song, not as the calm seed of a new one.
    func testAShortDipUnderTheGateHoldsTheSongsStatistics() {
        var follower = LoudnessFollower()
        feed(&follower, seconds: 5) { _ in 0.4 }
        let dip = feed(&follower, seconds: 0.3) { _ in 0.01 }
        for drive in dip { XCTAssertEqual(drive, 0) }
        XCTAssertTrue(follower.isSilent, "the gate is closed through the dip")
        XCTAssertGreaterThan(follower.drive(loudness: 0.5, dt: tick), 0.9)
    }

    /// The tail of a fade dithers across the gate. Re-seeding on every upward
    /// crossing would jump the drive from 0 to 0.5 on alternate ticks.
    func testAFadeTailDitheringAcrossTheGateNeverReseeds() {
        var follower = LoudnessFollower()
        feed(&follower, seconds: 3) { _ in 0.3 }
        var step = 0
        let tail = feed(&follower, seconds: 1) { _ in
            step += 1
            return step.isMultiple(of: 2) ? 0.021 : 0.019
        }
        for drive in tail { XCTAssertLessThan(drive, 0.25, "\(tail)") }
    }

    /// A quiet spell longer than the hold is the end of the song: the next
    /// sound seeds afresh.
    func testAQuietSpellLongerThanTheHoldForgets() {
        var follower = LoudnessFollower()
        feed(&follower, seconds: 5) { _ in 0.2 }
        feed(&follower, seconds: LoudnessFollower.silenceHold + 0.1) { _ in 0.01 }
        XCTAssertEqual(follower.drive(loudness: 0.8, dt: tick), 0.5, accuracy: 1e-12)
    }

    /// Exactly 0 is the meter settled after playback stopped: forgotten at
    /// once, with no hold.
    func testASettledZeroForgetsAtOnce() {
        var follower = LoudnessFollower()
        feed(&follower, seconds: 5) { _ in 0.2 }
        XCTAssertEqual(follower.drive(loudness: 0, dt: tick), 0)
        XCTAssertTrue(follower.isSilent)
        XCTAssertEqual(follower.drive(loudness: 0.8, dt: tick), 0.5, accuracy: 1e-12)
    }

    /// A step longer than the time constant (the window was hidden while the
    /// music played on) says nothing about the music in between: re-seed
    /// rather than read the new level against a chorus long gone, or fold one
    /// reading in at nearly full weight and leave the spread blown up.
    func testAGapLongerThanTheTimeConstantReseeds() {
        var follower = LoudnessFollower()
        feed(&follower, seconds: 5) { 0.5 + 0.04 * sin(2 * .pi * 1.3 * $0) }
        XCTAssertEqual(follower.drive(loudness: 0.35, dt: 30), 0.5, accuracy: 1e-12)
        let after = feed(&follower, seconds: 1) { _ in 0.35 }
        for drive in after { XCTAssertEqual(drive, 0.5, accuracy: 1e-9) }
    }

    func testResetForgetsTheStatistics() {
        var follower = LoudnessFollower()
        feed(&follower, seconds: 5) { _ in 0.2 }
        follower.reset()
        XCTAssertTrue(follower.isSilent)
        XCTAssertEqual(follower.drive(loudness: 0.8, dt: tick), 0.5, accuracy: 1e-12)
    }
}
