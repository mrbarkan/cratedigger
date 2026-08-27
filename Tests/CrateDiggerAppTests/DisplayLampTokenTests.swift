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
