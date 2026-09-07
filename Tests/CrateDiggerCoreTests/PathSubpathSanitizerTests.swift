#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

/// A relative subpath is the one place a user-typed string is joined onto a
/// destination root. It must never be able to climb out of that root, and
/// there must be exactly one implementation of that rule — the album-folder
/// review sheet and the external-device profile each had their own, and each
/// was missing something the other had.
final class PathSubpathSanitizerTests: XCTestCase {

    // MARK: - Climbing out

    func testDotDotComponentsAreDropped() {
        XCTAssertEqual(
            PathComponentSanitizer.sanitizeSubpath("../../etc", fallback: "Fallback"),
            "etc"
        )
    }

    func testAPathThatIsNothingButTraversalFallsBack() {
        XCTAssertEqual(
            PathComponentSanitizer.sanitizeSubpath("../..", fallback: "Fallback"),
            "Fallback"
        )
        XCTAssertEqual(
            PathComponentSanitizer.sanitizeSubpath("./././", fallback: "Fallback"),
            "Fallback"
        )
    }

    func testTraversalBuriedMidPathIsDropped() {
        XCTAssertEqual(
            PathComponentSanitizer.sanitizeSubpath("Miles Davis/../../../Kind of Blue",
                                                   fallback: "Fallback"),
            "Miles Davis/Kind of Blue"
        )
    }

    func testALeadingSlashDoesNotMakeItAbsolute() {
        XCTAssertEqual(
            PathComponentSanitizer.sanitizeSubpath("/Volumes/Other/Thing", fallback: "Fallback"),
            "Volumes/Other/Thing"
        )
    }

    // MARK: - Ordinary cleaning

    func testKeepsRealFolderStructure() {
        XCTAssertEqual(
            PathComponentSanitizer.sanitizeSubpath("Miles Davis/Kind of Blue", fallback: "F"),
            "Miles Davis/Kind of Blue"
        )
    }

    func testEmptyComponentsCollapse() {
        XCTAssertEqual(
            PathComponentSanitizer.sanitizeSubpath("A//B///C", fallback: "F"),
            "A/B/C"
        )
    }

    func testWhitespaceRunsCollapseInsideEachComponent() {
        XCTAssertEqual(
            PathComponentSanitizer.sanitizeSubpath("Miles    Davis/  Kind   of Blue  ", fallback: "F"),
            "Miles Davis/Kind of Blue"
        )
    }

    func testHiddenComponentsLoseTheirLeadingDot() {
        XCTAssertEqual(
            PathComponentSanitizer.sanitizeSubpath(".hidden/.also", fallback: "F"),
            "hidden/also"
        )
    }

    func testColonsAndBackslashesBecomeHyphens() {
        XCTAssertEqual(
            PathComponentSanitizer.sanitizeSubpath("AC:DC/Back\\In Black", fallback: "F"),
            "AC-DC/Back-In Black"
        )
    }

    func testEmptyInputFallsBack() {
        XCTAssertEqual(PathComponentSanitizer.sanitizeSubpath("", fallback: "Fallback"), "Fallback")
        XCTAssertEqual(PathComponentSanitizer.sanitizeSubpath("   ", fallback: "Fallback"), "Fallback")
    }

    // MARK: - The device profile folds onto the same rule

    func testDeviceProfileSubpathCannotClimbOut() {
        XCTAssertEqual(ExternalDeviceProfile.normalizedSubpath("../../Music"), "Music")
        XCTAssertEqual(ExternalDeviceProfile.normalizedSubpath(".."), "")
    }

    func testDeviceProfileSubpathKeepsWorkingAsBefore() {
        XCTAssertEqual(ExternalDeviceProfile.normalizedSubpath("Music"), "Music")
        XCTAssertEqual(ExternalDeviceProfile.normalizedSubpath("/Music/Imports/"), "Music/Imports")
        XCTAssertEqual(ExternalDeviceProfile.normalizedSubpath(""), "")
        XCTAssertEqual(ExternalDeviceProfile.normalizedSubpath("My   Music"), "My Music")
    }

    // MARK: - The single-component sanitiser still behaves

    func testSingleComponentSanitizeIsUnchanged() {
        XCTAssertEqual(PathComponentSanitizer.sanitize(".", fallback: "Fallback"), "Fallback")
        XCTAssertEqual(PathComponentSanitizer.sanitize("..", fallback: "Fallback"), "Fallback")
        XCTAssertEqual(PathComponentSanitizer.sanitize(". .", fallback: "Fallback"), "Fallback")
        XCTAssertEqual(PathComponentSanitizer.sanitize(".hidden", fallback: "Fallback"), "hidden")
        XCTAssertEqual(PathComponentSanitizer.sanitize("a/b", fallback: "Fallback"), "a-b")
    }
}
#endif
