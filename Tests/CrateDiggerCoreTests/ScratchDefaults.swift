import Foundation
import XCTest

extension XCTestCase {
    /// An isolated, empty `UserDefaults` for one test.
    ///
    /// **Use this instead of `UserDefaults(suiteName:)` in tests.** A suite
    /// named per *run* — `"test.\(UUID())"` — leaks a preferences file every
    /// time the suite executes, and there is no way to take it back:
    /// `removePersistentDomain(forName:)` empties the domain but leaves the
    /// file, and deleting the file by hand does not stick either, because
    /// `cfprefsd` flushes its cached copy back to disk afterwards. This repo
    /// had left four thousand of them on the machine it was developed on,
    /// which was most of the preference domains on that machine.
    ///
    /// So the suite is named per test *class* and reused: the file is created
    /// once and then rewritten, rather than multiplied. Each call still hands
    /// back an empty domain, and empties it again afterwards, so tests stay
    /// isolated from each other and leave no values behind — the only residue
    /// is one small empty plist per class, which stays one no matter how often
    /// the suite runs.
    func makeScratchDefaults() -> UserDefaults {
        let suiteName = Self.scratchSuiteName
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not open the scratch suite \(suiteName)")
            return .standard
        }
        // Empty going in as well as coming out: a test that crashes mid-way
        // must not hand its values to the next one.
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    /// `CrateDiggerScratch.<TestClass>` — one per class, so classes stay
    /// isolated from each other even if they ever run in parallel, and a
    /// stray file names the class that made it.
    static var scratchSuiteName: String {
        "CrateDiggerScratch.\(String(describing: self))"
    }
}
