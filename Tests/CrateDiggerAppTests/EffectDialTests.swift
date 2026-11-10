#if canImport(XCTest)
import CrateDiggerCore
import SwiftUI
import XCTest
@testable import CrateDiggerApp

/// An effect is a number in a dictionary that some overlay may or may not read.
/// Every way that silently does nothing — a key nothing looks at, a ceiling the
/// theme clamps away, a switch that lights to 0 — looks identical from the
/// outside: the slider moves and the screen doesn't change. So the wiring is
/// pinned here instead of being found by dragging.
final class EffectDialTests: XCTestCase {

    func testDialsAreDistinctAndUsable() {
        let keys = ThemeTokenCatalog.effectDials.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "two dials writing one key would fight")

        for dial in ThemeTokenCatalog.effectDials {
            XCTAssertGreaterThan(dial.max, 0, "\(dial.key) can never be turned up")
            XCTAssertGreaterThan(dial.on, 0, "\(dial.key)'s switch would light to nothing")
            XCTAssertLessThanOrEqual(dial.on, dial.max, "\(dial.key)'s switch overshoots its own ceiling")
            XCTAssertFalse(dial.label.isEmpty)
            XCTAssertFalse(dial.note.isEmpty)
        }
    }

    /// Every surface has to be represented, or the editor renders an empty
    /// section header; and every dial is on one of them, or it never shows.
    func testBothSurfacesHaveDials() {
        XCTAssertFalse(ThemeTokenCatalog.effectDials(on: .interface).isEmpty)
        XCTAssertFalse(ThemeTokenCatalog.effectDials(on: .display).isEmpty)
        XCTAssertFalse(ThemeTokenCatalog.effectDials(on: .cover).isEmpty)
        XCTAssertEqual(
            ThemeTokenCatalog.effectDials(on: .interface).count
                + ThemeTokenCatalog.effectDials(on: .display).count
                + ThemeTokenCatalog.effectDials(on: .cover).count,
            ThemeTokenCatalog.effectDials.count
        )
    }

    /// The two exclusive groups are read off the Core resolvers' own enums,
    /// so a material or look added there without a dial (or a dial whose key
    /// is misspelt) shows up here as a group shorter than its enum.
    func testExclusiveGroupsAreExactlyTheCoreEnums() {
        XCTAssertEqual(ThemeTokenCatalog.shellMaterialDials.map(\.key),
                       ShellMaterial.allCases.map(\.effectKey))
        XCTAssertEqual(ThemeTokenCatalog.coverLookDials.map(\.key),
                       CoverScreenLook.allCases.map(\.effectKey))
        XCTAssertTrue(ThemeTokenCatalog.shellMaterialDials.contains { $0.key == "grain" },
                      "grain is a material: switching another on has to switch grain off")
        XCTAssertTrue(ThemeTokenCatalog.shellMaterialDials.allSatisfy { $0.surface == .interface })
        XCTAssertTrue(ThemeTokenCatalog.coverLookDials.allSatisfy { $0.surface == .cover })
    }

    /// The ranges the owner picked: `on` is the midpoint of each, and the
    /// ceiling leaves room above it.
    func testMaterialAndLookStrengths() {
        let dials = Dictionary(uniqueKeysWithValues: ThemeTokenCatalog.effectDials.map { ($0.key, $0) })
        let expected: [String: (max: Double, on: Double)] = [
            "grain": (0.6, 0.2),
            "shellPlastic": (0.30, 0.08),
            "shellBrushed": (0.50, 0.18),
            "shellBlasted": (1.00, 0.58),
            "shellWeave": (0.40, 0.12),
            "coverGrid": (1.0, 0.55),
            "coverPixel": (1.0, 0.55),
            "coverHandheld": (1.0, 0.55),
        ]
        for (key, values) in expected {
            guard let dial = dials[key] else {
                XCTFail("no dial for \(key)")
                continue
            }
            XCTAssertEqual(dial.max, values.max, "\(key) max")
            XCTAssertEqual(dial.on, values.on, "\(key) on")
        }
    }

    /// A theme that inherits Carbon's grain and sets a material draws the
    /// material alone: grain is last in the priority, and the chassis asks
    /// for the winner rather than for `grainAmount`.
    func testGrainAndAMaterialResolveToTheMaterialOnly() {
        let theme = CarbonTheme(
            definition: ThemeDefinition(id: "t", name: "T", baseAppearance: .dark,
                                        effects: ["grain": 0.1, "shellBrushed": 0.18]),
            resolvedBase: .carbon
        )
        XCTAssertEqual(theme.shellMaterial, .brushed)
        XCTAssertEqual(theme.shellMaterialStrength, 0.18, accuracy: 0.0001)
        XCTAssertEqual(theme.grainAmount, 0.1, accuracy: 0.0001, "the grain dial still reads its own value")
    }

    /// The resolved strength is the clamped one: a theme asking for more than
    /// the dial allows gets the ceiling, not the raw number.
    func testResolvedMaterialAndLookAreClamped() {
        let theme = CarbonTheme(
            definition: ThemeDefinition(id: "t", name: "T", baseAppearance: .dark,
                                        effects: ["shellPlastic": 5, "coverGrid": 5]),
            resolvedBase: .carbon
        )
        XCTAssertEqual(theme.shellMaterial, .plastic)
        XCTAssertEqual(theme.shellMaterialStrength, 0.30, accuracy: 0.0001)
        XCTAssertEqual(theme.coverScreenLook, .grid)
        XCTAssertEqual(theme.coverScreenStrength, 1.0, accuracy: 0.0001)
    }

    func testCoverLookResolvesWithItsStrength() {
        let theme = CarbonTheme(
            definition: ThemeDefinition(id: "t", name: "T", baseAppearance: .dark,
                                        effects: ["coverGrid": 0.3, "coverHandheld": 0.55]),
            resolvedBase: .carbon
        )
        XCTAssertEqual(theme.coverScreenLook, .handheld)
        XCTAssertEqual(theme.coverScreenStrength, 0.55, accuracy: 0.0001)
    }

    /// `coverPixelSize` has no dial, so it must not go through the dial clamp,
    /// which would pass it 0...1 and turn every size into 1 pt.
    func testCoverPixelSizeIsReadRawAndSnapped() {
        func size(_ effects: [String: Double]) -> Double {
            CarbonTheme(
                definition: ThemeDefinition(id: "t", name: "T", baseAppearance: .dark, effects: effects),
                resolvedBase: .carbon
            ).coverPixelSize
        }
        XCTAssertEqual(size(["coverPixel": 0.55, "coverPixelSize": 4]), 4)
        XCTAssertEqual(size(["coverPixel": 0.55, "coverPixelSize": 2.9]), 3)
        XCTAssertEqual(size(["coverPixel": 0.55]), 1.5, "absent is the default")
        XCTAssertEqual(size(["coverPixel": 0.55, "coverPixelSize": 0]), 1.5, "0 is the default")
        XCTAssertEqual(CarbonTheme.carbon.coverPixelSize, 1.5)
        XCTAssertEqual(CarbonTheme.linen.coverPixelSize, 1.5)
    }

    /// The built-ins resolve to exactly what they drew before: no material,
    /// no look. (Carbon's grain lives in its bundled file, not here.)
    func testBuiltInsResolveToNothing() {
        for theme in [CarbonTheme.carbon, .linen] {
            XCTAssertNil(theme.shellMaterial)
            XCTAssertEqual(theme.shellMaterialStrength, 0)
            XCTAssertNil(theme.coverScreenLook)
            XCTAssertEqual(theme.coverScreenStrength, 0)
        }
    }

    /// The dial's key must be the key `CarbonTheme` reads, and its `read` path
    /// must be where that value lands — the two ends of the only wire there is.
    func testEveryDialRoundTripsThroughTheTheme() {
        for dial in ThemeTokenCatalog.effectDials {
            let asked = dial.max / 2
            let theme = CarbonTheme(
                definition: ThemeDefinition(id: "t", name: "T", baseAppearance: .dark,
                                            effects: [dial.key: asked]),
                resolvedBase: .carbon
            )
            XCTAssertEqual(theme[keyPath: dial.read], asked, accuracy: 0.0001,
                           "effects.\(dial.key) doesn't reach \(dial.label)")
        }
    }

    func testEveryDialClampsToItsCeiling() {
        for dial in ThemeTokenCatalog.effectDials {
            let theme = CarbonTheme(
                definition: ThemeDefinition(id: "t", name: "T", baseAppearance: .dark,
                                            effects: [dial.key: dial.max * 10]),
                resolvedBase: .carbon
            )
            XCTAssertEqual(theme[keyPath: dial.read], dial.max, accuracy: 0.0001,
                           "\(dial.key) above its ceiling should clamp, not pass through")

            let negative = CarbonTheme(
                definition: ThemeDefinition(id: "t", name: "T", baseAppearance: .dark,
                                            effects: [dial.key: -1]),
                resolvedBase: .carbon
            )
            XCTAssertEqual(negative[keyPath: dial.read], 0, accuracy: 0.0001)
        }
    }

    /// Nothing is drawn unless a theme asks for it: the console ships as the
    /// hardware, not as a photograph of it.
    func testTheShippedThemesRunEveryEffectOff() {
        for theme in [CarbonTheme.carbon, .linen] {
            for dial in ThemeTokenCatalog.effectDials {
                XCTAssertEqual(theme[keyPath: dial.read], 0, "\(dial.key) ships on")
            }
        }
    }

    // MARK: - Exclusive groups

    func testSwitchingOneMaterialOnZeroesTheRestAndLeavesOtherKeysAlone() {
        let group = ShellMaterial.allCases.map(\.effectKey)
        let before: [String: Double] = ["grain": 0.2, "flat": 1, "oledGlare": 0.16, "coverPixel": 0.55, "coverPixelSize": 2]
        let after = ThemeTokenCatalog.settingExclusive("shellBrushed", to: 0.18, among: group, in: before)
        XCTAssertEqual(after["shellBrushed"], 0.18)
        for key in group where key != "shellBrushed" { XCTAssertEqual(after[key] ?? 0, 0, key) }
        XCTAssertEqual(after["flat"], 1)
        XCTAssertEqual(after["oledGlare"], 0.16)
        XCTAssertEqual(after["coverPixel"], 0.55)
        XCTAssertEqual(after["coverPixelSize"], 2)
        XCTAssertEqual(ShellMaterial.resolve(effects: after)?.material, .brushed)
    }

    func testSwitchingTheWinnerOffLeavesTheGroupAllZero() {
        let group = ShellMaterial.allCases.map(\.effectKey)
        let on = ThemeTokenCatalog.settingExclusive("shellWeave", to: 0.12, among: group, in: ["grain": 0.1])
        let off = ThemeTokenCatalog.settingExclusive("shellWeave", to: 0, among: group, in: on)
        for key in group { XCTAssertEqual(off[key] ?? 0, 0, key) }
        XCTAssertNil(ShellMaterial.resolve(effects: off))
    }

    func testADraftWithTwoNonZeroKeysEndsWithOne() {
        let group = CoverScreenLook.allCases.map(\.effectKey)
        let dirty: [String: Double] = ["coverGrid": 0.4, "coverHandheld": 0.3]
        let after = ThemeTokenCatalog.settingExclusive("coverPixel", to: 0.55, among: group, in: dirty)
        XCTAssertEqual(group.filter { (after[$0] ?? 0) > 0 }, ["coverPixel"])
        XCTAssertEqual(CoverScreenLook.resolve(effects: after)?.look, .pixel)
    }
}
#endif
