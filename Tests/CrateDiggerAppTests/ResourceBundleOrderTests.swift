import XCTest
@testable import CrateDiggerApp

/// A `swift build` tree grows a resource bundle per test target the moment
/// anyone runs the suite, so "the bundle beside the binary" stops being one
/// bundle. Picking whichever the filesystem listed first handed callers the
/// test bundle — no Fonts, no Themes — and every custom face fell back to the
/// system font for the rest of the session, silently, and only on machines
/// where the tests had been run.
final class ResourceBundleOrderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cd-bundle-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Bundle(url:) only succeeds for a directory, which is all these need to
    /// be — the ordering is by name, not by content.
    private func makeBundle(_ name: String) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(name), withIntermediateDirectories: true
        )
    }

    func testTestBundlesSortAfterTheRealOnes() throws {
        // "CoreTests" sorts before "App" alphabetically, which is exactly how
        // the bug used to win.
        try makeBundle("CrateDigger_CrateDiggerCoreTests.bundle")
        try makeBundle("CrateDigger_CrateDiggerApp.bundle")

        let names = Bundle.resourceBundles(searching: [root]).map(\.bundleURL.lastPathComponent)
        XCTAssertEqual(names, [
            "CrateDigger_CrateDiggerApp.bundle",
            "CrateDigger_CrateDiggerCoreTests.bundle"
        ])
        XCTAssertEqual(
            Bundle.resourceBundle(searching: [root])?.bundleURL.lastPathComponent,
            "CrateDigger_CrateDiggerApp.bundle",
            "the app's own bundle is what a caller asking for fonts means"
        )
    }

    func testEveryBundleIsReturnedSoCallersCanSearchThemAll() throws {
        try makeBundle("A.bundle")
        try makeBundle("B.bundle")
        XCTAssertEqual(Bundle.resourceBundles(searching: [root]).count, 2)
    }

    /// The two bases overlap in a packaged `.app`, where `resourceURL` sits
    /// inside `bundleURL`; the same bundle must not come back twice.
    func testTheSameBundleIsNotListedTwice() throws {
        try makeBundle("Only.bundle")
        XCTAssertEqual(Bundle.resourceBundles(searching: [root, root]).count, 1)
    }

    func testNoBundlesIsEmptyRatherThanAFailure() throws {
        XCTAssertTrue(Bundle.resourceBundles(searching: [root]).isEmpty)
        XCTAssertNil(Bundle.resourceBundle(searching: [root]))
    }
}
