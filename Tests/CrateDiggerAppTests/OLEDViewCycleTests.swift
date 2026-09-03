#if canImport(XCTest)
import XCTest
@testable import CrateDiggerApp

/// The DISPLAY key walks the screens a user chooses; SEARCH is summoned by
/// a query and must never appear in the walk, and STATS is the last stop.
final class OLEDViewCycleTests: XCTestCase {

    func testTheDisplayCycleEndsOnStatsAndSkipsSearch() {
        XCTAssertEqual(DisplayModeButton.cycle.last, .stats)
        XCTAssertFalse(DisplayModeButton.cycle.contains(.search))
        XCTAssertEqual(DisplayModeButton.cycle.count, Set(DisplayModeButton.cycle).count, "no screen twice")
    }

    func testEveryScreenHasARailLabel() {
        for view in OLEDView.allCases {
            XCTAssertFalse(view.label.isEmpty, "\(view) has no label")
        }
    }
}
#endif
