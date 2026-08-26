#if canImport(XCTest)
import XCTest
@testable import CrateDiggerApp

/// `Bundle.module` traps when the SPM resource bundle isn't where the
/// generated accessor expects — which is exactly what a packaged `.app` does,
/// and what crashed 1.5.5 on launch. These pin the replacement: find it
/// wherever it actually sits, and return nil instead of dying when it's gone.
final class ResourceBundleTests: XCTestCase {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResourceBundleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testFindsResourceBundleInFirstSearchedBase() throws {
        let base = try makeTemporaryDirectory()
        let bundleURL = base.appendingPathComponent("CrateDigger_CrateDiggerApp.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let found = Bundle.resourceBundle(searching: [base])
        XCTAssertEqual(found?.bundleURL.resolvingSymlinksInPath(), bundleURL.resolvingSymlinksInPath())
    }

    /// The packaged-.app layout: nothing at the bundle root, the resources one
    /// level down in Contents/Resources. `Bundle.module` looked only at the
    /// root and trapped.
    func testFallsThroughToLaterSearchBase() throws {
        let root = try makeTemporaryDirectory()
        let resources = root.appendingPathComponent("Contents/Resources", isDirectory: true)
        let bundleURL = resources.appendingPathComponent("CrateDigger_CrateDiggerApp.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let found = Bundle.resourceBundle(searching: [root, resources])
        XCTAssertEqual(found?.bundleURL.resolvingSymlinksInPath(), bundleURL.resolvingSymlinksInPath())
    }

    func testReturnsNilWhenNoResourceBundleExists() throws {
        let base = try makeTemporaryDirectory()
        XCTAssertNil(Bundle.resourceBundle(searching: [base]))
    }

    func testToleratesMissingSearchBase() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        XCTAssertNil(Bundle.resourceBundle(searching: [missing]))
    }

    /// The regression guard the unit tests above can't be: `Bundle.module`
    /// works under `swift run` and traps in the packaged `.app`, so nothing
    /// short of packaging catches it at runtime. Reading the source is cheaper.
    func testAppTargetNeverUsesBundleModule() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CrateDiggerAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/CrateDiggerApp", isDirectory: true)

        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "found no app sources to scan")

        // `.module` rather than `Bundle.module`: the call site that shipped the
        // crash was `[.main, .module]`. Comment lines are dropped so the
        // explanations of *why* it's banned don't trip the ban.
        let offenders = try files.filter { file in
            try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .contains { $0.contains(".module") }
        }
        XCTAssertEqual(
            offenders.map(\.lastPathComponent),
            [],
            "use Bundle.crateDiggerResources — Bundle.module traps in the packaged .app"
        )
    }
}
#endif
