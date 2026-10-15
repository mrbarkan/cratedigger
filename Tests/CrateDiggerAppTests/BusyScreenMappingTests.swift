#if canImport(XCTest)
import XCTest
import CrateDiggerCore
@testable import CrateDiggerApp

/// Core cannot see `OLEDView`, so the ledger keeps its own mirror of the four
/// screens that host a job. These pin the two-way mapping: a screen that maps
/// wrong would put a mini on the job's own rail, or send a mini's click to the
/// wrong screen.
final class BusyScreenMappingTests: XCTestCase {

    func testEveryOLEDViewMapsToItsBusyScreen() {
        let expected: [OLEDView: BusyScreen] = [
            .dub: .dub, .conversion: .conversion, .scan: .scan, .devices: .devices,
            .nowPlaying: .other, .remoteSync: .other, .search: .other, .stats: .other,
        ]
        for view in OLEDView.allCases {
            XCTAssertEqual(view.busyScreen, expected[view], "\(view)")
        }
    }

    func testJobScreensMapBack() {
        for screen in BusyScreen.allCases where screen != .other {
            XCTAssertEqual(screen.oledView?.busyScreen, screen, "\(screen)")
        }
        XCTAssertNil(BusyScreen.other.oledView)
    }
}
#endif
