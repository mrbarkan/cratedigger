#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class AmbientSettingsTests: XCTestCase {

    func testDefaults() {
        let settings = AmbientSettings.defaults
        XCTAssertNil(settings.inputUID, "nil follows the system default input")
        XCTAssertEqual(settings.level, AmbientLevelCurve.unityPosition)
        XCTAssertEqual(settings.delay, .balanced)
        XCTAssertTrue(settings.lowCut)
        XCTAssertEqual(settings.engine, .split)
        XCTAssertTrue(settings.callModeApprovedUIDs.isEmpty)
    }

    func testDelaySettingsGrowFromLiveToSmooth() {
        XCTAssertEqual(AmbientDelay.live.seconds, 0.010, accuracy: 0.0001)
        XCTAssertEqual(AmbientDelay.balanced.seconds, 0.030, accuracy: 0.0001)
        XCTAssertEqual(AmbientDelay.smooth.seconds, 0.080, accuracy: 0.0001)
    }

    /// A blob saved by a build that knew fewer fields keeps what it has instead
    /// of resetting every setting to the default.
    func testDecodingFillsMissingFieldsWithDefaults() throws {
        let json = Data(#"{"level":0.5,"engine":"combined"}"#.utf8)
        let settings = try JSONDecoder().decode(AmbientSettings.self, from: json)
        XCTAssertEqual(settings.level, 0.5)
        XCTAssertEqual(settings.engine, .combined)
        XCTAssertEqual(settings.delay, .balanced)
        XCTAssertTrue(settings.lowCut)
        XCTAssertNil(settings.inputUID)
    }

    func testPreferencesRoundTrip() {
        let suite = "AmbientSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(PreferencesStore(defaults: defaults).ambientSettings, .defaults)

        var settings = AmbientSettings.defaults
        settings.inputUID = "AppleUSBAudioEngine:Blue:Yeti"
        settings.level = 0.9
        settings.delay = .smooth
        settings.lowCut = false
        settings.engine = .combined
        settings.callModeApprovedUIDs = ["AC-80-0A-11-22-33:input"]
        PreferencesStore(defaults: defaults).ambientSettings = settings

        XCTAssertEqual(PreferencesStore(defaults: defaults).ambientSettings, settings)
    }
}
#endif
