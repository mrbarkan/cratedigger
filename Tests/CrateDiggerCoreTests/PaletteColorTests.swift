import XCTest
@testable import CrateDiggerCore

final class PaletteColorTests: XCTestCase {
    func testHexRoundTrip() {
        for hex in ["#1B1D22", "#FF6A13", "#FFFFFF80"] {
            XCTAssertEqual(PaletteColor(hex: hex)?.hex, hex)
        }
        XCTAssertEqual(PaletteColor(hex: "1b1d22")?.hex, "#1B1D22")
    }

    func testInvalidHexIsNil() {
        XCTAssertNil(PaletteColor(hex: "#12"))
        XCTAssertNil(PaletteColor(hex: "zz0000"))
        XCTAssertNil(PaletteColor(hex: ""))
    }

    func testOKLCHRoundTripWithin1e3() {
        var rng = SplitMix64(seed: 42)
        for _ in 0..<200 {
            let c = PaletteColor(r: rng.unit(), g: rng.unit(), b: rng.unit(), a: 1)
            let back = PaletteColor(oklch: c.oklch)
            XCTAssertEqual(c.r, back.r, accuracy: 1e-3)
            XCTAssertEqual(c.g, back.g, accuracy: 1e-3)
            XCTAssertEqual(c.b, back.b, accuracy: 1e-3)
        }
    }

    func testContrastBlackWhiteIs21() {
        let black = PaletteColor(hex: "#000000")!, white = PaletteColor(hex: "#FFFFFF")!
        XCTAssertEqual(PaletteColor.contrast(black, white), 21, accuracy: 1e-6)
        XCTAssertEqual(PaletteColor.contrast(white, black), 21, accuracy: 1e-6)
    }

    func testContrastSameIs1() {
        let c = PaletteColor(hex: "#336699")!
        XCTAssertEqual(PaletteColor.contrast(c, c), 1, accuracy: 1e-9)
    }

    func testContrastCompositesAlphaOverBackground() {
        let clear = PaletteColor(hex: "#00000000")!
        let white = PaletteColor(hex: "#FFFFFF")!
        XCTAssertEqual(PaletteColor.contrast(clear, white), 1, accuracy: 1e-9)
    }

    func testOutOfGamutClipsChromaKeepsHue() {
        let c = PaletteColor(oklch: OKLCH(l: 0.7, c: 0.4, h: 145))
        XCTAssertTrue((0...1).contains(c.r) && (0...1).contains(c.g) && (0...1).contains(c.b))
        var dh = abs(c.oklch.h - 145)
        if dh > 180 { dh = 360 - dh }
        XCTAssertLessThan(dh, 1)
        XCTAssertLessThan(c.oklch.c, 0.4)
    }

    func testNearlyOpaqueAlphaWritesSixDigits() {
        // 0.999 rounds to the byte 255, which is opaque: no `FF` suffix.
        XCTAssertEqual(PaletteColor(r: 1, g: 0, b: 0, a: 0.999).hex, "#FF0000")
        XCTAssertEqual(PaletteColor(r: 1, g: 0, b: 0, a: 0.99).hex, "#FF0000FC")
    }

    func testNonFiniteComponentDoesNotTrap() {
        // NaN has no order, so it reads as 0; an infinity still clamps.
        XCTAssertEqual(PaletteColor(r: .nan, g: 0.5, b: .infinity, a: 1).hex, "#0080FF")
        XCTAssertEqual(PaletteColor(r: 0, g: 0, b: 0, a: .nan).hex, "#00000000")
    }

    func testHueIsWrappedBelow360() {
        XCTAssertEqual(PaletteColor.normalizedHue(-1e-15), 0)
        XCTAssertEqual(PaletteColor.normalizedHue(360), 0)
        XCTAssertEqual(PaletteColor.normalizedHue(-90), 270, accuracy: 1e-9)
        XCTAssertEqual(PaletteColor.normalizedHue(725), 5, accuracy: 1e-9)
    }

    func testHexTrimsNewlines() {
        XCTAssertEqual(PaletteColor(hex: "  #336699\n")?.hex, "#336699")
        XCTAssertEqual(PaletteColor(hex: "\t336699\r\n")?.hex, "#336699")
    }

    func testDistance() {
        let a = PaletteColor(hex: "#336699")!
        XCTAssertEqual(a.distance(to: a), 0, accuracy: 1e-12)
        XCTAssertGreaterThan(a.distance(to: PaletteColor(hex: "#FFFFFF")!), 0.2)
    }
}

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
