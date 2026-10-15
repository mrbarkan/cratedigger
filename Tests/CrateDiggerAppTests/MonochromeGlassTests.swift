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

/// sRGB components rounded to 1/1000, so two colours built different ways
/// (a hex string, a `Color(red:…)`, an `.opacity` modifier) compare by what
/// they draw rather than by how they were constructed.
struct RGBA: Equatable, CustomStringConvertible {
    var r, g, b, a: Double

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    var description: String { String(format: "rgba(%.3f, %.3f, %.3f, %.3f)", r, g, b, a) }
}

func rgba(_ color: Color) -> RGBA {
    let ns = NSColor(color).usingColorSpace(.sRGB) ?? .clear
    func round3(_ v: CGFloat) -> Double { (Double(v) * 1000).rounded() / 1000 }
    return RGBA(r: round3(ns.redComponent), g: round3(ns.greenComponent),
                b: round3(ns.blueComponent), a: round3(ns.alphaComponent))
}
#endif
