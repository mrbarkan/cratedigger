#if canImport(XCTest)
import CrateDiggerCore
import SwiftUI
import XCTest
@testable import CrateDiggerApp

/// The tokens the interface styles draw with, and how a theme's style reaches
/// the environment. Every one of them is unset or inert in the themes that ship
/// today, so what is pinned here is mostly the fallback: Real Hardware must see
/// exactly the colours and radii it always did.
final class InterfaceStyleTokenTests: XCTestCase {

    private func theme(colors: [String: String] = [:],
                       appearance: ThemeDefinition.BaseAppearance = .dark) -> CarbonTheme {
        CarbonTheme(
            definition: ThemeDefinition(id: "t", name: "T", baseAppearance: appearance, colors: colors),
            resolvedBase: appearance == .dark ? .carbon : .linen
        )
    }

    // MARK: Sticker ink

    /// Black at 0.92 all but vanishes on a dark case, so dark falls back to the
    /// light print; light keeps the theme's own ink.
    func testStickerInkFallsBackPerAppearance() {
        let dark = theme(colors: ["chassisInk": "#DDEEFF"], appearance: .dark)
        XCTAssertEqual(dark.stickerInk, dark.chassisInk.opacity(0.85))
        XCTAssertNil(dark.stickerInkOverride)

        let light = theme(colors: ["ink": "#112233"], appearance: .light)
        XCTAssertEqual(light.stickerInk, light.ink.opacity(0.9))
        XCTAssertNil(light.stickerInkOverride)

        XCTAssertEqual(CarbonTheme.carbon.stickerInk, CarbonTheme.carbon.chassisInk.opacity(0.85))
        XCTAssertEqual(CarbonTheme.linen.stickerInk, CarbonTheme.linen.ink.opacity(0.9))
    }

    func testNamedStickerInkWins() {
        for appearance in [ThemeDefinition.BaseAppearance.dark, .light] {
            let pinned = theme(colors: ["stickerInk": "#6E8EF5"], appearance: appearance)
            XCTAssertEqual(pinned.stickerInk, Color(hexString: "#6E8EF5"), "\(appearance)")
        }
    }

    func testStickerInkHasASwatch() {
        XCTAssertTrue(
            ThemeTokenCatalog.allColorTokens.contains { $0.key == "stickerInk" },
            "stickerInk has no swatch in the theme editor"
        )
    }

    // MARK: Key print

    /// Unset, the keys keep the ink each one prints in today, exactly; set, they
    /// all follow the theme's Key Print.
    func testKeyPrintFollowsChassisInkOnlyWhenSet() {
        let unset = theme(colors: ["ink2": "#00E000", "ink3": "#445566"])
        XCTAssertEqual(unset.keyPrint(unset.ink3), unset.ink3)
        XCTAssertEqual(unset.keyPrint(unset.ink2), unset.ink2)
        XCTAssertEqual(CarbonTheme.carbon.keyPrint(CarbonTheme.carbon.ink3), CarbonTheme.carbon.ink3)
        XCTAssertEqual(CarbonTheme.linen.keyPrint(CarbonTheme.linen.ink3), CarbonTheme.linen.ink3)

        let pinned = theme(colors: ["chassisInk": "#1E2A1E", "ink3": "#445566"])
        XCTAssertEqual(pinned.keyPrint(pinned.ink3), Color(hexString: "#1E2A1E"))
        XCTAssertEqual(pinned.keyPrint(pinned.ink2), pinned.chassisInk)
    }

    /// Key Print equal to the secondary ink is what the editor's seeding
    /// writes into every draft: it is no choice, so the keys keep their own
    /// ink. Only a Key Print that differs reaches them.
    func testKeyPrintEqualToInk2IsInert() {
        let seededPin = theme(colors: ["ink2": "#00E000", "ink3": "#445566", "chassisInk": "#00E000"])
        XCTAssertEqual(seededPin.keyPrint(seededPin.ink3), seededPin.ink3)
        XCTAssertEqual(seededPin.keyPrint(seededPin.ink2), seededPin.ink2)

        let real = theme(colors: ["ink2": "#00E000", "ink3": "#445566", "chassisInk": "#1E2A1E"])
        XCTAssertEqual(real.keyPrint(real.ink3), Color(hexString: "#1E2A1E"))
        XCTAssertEqual(real.keyPrint(real.ink2), Color(hexString: "#1E2A1E"))

        // The base's own ink2, unnamed by the theme, counts the same.
        let inheritedInk2 = theme(colors: ["chassisInk": CarbonTheme.carbon.ink2.themeHexString])
        XCTAssertEqual(inheritedInk2.keyPrint(inheritedInk2.ink3), inheritedInk2.ink3)
    }

    // MARK: Corner radii

    func testStyledRadiusStaysInBounds() {
        for style in InterfaceStyle.allCases {
            for r in stride(from: 0.0, through: 16.0, by: 1.0) {
                XCTAssertTrue(CarbonGeometry.Bounds.cornerRadius.contains(
                    CarbonGeometry.styledRadius(CGFloat(r), for: style)))
            }
            XCTAssertTrue(CarbonGeometry.Bounds.cornerRadius.contains(
                CarbonGeometry.styledRadius(40, for: style)), "\(style) at the ceiling")
        }
        XCTAssertEqual(CarbonGeometry.styledRadius(6, for: .hardware), 6)
    }

    func testStyledRadiusMultipliesByTheStylesScale() {
        XCTAssertEqual(CarbonGeometry.styledRadius(10, for: .softBlocks), 20)
        XCTAssertEqual(CarbonGeometry.styledRadius(10, for: .flatHardware), 14, accuracy: 0.0001)
        XCTAssertEqual(CarbonGeometry.styledRadius(30, for: .softBlocks), 40, "clamped to the ceiling")
    }

