import XCTest
@testable import CrateDiggerCore

final class InterfaceStyleRulesTests: XCTestCase {
    func testFlatSwitchOnlyReachesRealHardware() {
        XCTAssertFalse(InterfaceStyle.hardware.castsContentShadows(flatSwitchOn: true))
        XCTAssertTrue(InterfaceStyle.hardware.castsContentShadows(flatSwitchOn: false))
        XCTAssertTrue(InterfaceStyle.hardware.honoursFlatSwitch)
        for style in [InterfaceStyle.flatHardware, .softBlocks, .sticker] {
            XCTAssertTrue(style.castsContentShadows(flatSwitchOn: true), "\(style)")
            XCTAssertTrue(style.castsContentShadows(flatSwitchOn: false), "\(style)")
            XCTAssertFalse(style.honoursFlatSwitch, "\(style)")
        }
    }

    func testNearIdenticalPairIsPushedApartAwayFromTheSurface() {
        let key = PaletteColor(hex: "#C4C4C4")!, caseColor = PaletteColor(hex: "#C0C0C0")!
        let out = SoftSeparation.separated(key, on: caseColor)
        XCTAssertGreaterThanOrEqual(PaletteColor.contrast(out, caseColor), SoftSeparation.minimumContrast)
        XCTAssertGreaterThan(out.relativeLuminance, key.relativeLuminance)
    }

    func testDistinctPairIsUntouched() {
        let metal = PaletteColor(hex: "#33415A")!, chassis = PaletteColor(hex: "#18212F")!
        XCTAssertEqual(SoftSeparation.separated(metal, on: chassis), metal)
    }

    func testDarkerFillOnPaleSurfaceMovesDarker() {
        // #B8B5AD from the brief is already 1.15 against #C9C6BE and rightly untouched, so the
        // darker case uses a fill that is actually too close.
        XCTAssertEqual(SoftSeparation.separated(PaletteColor(hex: "#B8B5AD")!, on: PaletteColor(hex: "#C9C6BE")!).hex, "#B8B5AD")
        let surface = PaletteColor(hex: "#C9C6BE")!
        let lighter = SoftSeparation.separated(PaletteColor(hex: "#CFCBC4")!, on: surface)
        XCTAssertGreaterThan(lighter.relativeLuminance, PaletteColor(hex: "#CFCBC4")!.relativeLuminance)
        XCTAssertGreaterThanOrEqual(PaletteColor.contrast(lighter, surface), SoftSeparation.minimumContrast)
        let darker = SoftSeparation.separated(PaletteColor(hex: "#BFBCB4")!, on: surface)
        XCTAssertLessThan(darker.relativeLuminance, PaletteColor(hex: "#BFBCB4")!.relativeLuminance)
        XCTAssertGreaterThanOrEqual(PaletteColor.contrast(darker, surface), SoftSeparation.minimumContrast)
    }
}
