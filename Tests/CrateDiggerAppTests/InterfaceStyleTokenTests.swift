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
