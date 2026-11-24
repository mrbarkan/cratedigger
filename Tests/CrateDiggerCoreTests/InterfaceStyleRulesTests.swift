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

    func testLighterFillWithNoRoomAboveGoesDarker() {
        let surface = PaletteColor(hex: "#F5F8FA")!
        let out = SoftSeparation.separated(PaletteColor(hex: "#FAFCFD")!, on: surface)
        XCTAssertGreaterThanOrEqual(PaletteColor.contrast(out, surface), SoftSeparation.minimumContrast)
        XCTAssertLessThan(out.relativeLuminance, surface.relativeLuminance)
    }

    func testIdenticalWhiteAndBlackAreSeparated() {
        for hex in ["#FFFFFF", "#000000"] {
            let c = PaletteColor(hex: hex)!
            let out = SoftSeparation.separated(c, on: c)
            XCTAssertGreaterThanOrEqual(PaletteColor.contrast(out, c), SoftSeparation.minimumContrast, hex)
        }
    }

    // MARK: separated(_:onAll:) — a key clears every surface it can sit on

    private func minContrast(_ fill: PaletteColor, _ surfaces: [PaletteColor]) -> Double {
        surfaces.map { PaletteColor.contrast(fill, $0) }.min() ?? .infinity
    }

    func testFillTooCloseToTwoOfThreeSurfacesClearsAllThree() {
        let fill = PaletteColor(hex: "#808080")!
        let surfaces = [PaletteColor(hex: "#808080")!, PaletteColor(hex: "#848484")!, PaletteColor(hex: "#202020")!]
        XCTAssertLessThan(minContrast(fill, surfaces), SoftSeparation.minimumContrast)
        let out = SoftSeparation.separated(fill, onAll: surfaces)
        XCTAssertGreaterThanOrEqual(minContrast(out, surfaces), SoftSeparation.minimumContrast)
    }

    func testFillThatAlreadyClearsEverySurfaceIsUntouched() {
        let fill = PaletteColor(hex: "#808080")!
        XCTAssertEqual(SoftSeparation.separated(fill, onAll: [PaletteColor(hex: "#000000")!,
                                                               PaletteColor(hex: "#FFFFFF")!]), fill)
    }

    func testNoSurfacesLeavesTheFill() {
        let fill = PaletteColor(hex: "#808080")!
        XCTAssertEqual(SoftSeparation.separated(fill, onAll: []), fill)
    }

    /// One surface just above and one just below: the fill has to travel past one
    /// of them, and still ends clear of both.
    func testFillSqueezedBetweenALighterAndADarkerSurfaceClearsBoth() {
        let fill = PaletteColor(hex: "#808080")!
        let surfaces = [PaletteColor(hex: "#888888")!, PaletteColor(hex: "#787878")!]
        let out = SoftSeparation.separated(fill, onAll: surfaces)
        XCTAssertNotEqual(out, fill)
        XCTAssertGreaterThanOrEqual(minContrast(out, surfaces), SoftSeparation.minimumContrast)
    }

    /// Greys every 12 levels across the whole reach of a 0.50 mix: no candidate clears
    /// them all, so the answer is the candidate whose worst contrast is the best.
    func testWhenNothingClearsEverySurfaceTheBestWorstCaseWins() {
        let fill = PaletteColor(hex: "#808080")!
        let surfaces = stride(from: 40, through: 220, by: 12).map {
            PaletteColor(r: Double($0) / 255, g: Double($0) / 255, b: Double($0) / 255)
        }
        var best = -Double.infinity
        for end in [0.0, 1.0] {
            for k in 1...25 {
                let t = Double(k) * 0.02
                let c = PaletteColor(r: fill.r + (end - fill.r) * t, g: fill.g + (end - fill.g) * t,
                                     b: fill.b + (end - fill.b) * t, a: fill.a)
                XCTAssertLessThan(minContrast(c, surfaces), SoftSeparation.minimumContrast, "the case must be impossible")
                best = max(best, minContrast(c, surfaces))
            }
        }
        let out = SoftSeparation.separated(fill, onAll: surfaces)
        XCTAssertEqual(minContrast(out, surfaces), best, accuracy: 1e-12)
    }
}
