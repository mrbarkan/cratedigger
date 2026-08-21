#if canImport(XCTest)
import CrateDiggerCore
import SwiftUI
import XCTest
@testable import CrateDiggerApp

/// A preset writes tokens by string key and a scanline by number, and both fail
/// *silently* when they're wrong — a mistyped key paints nothing, an
/// out-of-range scanline is clamped away. So they're pinned here rather than
/// found by clicking six buttons and squinting at the header.
final class ScreenPresetTests: XCTestCase {

    private var screenKeys: Set<String> {
        Set(ThemeTokenCatalog.colorGroups
            .first { $0.name == ThemeTokenCatalog.screenGroupName }?
            .tokens.map(\.key) ?? [])
    }

    func testEveryPresetPaintsTheWholeScreenGroup() {
        let keys = screenKeys
        XCTAssertFalse(keys.isEmpty, "the screen group must exist for presets to write into")

        for preset in ThemeTokenCatalog.screenPresets {
            // Both appearances, since a half-filled light set would leave that
            // layer showing whatever the last preset put there.
            for appearance in [ThemeDefinition.BaseAppearance.light, .dark] {
                let colors = preset.colors(for: appearance)
                XCTAssertEqual(Set(colors.keys), keys,
                               "\(preset.name) (\(appearance)) must set every screen token and no others")
                for (key, hex) in colors {
                    XCTAssertNotNil(Color(hexString: hex), "\(preset.name).\(key) is not a parseable hex")
                }
            }
        }
    }

    /// The iPod is the reason `lightColors` exists — its panel is a different
    /// device with the backlight off, not the same one re-tinted.
    func testTheBacklitPresetIsTheOnlyAppearanceAwareOne() throws {
        let aware = ThemeTokenCatalog.screenPresets.filter(\.isAppearanceAware)
        XCTAssertEqual(aware.map(\.name), ["IPOD"])

        let ipod = try XCTUnwrap(aware.first)
        let lit = try XCTUnwrap(Color(hexString: ipod.colors(for: .dark)["oledSurface"] ?? ""))
        let unlit = try XCTUnwrap(Color(hexString: ipod.colors(for: .light)["oledSurface"] ?? ""))
        XCTAssertGreaterThan(lit.themeLuminance, 0.4, "backlight on should be the brighter glass")
        XCTAssertNotEqual(lit.themeHexString, unlit.themeHexString)
    }

    /// `CarbonTheme` clamps this to 0…0.15; a preset asking for more would be
    /// quietly trimmed, so it just isn't allowed to ask.
    func testScanlineStaysInsideTheClamp() {
        for preset in ThemeTokenCatalog.screenPresets {
            XCTAssertTrue((0...0.15).contains(preset.scanline),
                          "\(preset.name) scanline \(preset.scanline) would be clamped")
        }
    }

    /// Every preset models real single-emitter hardware, so every one turns the
    /// monochrome panel on — and the effect it writes has to be the value
    /// `CarbonTheme` reads back, or the switch in the editor would sit at OFF
    /// right after a preset was clicked.
    func testEveryPresetTurnsTheGlassMonochrome() {
        XCTAssertTrue(ThemeTokenCatalog.screenPresets.allSatisfy(\.monochrome))

        let definition = ThemeDefinition(
            id: "t", name: "T", baseAppearance: .dark,
            effects: ["oledMonochrome": 1]
        )
        XCTAssertTrue(CarbonTheme(definition: definition, resolvedBase: .carbon).oledMonochrome)
    }

    /// The point of the switch: nothing coloured survives on the glass.
    func testMonochromeGlassCollapsesEveryAccentOntoThePhosphor() {
        let definition = ThemeDefinition(
            id: "t", name: "T", baseAppearance: .dark,
            colors: ["oledForeground": "#00FF00"]
        )
        let glass = CarbonTheme(definition: definition, resolvedBase: .carbon).monochromeGlass
        let phosphor = glass.oledForeground.themeHexString

        for accent in [glass.orange, glass.sun, glass.cyan, glass.red, glass.indigo,
                       glass.onAir, glass.selectionLedCore] {
            XCTAssertEqual(accent.themeHexString, phosphor)
        }
        // The chassis is not the glass — its accents are none of this modifier's
        // business, and a theme that lost them would go grey everywhere.
        XCTAssertNotEqual(glass.chassis.themeHexString, phosphor)
        XCTAssertEqual(glass.ink.themeHexString, CarbonTheme.carbon.ink.themeHexString)
    }

    /// FLAT is a theme effect, not a view flag: `depthShadow` reads it off the
    /// environment theme, so if this mapping breaks every shadow in the app
    /// silently stops obeying the switch.
    func testFlatEffectTurnsOffCastShadows() {
        func theme(_ effects: [String: Double]) -> CarbonTheme {
            CarbonTheme(
                definition: ThemeDefinition(id: "t", name: "T", baseAppearance: .dark, effects: effects),
                resolvedBase: .carbon
            )
        }
        XCTAssertTrue(theme([:]).castsShadows, "a theme that says nothing keeps its depth")
        XCTAssertFalse(theme(["flat": 1]).castsShadows)
        XCTAssertTrue(theme(["flat": 0]).castsShadows)
    }

    func testPresetsHaveDistinctNames() {
        let names = ThemeTokenCatalog.screenPresets.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }
}
#endif
