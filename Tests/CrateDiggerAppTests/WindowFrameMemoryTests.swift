#if canImport(XCTest)
import CoreGraphics
import CrateDiggerCore
import XCTest
@testable import CrateDiggerApp

final class WindowFrameMemoryTests: XCTestCase {
    private func scratchPrefs() -> PreferencesStore {
        let suite = "CrateDiggerScratch.WindowFrameMemoryTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return PreferencesStore(defaults: defaults)
    }

    /// The window's own launch-time setFrame posts windowDidMove before the
    /// saved frame has been applied; recording it overwrote the user's frame
    /// with the centred default on every launch.
    func testFramesReportedBeforeLaunchRestoreAreNotRecorded() {
        let prefs = scratchPrefs()
        let saved = CGRect(x: 300, y: 200, width: 1500, height: 950)
        prefs.savedWindowFrame = saved
        let memory = WindowFrameMemory(prefs: prefs)

        memory.record(CGRect(x: 56, y: 28, width: 1400, height: 892), for: .full)

        XCTAssertEqual(prefs.savedWindowFrame, saved)
        XCTAssertEqual(memory.saved(for: .full), saved)
    }

    func testOnceArmedEachLayoutWritesItsOwnSlot() {
        let prefs = scratchPrefs()
        var memory = WindowFrameMemory(prefs: prefs)
        memory.arm()
        let full = CGRect(x: 10, y: 20, width: 1400, height: 920)
        let compact = CGRect(x: 10, y: 638, width: 1300, height: 302)

        memory.record(full, for: .full)
        memory.record(compact, for: .compact)

        XCTAssertEqual(prefs.savedWindowFrame, full)
        XCTAssertEqual(prefs.savedCompactWindowFrame, compact)
        XCTAssertEqual(memory.saved(for: .full), full)
        XCTAssertEqual(memory.saved(for: .compact), compact)
    }
}
#endif
