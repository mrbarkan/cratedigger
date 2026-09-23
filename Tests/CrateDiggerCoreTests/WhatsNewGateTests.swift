#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class WhatsNewGateTests: XCTestCase {
    private func store(lastSeen: String?) -> PreferencesStore {
        let prefs = PreferencesStore(defaults: makeScratchDefaults())
        prefs.hasSeenWelcomeTour = true
        prefs.lastWhatsNewVersion = lastSeen
        return prefs
    }

    func testPatchReleaseDoesNotReshowTheSameList() {
        XCTAssertFalse(store(lastSeen: "2.2.0").shouldShowWhatsNew(for: "2.2.1"))
    }

    func testFeatureReleaseShowsTheNewList() {
        XCTAssertTrue(store(lastSeen: "2.2.1").shouldShowWhatsNew(for: "2.3.0"))
        XCTAssertTrue(store(lastSeen: "2.9.4").shouldShowWhatsNew(for: "3.0.0"))
    }

    func testUpgraderWhoNeverDismissedOneSeesIt() {
        XCTAssertTrue(store(lastSeen: nil).shouldShowWhatsNew(for: "2.2.1"))
    }

    func testFirstRunGetsTheTourInstead() {
        let prefs = PreferencesStore(defaults: makeScratchDefaults())
        XCTAssertFalse(prefs.shouldShowWhatsNew(for: "2.2.1"))
    }
}
#endif
