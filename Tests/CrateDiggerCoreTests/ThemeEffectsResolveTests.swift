import XCTest
@testable import CrateDiggerCore

final class ThemeEffectsResolveTests: XCTestCase {
    func testShellMaterialPriority() {
        let all: [String: Double] = ["grain": 0.2, "shellPlastic": 0.08, "shellBrushed": 0.18,
                                     "shellBlasted": 0.58, "shellWeave": 0.12]
        XCTAssertEqual(ShellMaterial.resolve(effects: all)?.material, .plastic)
        var e = all; e["shellPlastic"] = 0
        XCTAssertEqual(ShellMaterial.resolve(effects: e)?.material, .brushed)
        e["shellBrushed"] = 0
        XCTAssertEqual(ShellMaterial.resolve(effects: e)?.material, .blasted)
        e["shellBlasted"] = 0
        XCTAssertEqual(ShellMaterial.resolve(effects: e)?.material, .weave)
        e["shellWeave"] = 0
        let last = ShellMaterial.resolve(effects: e)
        XCTAssertEqual(last?.material, .grain)
        XCTAssertEqual(last?.strength, 0.2)
    }

    func testShellMaterialInheritedGrainLosesToMaterial() {
        let r = ShellMaterial.resolve(effects: ["grain": 0.1, "shellBrushed": 0.18])
        XCTAssertEqual(r?.material, .brushed)
        XCTAssertEqual(r?.strength, 0.18)
    }

    func testShellMaterialOffWhenZeroNegativeOrMissing() {
        XCTAssertNil(ShellMaterial.resolve(effects: [:]))
        XCTAssertNil(ShellMaterial.resolve(effects: ["grain": 0, "shellWeave": -0.2]))
    }

    func testShellMaterialKeys() {
        XCTAssertEqual(ShellMaterial.allCases.map(\.effectKey),
                       ["grain", "shellPlastic", "shellBrushed", "shellBlasted", "shellWeave"])
    }

    func testCoverLookPriority() {
        let all: [String: Double] = ["coverGrid": 0.3, "coverPixel": 0.4, "coverHandheld": 0.5]
        XCTAssertEqual(CoverScreenLook.resolve(effects: all)?.look, .handheld)
        XCTAssertEqual(CoverScreenLook.resolve(effects: all)?.strength, 0.5)
        var e = all; e["coverHandheld"] = 0
        XCTAssertEqual(CoverScreenLook.resolve(effects: e)?.look, .pixel)
        e["coverPixel"] = 0
        XCTAssertEqual(CoverScreenLook.resolve(effects: e)?.look, .grid)
        e["coverGrid"] = -1
        XCTAssertNil(CoverScreenLook.resolve(effects: e))
        XCTAssertNil(CoverScreenLook.resolve(effects: [:]))
        // Pixel size alone never turns a look on.
        XCTAssertNil(CoverScreenLook.resolve(effects: ["coverPixelSize": 3]))
    }

    func testCoverLookKeys() {
        XCTAssertEqual(CoverScreenLook.allCases.map(\.effectKey), ["coverGrid", "coverPixel", "coverHandheld"])
    }

    func testPixelSizeSnap() {
        XCTAssertEqual(CoverScreenLook.pixelSize(from: nil), 1.5)
        XCTAssertEqual(CoverScreenLook.pixelSize(from: 0), 1.5)
        XCTAssertEqual(CoverScreenLook.pixelSize(from: -2), 1.5)
        XCTAssertEqual(CoverScreenLook.pixelSize(from: 1.5), 1.5)
        XCTAssertEqual(CoverScreenLook.pixelSize(from: 1.7), 1.5)
        XCTAssertEqual(CoverScreenLook.pixelSize(from: 1.8), 2)
        XCTAssertEqual(CoverScreenLook.pixelSize(from: 2.6), 3)
        XCTAssertEqual(CoverScreenLook.pixelSize(from: 3.4), 3)
        XCTAssertEqual(CoverScreenLook.pixelSize(from: 3.6), 4)
        XCTAssertEqual(CoverScreenLook.pixelSize(from: 9), 4)
        XCTAssertEqual(CoverScreenLook.pixelSize(from: 0.1), 1.5)
    }
}
