#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class BrowserLayoutTests: XCTestCase {
    func testRawValueRoundTrip() {
        XCTAssertEqual(BrowserLayout.allCases.count, 3)
        for layout in BrowserLayout.allCases {
            XCTAssertEqual(BrowserLayout(rawValue: layout.rawValue), layout)
            XCTAssertFalse(layout.title.isEmpty)
            XCTAssertFalse(layout.iconName.isEmpty)
        }
    }

    func testRawValuesAreStable() {
        // These persist to UserDefaults — they must not drift.
        XCTAssertEqual(BrowserLayout.full.rawValue, "full")
        XCTAssertEqual(BrowserLayout.albumTrack.rawValue, "albumTrack")
        XCTAssertEqual(BrowserLayout.track.rawValue, "track")
    }
}
#endif
