import XCTest
@testable import CrateDiggerApp

final class TitlebarDoubleClickTests: XCTestCase {
    func testUnsetSettingZooms() {
        XCTAssertEqual(TitlebarDoubleClick.action(forSetting: nil), .zoom)
    }

    func testMaximizeAndFillZoom() {
        XCTAssertEqual(TitlebarDoubleClick.action(forSetting: "Maximize"), .zoom)
        XCTAssertEqual(TitlebarDoubleClick.action(forSetting: "Fill"), .zoom)
    }

    func testMinimizeMinimizes() {
        XCTAssertEqual(TitlebarDoubleClick.action(forSetting: "Minimize"), .minimize)
    }

    func testNoneDoesNothing() {
        XCTAssertEqual(TitlebarDoubleClick.action(forSetting: "None"), .nothing)
    }

    func testAClickInTheStripCounts() {
        XCTAssertTrue(TitlebarDoubleClick.isInTitlebarStrip(pointY: 840, windowHeight: 850, contentLayoutMaxY: 818))
        XCTAssertTrue(TitlebarDoubleClick.isInTitlebarStrip(pointY: 818, windowHeight: 850, contentLayoutMaxY: 818))
    }

    /// The header keys sit below the strip; pressing one twice must not zoom.
    func testAClickBelowTheStripDoesNot() {
        XCTAssertFalse(TitlebarDoubleClick.isInTitlebarStrip(pointY: 800, windowHeight: 850, contentLayoutMaxY: 818))
    }

    func testAWindowWithNoTitlebarStripNeverCounts() {
        XCTAssertFalse(TitlebarDoubleClick.isInTitlebarStrip(pointY: 850, windowHeight: 850, contentLayoutMaxY: 850))
    }
}
