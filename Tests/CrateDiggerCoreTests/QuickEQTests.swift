import XCTest
@testable import CrateDiggerCore

final class QuickEQTests: XCTestCase {

    private let range: ClosedRange<Double> = -12...12

    private func action(_ keyCode: UInt16, _ characters: String? = nil,
                        command: Bool = false) -> QuickEQ.Action? {
        QuickEQ.action(keyCode: keyCode, characters: characters, hasCommandModifier: command)
    }

    func testUpDownArrowsAndWSNudge() {
        XCTAssertEqual(action(126), .nudge(.up))
        XCTAssertEqual(action(125), .nudge(.down))
        XCTAssertEqual(action(13, "w"), .nudge(.up))
        XCTAssertEqual(action(1, "s"), .nudge(.down))
    }

    func testLeftRightArrowsAndADSelectTheNeighbour() {
        XCTAssertEqual(action(123), .select(offset: -1))
        XCTAssertEqual(action(124), .select(offset: 1))
        XCTAssertEqual(action(0, "a"), .select(offset: -1))
        XCTAssertEqual(action(2, "d"), .select(offset: 1))
    }

    func testCapitalLettersStillCount() {
        XCTAssertEqual(action(13, "W"), .nudge(.up))
        XCTAssertEqual(action(1, "S"), .nudge(.down))
        XCTAssertEqual(action(0, "A"), .select(offset: -1))
        XCTAssertEqual(action(2, "D"), .select(offset: 1))
    }

    /// The letters are letters, not positions: on AZERTY the W is where Z
    /// sits on QWERTY and the A where Q sits, and the keys typing "z" and "q"
    /// must not move anything.
    func testLettersFollowTheLayoutNotTheKeyPosition() {
        XCTAssertNil(action(13, "z"))
        XCTAssertNil(action(0, "q"))
        XCTAssertEqual(action(6, "w"), .nudge(.up))
        XCTAssertEqual(action(12, "a"), .select(offset: -1))
    }

    func testCommandKeysPassThrough() {
        XCTAssertNil(action(13, "w", command: true))   // ⌘W closes
        XCTAssertNil(action(0, "a", command: true))    // ⌘A selects all
        XCTAssertNil(action(126, command: true))
        XCTAssertNil(action(123, command: true))
    }

    func testOtherKeysAreNotQuickEQ() {
        XCTAssertNil(action(49, " "))   // Space plays
        XCTAssertNil(action(36, "\r"))  // Return
        XCTAssertNil(action(14, "e"))
    }

    func testSelectionStepsOneFaderAndStopsAtTheEnds() {
        XCTAssertEqual(QuickEQ.band(4, offsetBy: 1, count: 10), 5)
        XCTAssertEqual(QuickEQ.band(4, offsetBy: -1, count: 10), 3)
        XCTAssertEqual(QuickEQ.band(9, offsetBy: 1, count: 10), 9)
        XCTAssertEqual(QuickEQ.band(0, offsetBy: -1, count: 10), 0)
    }

    func testNudgeMovesHalfADecibel() {
        XCTAssertEqual(QuickEQ.nudged(0, .up, in: range), 0.5)
        XCTAssertEqual(QuickEQ.nudged(0, .down, in: range), -0.5)
        XCTAssertEqual(QuickEQ.nudged(-3.5, .up, in: range), -3)
    }

    func testNudgeStopsAtTheEndsOfTravel() {
        XCTAssertEqual(QuickEQ.nudged(12, .up, in: range), 12)
        XCTAssertEqual(QuickEQ.nudged(-12, .down, in: range), -12)
        XCTAssertEqual(QuickEQ.nudged(11.75, .up, in: range), 12)
    }

    /// An imported curve can sit between grid points. One press lands on the
    /// next point that way, never jumps past it or stays put.
    func testOffGridGainLandsOnTheNextGridPointThatWay() {
        XCTAssertEqual(QuickEQ.nudged(1.2, .up, in: range), 1.5)
        XCTAssertEqual(QuickEQ.nudged(1.2, .down, in: range), 1.0)
        XCTAssertEqual(QuickEQ.nudged(-1.2, .down, in: range), -1.5)
        XCTAssertEqual(QuickEQ.nudged(-1.2, .up, in: range), -1.0)
    }

    func testQuickEQPreferenceDefaultsOffAndPersists() {
        let defaults = makeScratchDefaults()
        XCTAssertFalse(PreferencesStore(defaults: defaults).quickEQEnabled)
        PreferencesStore(defaults: defaults).quickEQEnabled = true
        XCTAssertTrue(PreferencesStore(defaults: defaults).quickEQEnabled)
    }
}
