#if canImport(XCTest)
import AppKit
import CrateDiggerCore
import SwiftUI
import XCTest
@testable import CrateDiggerApp

/// `monochromeGlass` collapses every accent onto the phosphor, but a pinned
/// token outranks the accent it falls back to. Llama '97 pins `meterHot` to
/// red and turns monochrome on, so unless the pin is cleared too, anything
/// on the glass that reads `meterHot` (a Busy Signals hot ink) draws red on
/// a green single-phosphor panel.
@MainActor
final class MonochromeGlassTests: XCTestCase {
    func testMonochromeGlassClearsThePinnedMeterHot() {
        let theme = Self.llamaLikeTheme()
        XCTAssertNotNil(theme.meterHotOverride, "precondition: the definition pins meterHot")
        XCTAssertTrue(theme.oledMonochrome, "precondition: the definition turns monochrome on")

        let glass = theme.monochromeGlass
        XCTAssertNil(glass.meterHotOverride)
        XCTAssertEqual(rgba(glass.meterHot), rgba(glass.oledForeground))
        XCTAssertEqual(rgba(glass.meterHotHi), rgba(glass.oledForeground))
    }

    /// Off the glass the pin still stands: only the monochrome copy drops it.
    func testThePinSurvivesOutsideTheGlass() {
        let theme = Self.llamaLikeTheme()
        XCTAssertEqual(rgba(theme.meterHot), RGBA(r: 1, g: 0, b: 0, a: 1))
    }

    /// Mirrors the bundled Llama '97 theme's two relevant lines.
    static func llamaLikeTheme() -> CarbonTheme {
        let definition = ThemeDefinition(
            id: "test-llama", name: "Test Llama", baseAppearance: .dark,
            colors: ["meterHot": "#FF0000", "oledForeground": "#00FF00", "cyan": "#00E23C"],
            effects: ["oledMonochrome": 1]
        )
        return CarbonTheme(definition: definition, resolvedBase: .carbon)
    }
}
#endif
