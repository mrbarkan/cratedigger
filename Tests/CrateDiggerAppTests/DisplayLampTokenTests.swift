#if canImport(XCTest)
import CrateDiggerCore
import SwiftUI
import XCTest
@testable import CrateDiggerApp

/// The per-screen display lamps (NOW, CNVRT, SCAN, SYNC, CD, DEV) and the
/// browser's row stripe. Both are tokens that are *unset* in everything that
/// ships, so the thing worth pinning is the fallback: an unnamed lamp has to
/// keep tracking the accent it always borrowed, or every existing theme
/// silently loses its annunciator colors.
final class DisplayLampTokenTests: XCTestCase {

    private func theme(colors: [String: String]) -> CarbonTheme {
        CarbonTheme(
            definition: ThemeDefinition(id: "t", name: "T", baseAppearance: .dark, colors: colors),
            resolvedBase: .carbon
        )
    }

    func testUnsetLampFollowsTheAccentItBorrows() {
        let retinted = theme(colors: ["cyan": "#123456", "sun": "#654321"])
        XCTAssertEqual(retinted.lampScan, retinted.cyan)
        XCTAssertEqual(retinted.lampNow, retinted.sun)
    }

    func testNamedLampOverridesTheAccent() {
        let pinned = theme(colors: ["lampScan": "#00FF00", "cyan": "#123456"])
        XCTAssertEqual(pinned.lampScan, Color(hexString: "#00FF00"))
        XCTAssertNotEqual(pinned.lampScan, pinned.cyan, "a pinned lamp must not follow the accent")
        // The other five stay attached to theirs.
        XCTAssertEqual(pinned.lampConvert, pinned.orange)
    }

    func testEveryLampIsReachableFromTheEditorCatalog() {
        let keys = Set(ThemeTokenCatalog.allColorTokens.map(\.key))
        for key in ["lampNow", "lampConvert", "lampScan", "lampSync", "lampCD", "lampDevices", "rowAlt"] {
            XCTAssertTrue(keys.contains(key), "\(key) has no swatch in the theme editor")
        }
    }

    /// SEARCH is the seventh screen. Every other accent already belongs to a
    /// lamp, so its unset colour is the teal glow.
    func testSearchLampFollowsTheTealGlowUntilPinned() {
        let retinted = theme(colors: ["cyanGlow": "#112233"])
        XCTAssertEqual(retinted.lampSearch, retinted.cyanGlow)

        let pinned = theme(colors: ["lampSearch": "#00FF00", "cyanGlow": "#112233"])
        XCTAssertEqual(pinned.lampSearch, Color(hexString: "#00FF00"))
        XCTAssertEqual(pinned.monochromeGlass.lampSearch, pinned.oledForeground)
    }

    /// STATS is the eighth screen. It is about what you have been playing, so
    /// its lamp is the NOW family one step brighter: `sunHi`.
    func testStatsLampFollowsSunHiUntilPinned() {
        let retinted = theme(colors: ["sunHi": "#332211"])
        XCTAssertEqual(retinted.lampStats, retinted.sunHi)

        let pinned = theme(colors: ["lampStats": "#00FF00", "sunHi": "#332211"])
        XCTAssertEqual(pinned.lampStats, Color(hexString: "#00FF00"))
        XCTAssertEqual(pinned.monochromeGlass.lampStats, pinned.oledForeground)
    }

    /// The LED behind the transport caps. Unset it has to keep tracking the
    /// accent trio exactly, or every theme that ships today changes colour.
    func testTransportLampFollowsTheAccentTrioUntilPinned() {
        let retinted = theme(colors: ["orange": "#FF0000", "orangeHi": "#FF8888", "orangeLo": "#880000"])
        XCTAssertEqual(retinted.transportLamp, retinted.orange)
        XCTAssertEqual(retinted.transportLampHi, retinted.orangeHi)
        XCTAssertEqual(retinted.transportLampLo, retinted.orangeLo)
    }

    /// Pinned, the cap is one hue at three depths: a real LED behind rubber is
    /// one colour, and the cap's opacity ramp is what makes the gradient.
    func testPinnedTransportLampIsOneHueAndLeavesTheAccentAlone() {
        let pinned = theme(colors: ["transportLamp": "#00FF00", "orange": "#FF0000"])
        XCTAssertEqual(pinned.transportLamp, Color(hexString: "#00FF00"))
        XCTAssertEqual(pinned.transportLampHi, pinned.transportLamp)
        XCTAssertEqual(pinned.transportLampLo, pinned.transportLamp)
        XCTAssertNotEqual(pinned.transportLamp, pinned.orange, "the accent must not follow the cap")
    }

    func testBothNewTokensAreReachableFromTheEditorCatalog() {
        let keys = Set(ThemeTokenCatalog.allColorTokens.map(\.key))
        XCTAssertTrue(keys.contains("lampSearch"), "lampSearch has no swatch in the theme editor")
        XCTAssertTrue(keys.contains("lampStats"), "lampStats has no swatch in the theme editor")
        XCTAssertTrue(keys.contains("transportLamp"), "transportLamp has no swatch in the theme editor")
        XCTAssertTrue(keys.contains("keyLamp"), "keyLamp has no swatch in the theme editor")
        XCTAssertTrue(keys.contains("meterHot"), "meterHot has no swatch in the theme editor")
    }

