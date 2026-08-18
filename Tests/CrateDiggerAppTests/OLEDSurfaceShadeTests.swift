#if canImport(XCTest)
import AppKit
import CrateDiggerCore
import SwiftUI
import XCTest
@testable import CrateDiggerApp

/// `oledSurfaceShade` is the one token whose default is *computed* rather than
/// inherited: the fixed 28% black rake that gives a black screen its depth
/// turned a pale glass (a theme's light layer) into a grey smear.
final class OLEDSurfaceShadeTests: XCTestCase {
    func testDarkGlassKeepsTheFullShade() {
        XCTAssertEqual(shadeAlpha(glass: "#050504"), 0.28, accuracy: 0.01)
    }

    func testLightGlassGetsASofterShade() {
        XCTAssertLessThan(shadeAlpha(glass: "#E4E4E4"), 0.1)
    }

    /// The theme always wins — that's the point of exposing it as a token.
    func testExplicitShadeOverridesBothDefaults() {
        XCTAssertEqual(shadeAlpha(glass: "#E4E4E4", shade: "#0000FF80"), 0.5, accuracy: 0.01)
        XCTAssertEqual(shadeAlpha(glass: "#050504", shade: "#0000FF80"), 0.5, accuracy: 0.01)
    }

    /// A theme that names no glass at all inherits the base theme's, shade included.
    func testNoOverridesInheritsTheBase() {
        XCTAssertEqual(shadeAlpha(glass: nil), alpha(of: CarbonTheme.carbon.oledSurfaceShade), accuracy: 0.001)
    }

    private func shadeAlpha(glass: String?, shade: String? = nil) -> Double {
        var colors: [String: String] = [:]
        if let glass { colors["oledSurface"] = glass }
        if let shade { colors["oledSurfaceShade"] = shade }
        let definition = ThemeDefinition(
            id: "test", name: "Test", baseAppearance: .dark, colors: colors
        )
        return alpha(of: CarbonTheme(definition: definition, resolvedBase: .carbon).oledSurfaceShade)
    }

    private func alpha(of color: Color) -> Double {
        Double(NSColor(color).usingColorSpace(.sRGB)?.alphaComponent ?? -1)
    }
}
#endif
