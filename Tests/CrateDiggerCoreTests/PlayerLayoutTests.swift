#if canImport(XCTest)
import CoreGraphics
import XCTest
@testable import CrateDiggerCore

final class PlayerLayoutTests: XCTestCase {
    func testRawValuesAreStableBecauseTheyArePersisted() {
        XCTAssertEqual(PlayerLayout.full.rawValue, "full")
        XCTAssertEqual(PlayerLayout.compact.rawValue, "compact")
    }

    func testLaunchFollowsSavedLayoutWhenLibraryChosen() {
        XCTAssertEqual(PlayerLayout.launchLayout(saved: .compact, libraryChosen: true), .compact)
        XCTAssertEqual(PlayerLayout.launchLayout(saved: .full, libraryChosen: true), .full)
        XCTAssertEqual(PlayerLayout.launchLayout(saved: nil, libraryChosen: true), .full)
    }

    func testLaunchIsFullWhenNoLibraryChosen() {
        for saved in [nil, PlayerLayout.full, .compact] {
            XCTAssertEqual(PlayerLayout.launchLayout(saved: saved, libraryChosen: false), .full)
        }
    }

    func testPreferenceRoundTripsAndUnknownReadsAsNil() {
        let defaults = makeScratchDefaults()
        let prefs = PreferencesStore(defaults: defaults)
        XCTAssertNil(prefs.playerLayout)
        prefs.playerLayout = .compact
        XCTAssertEqual(prefs.playerLayout, .compact)
        defaults.set("portrait", forKey: "cratedigger.ui.playerLayout")
        XCTAssertNil(prefs.playerLayout)
        prefs.playerLayout = nil
        XCTAssertNil(defaults.object(forKey: "cratedigger.ui.playerLayout"))
    }

    func testCompactFrameIsStoredApartFromTheFullFrame() {
        let prefs = PreferencesStore(defaults: makeScratchDefaults())
        let full = CGRect(x: 10, y: 20, width: 1400, height: 920)
        let compact = CGRect(x: 30, y: 40, width: 1300, height: 302)
        prefs.savedWindowFrame = full
        prefs.savedCompactWindowFrame = compact
        XCTAssertEqual(prefs.savedWindowFrame, full)
        XCTAssertEqual(prefs.savedCompactWindowFrame, compact)
        prefs.savedCompactWindowFrame = nil
        XCTAssertNil(prefs.savedCompactWindowFrame)
        XCTAssertEqual(prefs.savedWindowFrame, full)
    }
}
#endif
