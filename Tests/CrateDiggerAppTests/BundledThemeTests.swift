#if canImport(XCTest)
import CrateDiggerCore
import SwiftUI
import XCTest
@testable import CrateDiggerApp

/// The four themes that ship with the app, read from the source folder they're
/// edited in.
///
/// A theme is data, so nothing in the compiler notices when a key is misspelt,
/// a hex is malformed, or a layer stops overriding what it used to — the app
/// just quietly renders the built-in default instead. These pin the parts that
/// would otherwise only be caught by looking at the window.
final class BundledThemeTests: XCTestCase {

    private var themes: [String: ThemeDefinition] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CrateDiggerAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/CrateDiggerApp/Resources/Themes", isDirectory: true)

        let result = ThemeLoaderService(bundles: [], userThemesDirectoryOverride: directory)
            .discoverThemes()

        XCTAssertEqual(result.warnings.map(\.message), [], "a bundled theme failed to parse")
        themes = Dictionary(uniqueKeysWithValues: result.themes.map { ($0.id, $0.definition) })
    }

    /// Every shipped theme follows the app's Light/Dark setting — Linen was
    /// folded into Carbon as its light layer precisely so none of them force an
    /// appearance on the user any more.
    func testEveryBundledThemeCarriesBothAppearances() {
        XCTAssertFalse(themes.isEmpty)
        for (id, definition) in themes {
            XCTAssertTrue(definition.isAdaptive, "\(id) is missing a light or dark layer")
        }
    }

    func testLinenIsGoneAndCarbonRendersBothLooks() throws {
        XCTAssertNil(themes["linen"], "Linen is Carbon's light layer now, not a theme of its own")

        let carbon = try XCTUnwrap(themes["carbon"])
        XCTAssertLessThan(render(carbon, .dark).chassis.themeLuminance, 0.2)
        XCTAssertGreaterThan(render(carbon, .light).chassis.themeLuminance, 0.8)
    }

    /// The screen is the skin's signature: black glass in both looks — phosphor
    /// green over the dark console, white type over the purple one. The glass
    /// is a shared token, so a layer that started overriding it (which is what
    /// inheriting an adaptive parent used to do) would light it in exactly one
    /// appearance and nobody would notice until they switched.
    func testLlamaScreenIsBlackInBothAppearances() throws {
        let llama = try XCTUnwrap(themes["llama-97"])
        for appearance in [ThemeDefinition.BaseAppearance.light, .dark] {
            XCTAssertEqual(render(llama, appearance).oledSurface.themeHexString, "#000000", "\(appearance)")
        }
        XCTAssertEqual(render(llama, .dark).oledForeground.themeHexString, "#00FF00")
        XCTAssertGreaterThan(render(llama, .light).oledForeground.themeLuminance, 0.8)
    }

    private func render(
        _ definition: ThemeDefinition,
        _ appearance: ThemeDefinition.BaseAppearance
    ) -> CarbonTheme {
        let resolved = definition.resolved(for: appearance)
        return CarbonTheme(definition: resolved, resolvedBase: appearance == .dark ? .carbon : .linen)
    }
}
#endif