    // MARK: Delivery

    func testStyleComesFromTheDefinitionUnlessOverridden() {
        let sticker = ThemeDefinition(id: "s", name: "S", baseAppearance: .light, style: .sticker)
        XCTAssertEqual(InterfaceStyleDelivery.style(for: sticker, override: nil), .sticker)
        XCTAssertEqual(InterfaceStyleDelivery.style(for: nil, override: nil), .hardware)
        XCTAssertEqual(InterfaceStyleDelivery.style(for: sticker, override: .softBlocks), .softBlocks)
        XCTAssertEqual(InterfaceStyleDelivery.style(for: nil, override: .flatHardware), .flatHardware)
    }

    #if DEBUG
    func testDebugOverrideAcceptsOnlyTheFourRawValues() {
        for style in InterfaceStyle.allCases {
            XCTAssertEqual(InterfaceStyleDelivery.debugOverride(from: style.rawValue), style)
        }
        for bad in [nil, "", "soft", "toy", "real", "Sticker", " sticker", "hardware\n"] as [String?] {
            XCTAssertNil(InterfaceStyleDelivery.debugOverride(from: bad), "\(String(describing: bad))")
        }
    }
    #endif

    /// Only Soft Blocks pays for the separation maths; every other style gets nil.
    func testSoftSurfacesExistOnlyForSoftBlocks() {
        for style in InterfaceStyle.allCases where style != .softBlocks {
            XCTAssertNil(InterfaceStyleDelivery.softSurfaces(for: style, theme: .carbon), "\(style)")
        }
        XCTAssertNotNil(InterfaceStyleDelivery.softSurfaces(for: .softBlocks, theme: .carbon))
    }

    /// A key the colour of the case is moved apart from it; one that already
    /// stands apart is left as it is.
    func testSoftSurfacesSeparateAFillFromItsSurface() throws {
        let flush = theme(colors: ["chassis": "#808080", "metal": "#808080",
                                   "well": "#202020", "paper": "#C0C0C0"])
        let surfaces = try XCTUnwrap(InterfaceStyleDelivery.softSurfaces(for: .softBlocks, theme: flush))
        XCTAssertNotEqual(surfaces.metal.paletteColor, PaletteColor(hex: "#808080"))
        let chassis = try XCTUnwrap(PaletteColor(hex: "#808080"))
        XCTAssertGreaterThanOrEqual(PaletteColor.contrast(surfaces.metal.paletteColor, chassis),
                                    SoftSeparation.minimumContrast - 0.0001)
        assertSameColor(surfaces.well.paletteColor, try XCTUnwrap(PaletteColor(hex: "#202020")))
        assertSameColor(surfaces.paper.paletteColor, try XCTUnwrap(PaletteColor(hex: "#C0C0C0")))
    }

    /// Each fill is separated from what Soft Blocks actually draws under it: the
    /// paper from the *separated* well, not the theme's own. Carbon dark's case,
    /// well and paper sit within the minimum contrast of one another, so
    /// separating the paper from the original well nudged both lighter together
    /// and the lists vanished into their panel.
    func testSoftSurfacesSeparatePaperFromTheWellAsDrawn() throws {
        let carbon = CarbonTheme.carbon
        let surfaces = try XCTUnwrap(InterfaceStyleDelivery.softSurfaces(for: .softBlocks, theme: carbon))
        let chassis = carbon.chassis.paletteColor
        let floor = SoftSeparation.minimumContrast - 0.0001
        XCTAssertGreaterThanOrEqual(PaletteColor.contrast(surfaces.well.paletteColor, chassis), floor,
                                    "well against the case")
        XCTAssertGreaterThanOrEqual(PaletteColor.contrast(surfaces.paper.paletteColor, surfaces.well.paletteColor),
                                    floor, "lists against the well as drawn")
        XCTAssertGreaterThanOrEqual(PaletteColor.contrast(surfaces.metal.paletteColor, chassis), floor,
                                    "keys against the case")
    }

    /// Keys sit on the case, on a well (pane-header plates) and on paper (the
    /// inspector's tab row), so Soft Blocks' metal clears all three as drawn.
    /// Carbon's own colours, both layers (Carbon.cdtheme).
    func testSoftMetalClearsEverySurfaceAKeySitsOn() throws {
        let layers: [(ThemeDefinition.BaseAppearance, [String: String])] = [
            (.light, ["chassis": "#F5F8FA", "well": "#E9F1F4", "paper": "#FAFCFD", "metal": "#DDE8EC"]),
            (.dark, ["chassis": "#171C22", "well": "#121A22", "paper": "#111820", "metal": "#303A43"]),
        ]
        for (appearance, colors) in layers {
            let drawn = theme(colors: colors, appearance: appearance)
            let surfaces = try XCTUnwrap(InterfaceStyleDelivery.softSurfaces(for: .softBlocks, theme: drawn))
            let metal = surfaces.metal.paletteColor
            let floor = SoftSeparation.minimumContrast - 0.0001
            for (name, under) in [("chassis", drawn.chassis), ("well", surfaces.well), ("paper", surfaces.paper)] {
                XCTAssertGreaterThanOrEqual(PaletteColor.contrast(metal, under.paletteColor), floor,
                                            "\(appearance): keys against the \(name)")
            }
        }
    }

    private func assertSameColor(_ a: PaletteColor, _ b: PaletteColor,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.r, b.r, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(a.g, b.g, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(a.b, b.b, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(a.a, b.a, accuracy: 0.002, file: file, line: line)
    }

    // MARK: Motion

    func testSoftPressIsAQuickSpring() {
        XCTAssertEqual(CarbonMotion.softPress, .spring(response: 0.18, dampingFraction: 0.55))
    }
}
#endif
