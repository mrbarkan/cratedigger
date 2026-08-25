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

    /// Both surfaces have to be represented, or the editor renders an empty
    /// section header.
    func testBothSurfacesHaveDials() {
        XCTAssertFalse(ThemeTokenCatalog.effectDials(on: .interface).isEmpty)
        XCTAssertFalse(ThemeTokenCatalog.effectDials(on: .display).isEmpty)
        XCTAssertEqual(
            ThemeTokenCatalog.effectDials(on: .interface).count
                + ThemeTokenCatalog.effectDials(on: .display).count,
            ThemeTokenCatalog.effectDials.count
        )
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
}
#endif
