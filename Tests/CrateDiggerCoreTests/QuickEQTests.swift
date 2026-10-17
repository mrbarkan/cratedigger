import XCTest
@testable import CrateDiggerCore

final class QuickEQTests: XCTestCase {

    private let range: ClosedRange<Double> = -12...12

    func testArrowsAndWSAreTheKeys() {
        XCTAssertEqual(QuickEQ.direction(keyCode: 126, characters: nil, hasCommandModifier: false), .up)
        XCTAssertEqual(QuickEQ.direction(keyCode: 125, characters: nil, hasCommandModifier: false), .down)
        XCTAssertEqual(QuickEQ.direction(keyCode: 13, characters: "w", hasCommandModifier: false), .up)
        XCTAssertEqual(QuickEQ.direction(keyCode: 1, characters: "s", hasCommandModifier: false), .down)
    }

    func testCapitalLettersStillCount() {
        XCTAssertEqual(QuickEQ.direction(keyCode: 13, characters: "W", hasCommandModifier: false), .up)
        XCTAssertEqual(QuickEQ.direction(keyCode: 1, characters: "S", hasCommandModifier: false), .down)
    }

    /// W and S are letters, not positions: on AZERTY the W is where Z sits on
    /// QWERTY, and that key typing "z" must not move a fader.
    func testLettersFollowTheLayoutNotTheKeyPosition() {
        XCTAssertNil(QuickEQ.direction(keyCode: 13, characters: "z", hasCommandModifier: false))
        XCTAssertEqual(QuickEQ.direction(keyCode: 6, characters: "w", hasCommandModifier: false), .up)
    }

    func testCommandKeysPassThrough() {
        XCTAssertNil(QuickEQ.direction(keyCode: 13, characters: "w", hasCommandModifier: true))   // ⌘W closes
        XCTAssertNil(QuickEQ.direction(keyCode: 126, characters: nil, hasCommandModifier: true))
    }

    func testOtherKeysAreNotQuickEQ() {
        XCTAssertNil(QuickEQ.direction(keyCode: 49, characters: " ", hasCommandModifier: false))  // Space plays
        XCTAssertNil(QuickEQ.direction(keyCode: 123, characters: nil, hasCommandModifier: false))
        XCTAssertNil(QuickEQ.direction(keyCode: 0, characters: "a", hasCommandModifier: false))
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
