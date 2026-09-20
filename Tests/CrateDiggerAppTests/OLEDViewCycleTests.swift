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

    /// `savedOLEDView` persists the raw value, so renaming `cdRip` to `dub`
    /// would have silently thrown away the saved screen of everyone sitting on
    /// it. The case keeps its old raw value; this is what stops a later tidy-up
    /// from dropping the `= "cdRip"` and breaking that quietly.
    func testRenamedScreensKeepTheirPersistedRawValue() {
        XCTAssertEqual(OLEDView.dub.rawValue, "cdRip")
        XCTAssertEqual(OLEDView(rawValue: "cdRip"), .dub)
    }

    func testEveryScreenHasALabel() {
        for view in OLEDView.allCases {
            XCTAssertFalse(view.label.isEmpty, "\(view) has no label")
        }
    }
}
#endif
