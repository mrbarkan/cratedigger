import XCTest
@testable import CrateDiggerCore

final class ProcessCommandRunnerPathTests: XCTestCase {
    func testAugmentedPathIncludesHomebrewWhenBaseLacksIt() {
        let result = ProcessCommandRunner.augmentedPATH(
            "/usr/bin:/bin",
            additionalDirectories: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        )
        let dirs = result.split(separator: ":").map(String.init)
        XCTAssertTrue(dirs.contains("/opt/homebrew/bin"), "must add the Homebrew dir where deno/node live")
        XCTAssertTrue(dirs.contains("/usr/bin"))
        // No duplicates (/usr/bin and /bin appear in both base and additional).
        XCTAssertEqual(dirs.count, Set(dirs).count, "no duplicate PATH entries")
    }

    func testAugmentedPathHandlesEmptyBase() {
        let result = ProcessCommandRunner.augmentedPATH(nil, additionalDirectories: ["/opt/homebrew/bin"])
        XCTAssertEqual(result, "/opt/homebrew/bin")
    }
}
