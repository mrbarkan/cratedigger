import XCTest
@testable import CrateDiggerCore

final class ValueDiffTests: XCTestCase {
    func testEqualValuesHaveNoChangedSpan() {
        let (current, proposed) = ValueDiff.split(current: "Backdrifts.", proposed: "Backdrifts.")
        XCTAssertTrue(current.isEmpty)
        XCTAssertTrue(proposed.isEmpty)
        XCTAssertEqual(current.head, "Backdrifts.")
    }

    /// The case that started this: one letter differs, and the highlight must
    /// land on the word rather than the letter.
    func testCasingChangeHighlightsTheWord() {
        let (current, proposed) = ValueDiff.split(
            current: "Sit Down. Stand up. (Snakes & Ladders.)",
            proposed: "Sit Down. Stand Up. (Snakes & Ladders.)"
        )
        XCTAssertEqual(current.head, "Sit Down. Stand ")
        XCTAssertEqual(current.changed, "up.")
        XCTAssertEqual(current.tail, " (Snakes & Ladders.)")
        XCTAssertEqual(proposed.changed, "Up.")
        XCTAssertEqual(proposed.head, current.head)
        XCTAssertEqual(proposed.tail, current.tail)
    }

    func testWhollyDifferentValuesHighlightEverything() {
        let (current, proposed) = ValueDiff.split(
            current: "We Suck Young Blood.",
            proposed: "Scatterbrain."
        )
        XCTAssertEqual(current.changed, "We Suck Young Blood.")
        XCTAssertEqual(proposed.changed, "Scatterbrain.")
        XCTAssertEqual(current.head, "")
        XCTAssertEqual(current.tail, "")
    }

    func testEmptyCurrentValue() {
        let (current, proposed) = ValueDiff.split(current: "", proposed: "Pyramid Song")
        XCTAssertTrue(current.isEmpty)
        XCTAssertEqual(proposed.changed, "Pyramid Song")
    }

    /// Every split must be lossless: the three parts rebuild the input.
    func testSplitsAreLossless() {
        let pairs = [
            ("Idioteque", "Idioteque (Remastered)"),
            ("2 + 2 = 5", "2 + 2 = 5. (The Lukewarm.)"),
            ("A", "B"),
            ("", ""),
            ("Kid A", "Kid A")
        ]
        for (a, b) in pairs {
            let (current, proposed) = ValueDiff.split(current: a, proposed: b)
            XCTAssertEqual(current.head + current.changed + current.tail, a)
            XCTAssertEqual(proposed.head + proposed.changed + proposed.tail, b)
        }
    }
}