    /// The meters' loud end follows the accent pair until named, then is one
    /// hue for the body and the peak, and leaves the accent alone.
    func testMeterHighFollowsTheAccentPairUntilPinned() {
        let retinted = theme(colors: ["orange": "#000000", "orangeHi": "#222222"])
        XCTAssertEqual(retinted.meterHot, retinted.orange)
        XCTAssertEqual(retinted.meterHotHi, retinted.orangeHi)

        let pinned = theme(colors: ["meterHot": "#FF4000", "orange": "#000000"])
        XCTAssertEqual(pinned.meterHot, Color(hexString: "#FF4000"))
        XCTAssertEqual(pinned.meterHotHi, pinned.meterHot)
        XCTAssertEqual(pinned.orange, Color(hexString: "#000000"))
    }

    /// A theme with black keys still needs LEDs that light: the key lamps
    /// follow the accent until named, and once named leave the accent alone.
    func testKeyLampFollowsTheAccentUntilPinned() {
        let retinted = theme(colors: ["orange": "#000000"])
        XCTAssertEqual(retinted.keyLamp, retinted.orange)

        let pinned = theme(colors: ["keyLamp": "#00FF00", "orange": "#000000"])
        XCTAssertEqual(pinned.keyLamp, Color(hexString: "#00FF00"))
        XCTAssertEqual(pinned.orange, Color(hexString: "#000000"), "the keys stay black")
    }

    /// A single-phosphor screen draws everything in its own color — a lamp
    /// pinned to green has to collapse with the accents, not survive them.
    func testMonochromeGlassCollapsesPinnedLamps() {
        let pinned = theme(colors: ["lampScan": "#00FF00"])
        XCTAssertEqual(pinned.monochromeGlass.lampScan, pinned.oledForeground)
    }

    func testRowStripeIsTransparentUntilAThemeNamesIt() {
        XCTAssertEqual(CarbonTheme.carbon.rowAlt, .clear)
        XCTAssertEqual(CarbonTheme.linen.rowAlt, .clear)
        XCTAssertEqual(theme(colors: ["rowAlt": "#FFFFFF20"]).rowAlt, Color(hexString: "#FFFFFF20"))
    }

    /// Print on a key. Shares `ink2` with body copy until a theme separates
    /// them, which a dark list inside a light console has to: Llama '97's
    /// silver keys need near-black glyphs while its rows need green.
    func testKeyPrintFollowsSecondaryTextUntilPinned() {
        let retinted = theme(colors: ["ink2": "#00E000"])
        XCTAssertEqual(retinted.chassisInk, retinted.ink2)

        let pinned = theme(colors: ["chassisInk": "#1E2A1E", "ink2": "#00E000"])
        XCTAssertEqual(pinned.chassisInk, Color(hexString: "#1E2A1E"))
        XCTAssertEqual(pinned.ink2, Color(hexString: "#00E000"), "pinning the print must not move body copy")
        XCTAssertTrue(
            ThemeTokenCatalog.allColorTokens.contains { $0.key == "chassisInk" },
            "chassisInk has no swatch in the theme editor"
        )
    }

    /// The browser column headers. Section-label type drawn on the well rather
    /// than on the chassis, so a dark browser needs it separable from SOURCES
    /// and BROWSER — but unset it is `ink3` exactly, or every theme that ships
    /// today changes the moment the token exists.
    func testColumnHeaderInkFollowsSectionLabelsUntilPinned() {
        let retinted = theme(colors: ["ink3": "#445566"])
        XCTAssertEqual(retinted.columnHeaderInk, retinted.ink3)

        let pinned = theme(colors: ["columnHeaderInk": "#00FF00", "ink3": "#445566"])
        XCTAssertEqual(pinned.columnHeaderInk, Color(hexString: "#00FF00"))
        XCTAssertNotEqual(pinned.columnHeaderInk, pinned.ink3)
        XCTAssertEqual(pinned.ink3, Color(hexString: "#445566"), "pinning the header must not move the labels")
        XCTAssertTrue(
            ThemeTokenCatalog.allColorTokens.contains { $0.key == "columnHeaderInk" },
            "columnHeaderInk has no swatch in the theme editor"
        )
    }
}

/// The browser column's scroll trigger. "Go to Current Song" on an album that
/// is already selected changes no id, so the request has to differ by its tick
/// or `onChange` never fires and the button reads as dead.
final class ScrollRequestTests: XCTestCase {

    func testSameTargetAskedTwiceIsANewRequest() {
        let first = ScrollRequest(target: AnyHashable("album-1"), tick: 1)
        let again = ScrollRequest(target: AnyHashable("album-1"), tick: 2)
        XCTAssertNotEqual(first, again)
    }

    func testAnUnchangedRequestDoesNotRetrigger() {
        XCTAssertEqual(
            ScrollRequest(target: AnyHashable("album-1"), tick: 1),
            ScrollRequest(target: AnyHashable("album-1"), tick: 1)
        )
    }

    func testMovingTheSelectionIsANewRequest() {
        XCTAssertNotEqual(
            ScrollRequest(target: AnyHashable("album-1"), tick: 1),
            ScrollRequest(target: AnyHashable("album-2"), tick: 1)
        )
    }
}
#endif
