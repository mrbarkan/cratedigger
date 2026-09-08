import XCTest
@testable import CrateDiggerCore

final class TransferLogLineTests: XCTestCase {

    func testParsesTaggedLinesAndSplitsThePath() {
        let lines = TransferLogLine.parse(
            "[ok] Music/Led Zeppelin/1969 Led Zeppelin/01 - Good Times Bad Times.m4a"
        )
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].outcome, .ok)
        XCTAssertEqual(lines[0].outcome.badge, "OK")
        XCTAssertEqual(lines[0].name, "01 - Good Times Bad Times.m4a")
        XCTAssertEqual(lines[0].parent, "Music/Led Zeppelin/1969 Led Zeppelin")
        XCTAssertNil(lines[0].note)
    }

    func testSkipCarriesItsReasonAsANote() {
        let lines = TransferLogLine.parse("[skip] Music/a.m4a — already on device")
        XCTAssertEqual(lines[0].outcome, .skipped)
        XCTAssertEqual(lines[0].note, "already on device")
        XCTAssertEqual(lines[0].path, "Music/a.m4a")
    }

    func testFailureFoldsItsIndentedReasonIntoTheSameEntry() {
        let lines = TransferLogLine.parse("""
        [ok] Music/a.m4a
        [FAILED] Music/b.m4a
            Source file missing
        """)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[1].outcome, .failed)
        XCTAssertEqual(lines[1].note, "Source file missing")
    }

    func testUntaggedLineSurvivesAsPlainText() {
        let lines = TransferLogLine.parse("Nothing to report")
        XCTAssertEqual(lines[0].outcome, .other)
        XCTAssertNil(lines[0].outcome.badge)
        XCTAssertEqual(lines[0].name, "Nothing to report")
        XCTAssertEqual(lines[0].parent, "")
    }
}
