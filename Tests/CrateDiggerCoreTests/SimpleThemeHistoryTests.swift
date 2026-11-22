import XCTest
@testable import CrateDiggerCore

final class SimpleThemeHistoryTests: XCTestCase {
    private func state(_ palette: [String] = ["#202830", "#E8E0D0", "#D04020"]) -> SimpleThemeState {
        SimpleThemeState(recipe: SimpleThemeRecipe(palette: palette))
    }

    func testCapacity20() {
        var history = SimpleThemeHistory(state())
        var s = state()
        for i in 0..<30 {
            s.setColor(String(format: "#%02X%02X%02X", i, 40, 90), at: 0)
            history.push(s)
        }
        var steps = 0
        while history.canGoBack { history.back(); steps += 1 }
        XCTAssertEqual(steps, 19, "20 states held, so 19 steps back")
    }

    func testBackForwardReturnExactStates() {
        let a = state()
        var b = a; b.setColor("#102030", at: 1)
        var c = b; c.contrast = .high
        var history = SimpleThemeHistory(a)
        history.push(b); history.push(c)
        XCTAssertEqual(history.current, c)
        history.back(); XCTAssertEqual(history.current, b)
        history.back(); XCTAssertEqual(history.current, a)
        XCTAssertFalse(history.canGoBack)
        history.forward(); history.forward()
        XCTAssertEqual(history.current, c)
        XCTAssertFalse(history.canGoForward)
    }

    func testPushAfterBackDropsForward() {
        let a = state()
        var b = a; b.setColor("#102030", at: 1)
        var c = a; c.setColor("#304050", at: 2)
        var history = SimpleThemeHistory(a)
        history.push(b)
        history.back()
        history.push(c)
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.current, c)
    }

    func testPushingEqualStateIsNoOp() {
        let a = state()
        var history = SimpleThemeHistory(a)
        history.push(a)
        XCTAssertFalse(history.canGoBack)
    }

    func testRemovingPinnedSwatch() {
        var s = state(["#202830", "#E8E0D0", "#D04020", "#40A070"])
        s.pin(.glass, to: 3)
        s.pin(.frame, to: 1)
        var history = SimpleThemeHistory(s)
        s.removeColor(at: 1)
        history.push(s)
        XCTAssertEqual(s.palette.count, 3)
        XCTAssertNil(s.pins[.frame], "the pin on the removed swatch drops")
        XCTAssertEqual(s.pins[.glass], 2, "a later pin follows its swatch down")
        for job in ThemeJob.allCases {
            if let entry = s.assignment[job], let index = entry {
                XCTAssertTrue(s.palette.indices.contains(index), "\(job) has a stale index")
            }
        }
        XCTAssertEqual(s.assignment[.glass] ?? nil, 2)
        history.back()
        XCTAssertEqual(history.current.palette.count, 4)
        XCTAssertEqual(history.current.pins[.frame], 1)
        XCTAssertEqual(history.current.pins[.glass], 3)
    }

    func testStateBoundsAndRoundTrip() {
        var s = state(["#202830", "#E8E0D0"])
        s.removeColor(at: 0)
        XCTAssertEqual(s.palette.count, 2, "never fewer than 2")
        for _ in 0..<8 { s.addColor("#808080") }
        XCTAssertEqual(s.palette.count, 6)
        XCTAssertEqual(SimpleThemeState(recipe: s.recipe), s)
    }

    func testShuffleKeepsContrastAndPins() {
        var s = state(["#202830", "#E8E0D0", "#D04020", "#40A070"])
        s.contrast = .high
        s.pin(.accent, to: 2)
        for _ in 0..<5 {
            s.shuffle()
            XCTAssertEqual(s.contrast, .high)
            XCTAssertEqual(s.assignment[.accent] ?? nil, 2)
        }
    }
}
