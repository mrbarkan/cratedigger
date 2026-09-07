import XCTest
@testable import CrateDiggerCore

final class MiniPlayerPanelTests: XCTestCase {
    func testARecordPlayingOpensOnUpNext() {
        XCTAssertEqual(MiniPlayerPanelTab.initial(isPlaying: true, isStream: false), .upNext)
    }

    func testNothingPlayingOpensOnSources() {
        XCTAssertEqual(MiniPlayerPanelTab.initial(isPlaying: false, isStream: false), .sources)
    }

    /// A stream has no queue, so Up Next would be an empty face.
    func testAStreamOpensOnSources() {
        XCTAssertEqual(MiniPlayerPanelTab.initial(isPlaying: true, isStream: true), .sources)
    }

    func testThePanelIsOutWhenThereIsNothingToShowOtherwise() {
        XCTAssertTrue(MiniPlayerPanelTab.opensExpanded(isPlaying: false))
        XCTAssertFalse(MiniPlayerPanelTab.opensExpanded(isPlaying: true))
    }
}
