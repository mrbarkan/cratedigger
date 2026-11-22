import XCTest
@testable import CrateDiggerCore

final class CoverScreenRendererTests: XCTestCase {
    private func solid(_ n: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] {
        var a = [UInt8](); a.reserveCapacity(n * n * 4)
        for _ in 0..<(n * n) { a += [r, g, b, 255] }
        return a
    }
    private func px(_ img: [UInt8], side: Int, _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * side + x) * 4
        return Array(img[i..<i + 4])
    }
    private let layout = CoverScreenLayout.plan(side: 80, scale: 2, pixelSize: 1.5) // 160px, cell 3

    func testOutputSizeAllLooks() {
        let l = layout
        XCTAssertGreaterThan(l.count, 0)
        for look in CoverScreenLook.allCases {
            let n = look == .grid ? l.lcdSide : l.count
            let out = CoverScreenRenderer.render(source: solid(n, 10, 20, 30), look: look, layout: l, gridStrength: 0.5)
            XCTAssertEqual(out.count, l.lcdSide * l.lcdSide * 4)
            XCTAssertTrue(stride(from: 3, to: out.count, by: 4).allSatisfy { out[$0] == 255 })
        }
    }

    func testEmptyLayoutGivesEmptyOutput() {
        let l = CoverScreenLayout.plan(side: 10, scale: 1, pixelSize: 1.5)
        XCTAssertEqual(CoverScreenRenderer.render(source: [], look: .pixel, layout: l, gridStrength: 1), [])
    }

    func testGapPixelsOfWhiteAreGapColour() {
        let l = layout
        for (look, gap) in [(CoverScreenLook.pixel, [UInt8(0), 0, 0, 255]), (.grid, [0, 0, 0, 255]),
                            (.handheld, [26, 25, 21, 255])] {
            let n = look == .grid ? l.lcdSide : l.count
            let out = CoverScreenRenderer.render(source: solid(n, 255, 255, 255), look: look, layout: l, gridStrength: 1)
            // Last column and last row of the first cell, and of the second.
            XCTAssertEqual(px(out, side: l.lcdSide, 2, 0), gap, "\(look)")
            XCTAssertEqual(px(out, side: l.lcdSide, 0, 2), gap)
            XCTAssertEqual(px(out, side: l.lcdSide, 5, 4), gap)
            XCTAssertEqual(px(out, side: l.lcdSide, 2, 2), gap)
        }
    }

    func testLargeCellGapAndShoulder() {
        let l = CoverScreenLayout.plan(side: 200, scale: 2, pixelSize: 4) // cell 8, gap round(8/6)=1
        XCTAssertEqual(l.cell, 8)
        let out = CoverScreenRenderer.render(source: solid(l.count, 255, 255, 255), look: .pixel, layout: l, gridStrength: 1)
        XCTAssertEqual(px(out, side: l.lcdSide, 7, 3), [0, 0, 0, 255])        // gap
        XCTAssertGreaterThan(px(out, side: l.lcdSide, 6, 3)[0], 0)            // shoulder: partly dark,
        XCTAssertLessThan(px(out, side: l.lcdSide, 6, 3)[0], px(out, side: l.lcdSide, 3, 3)[0]) // darker than the middle
    }

    /// Cell 12 is the first size with a two-pixel gap (round(12/6) = 2):
    /// columns and rows 10 and 11 are gap, 9 and 0 are shoulders.
    func testTwoPixelGapAtCellTwelve() {
        let l = CoverScreenLayout.plan(side: 100, scale: 2, pixelSize: 6)
        XCTAssertEqual(l.cell, 12)
        XCTAssertGreaterThanOrEqual(l.count, 2)
        let out = CoverScreenRenderer.render(source: solid(l.count, 255, 255, 255), look: .pixel, layout: l, gridStrength: 1)
        let side = l.lcdSide
        let black: [UInt8] = [0, 0, 0, 255]
        for gap in [10, 11, 22, 23] {
            XCTAssertEqual(px(out, side: side, gap, 4), black, "column \(gap)")
            XCTAssertEqual(px(out, side: side, 4, gap), black, "row \(gap)")
        }
        let middle = px(out, side: side, 4, 4)[0]
        XCTAssertEqual(middle, 255)
        for shoulder in [9, 0, 12, 21] {
            let value = px(out, side: side, shoulder, 4)[0]
            XCTAssertGreaterThan(value, 0, "column \(shoulder) is a shoulder, not gap")
            XCTAssertLessThan(value, middle, "column \(shoulder) is darker than the middle")
        }
        // Only two columns of gap: the one before them is lit.
        XCTAssertNotEqual(px(out, side: side, 9, 4), black)
    }

    /// A source of the wrong size for its look renders opaque black at the
    /// layout's size, for every look, rather than reading out of bounds.
    func testWrongSizeSourceGivesOpaqueBlack() {
        let l = layout
        for look in CoverScreenLook.allCases {
            let right = look == .grid ? l.lcdSide : l.count
            for source in [solid(right - 1, 200, 200, 200), solid(right + 1, 200, 200, 200), []] {
                let out = CoverScreenRenderer.render(source: source, look: look, layout: l, gridStrength: 0.5)
                XCTAssertEqual(out.count, l.lcdSide * l.lcdSide * 4, "\(look)")
                for i in stride(from: 0, to: out.count, by: 4) where out[i] != 0 || out[i + 1] != 0
                    || out[i + 2] != 0 || out[i + 3] != 255 {
                    XCTFail("\(look): pixel \(i / 4) is \(out[i..<i + 4]), not opaque black")
                    break
                }
            }
        }
        // The pixel looks' source handed to the grid look is the wrong size too.
        let mixed = CoverScreenRenderer.render(source: solid(l.count, 200, 200, 200), look: .grid, layout: l, gridStrength: 0.5)
        XCTAssertEqual(px(mixed, side: l.lcdSide, l.lcdSide / 2, l.lcdSide / 2), [0, 0, 0, 255])
    }

    /// A cancelled render stops and returns nothing, never a partial picture.
    func testCancelledRenderReturnsEmpty() {
        let l = layout
        let src = solid(l.count, 120, 80, 200)
        XCTAssertEqual(CoverScreenRenderer.render(source: src, look: .pixel, layout: l, gridStrength: 0.5,
                                                  isCancelled: { true }), [])
        var asked = 0
        let midway = CoverScreenRenderer.render(source: src, look: .pixel, layout: l, gridStrength: 0.5,
                                                isCancelled: { asked += 1; return asked > 10 })
        XCTAssertEqual(midway, [], "cancelled after ten rows")
        XCTAssertEqual(asked, 11, "asked once per row, and stopped at the first yes")
        let whole = CoverScreenRenderer.render(source: src, look: .pixel, layout: l, gridStrength: 0.5,
                                               isCancelled: { false })
        XCTAssertEqual(whole.count, l.lcdSide * l.lcdSide * 4)
    }

    func testZeroStrengthPixelReproducesSource() {
        let l = layout
        var src = [UInt8]()
        for i in 0..<(l.count * l.count) { src += [UInt8(i % 251), UInt8((i * 7) % 253), UInt8((i * 13) % 255), 255] }
        let out = CoverScreenRenderer.render(source: src, look: .pixel, layout: l, gridStrength: 0)
        for y in 0..<l.lcdSide where y % 5 == 0 {
            for x in 0..<l.lcdSide {
                let s = (y / l.cell * l.count + x / l.cell) * 4
                XCTAssertEqual(px(out, side: l.lcdSide, x, y), Array(src[s..<s + 4]))
            }
        }
    }

    func testGainKeepsMeanBrightness() {
        let l = layout
        let out = CoverScreenRenderer.render(source: solid(l.count, 100, 100, 100), look: .pixel, layout: l, gridStrength: 0.55)
        var sum = 0
        for i in stride(from: 0, to: out.count, by: 4) { sum += Int(out[i]) }
        let mean = Double(sum) / Double(l.lcdSide * l.lcdSide)
        // Cell 3 is 5/9 gap, so at 0.55 the mean lit share is 0.694 and the gain
        // hits its 1.35 cap: 100 * 1.35 * 0.694 = 93.75, not the full 100.
        XCTAssertEqual(mean, 93.75, accuracy: 1)
        // A strength light enough to stay under the cap is fully compensated.
        let soft = CoverScreenRenderer.render(source: solid(l.count, 100, 100, 100), look: .pixel, layout: l, gridStrength: 0.2)
        var softSum = 0
        for i in stride(from: 0, to: soft.count, by: 4) { softSum += Int(soft[i]) }
        XCTAssertEqual(Double(softSum) / Double(l.lcdSide * l.lcdSide), 100, accuracy: 1.5)
    }

    func testHandheldToneBlackLiftedAndBounded() {
        let black = CoverScreenRenderer.handheldTone(r: 0, g: 0, b: 0)
        XCTAssertGreaterThan(black.0, 0); XCTAssertGreaterThan(black.1, 0); XCTAssertGreaterThan(black.2, 0)
        XCTAssertLessThan(black.0, 60)
        let white = CoverScreenRenderer.handheldTone(r: 255, g: 255, b: 255)
        XCTAssertLessThanOrEqual(white.0, 255)
        XCTAssertLessThan(white.0, 250) // washed: never full white
        for v in stride(from: 0, through: 255, by: 15) {
            let t = CoverScreenRenderer.handheldTone(r: UInt8(v), g: UInt8(255 - v), b: UInt8(v))
            XCTAssertTrue(t.0 <= 255 && t.1 <= 255 && t.2 <= 255)
        }
    }

    func testDeterministic() {
        let l = layout
        var src = [UInt8]()
        for i in 0..<(l.count * l.count) { src += [UInt8(i % 256), UInt8((i * 3) % 256), UInt8((i * 5) % 256), 255] }
        let a = CoverScreenRenderer.render(source: src, look: .handheld, layout: l, gridStrength: 0.55)
        let b = CoverScreenRenderer.render(source: src, look: .handheld, layout: l, gridStrength: 0.55)
        XCTAssertEqual(a, b)
    }

    // MARK: - The unlit panel

    func testUnlitColourKeepsAPaleGlass() {
        // Pocket light's oledSurface, #B7BBB0: an unlit reflective LCD is the
        // colour of its glass.
        let c = CoverScreenRenderer.unlitColor(r: 0xB7, g: 0xBB, b: 0xB0)
        XCTAssertEqual([c.0, c.1, c.2], [0xB7, 0xBB, 0xB0])
    }

    func testUnlitColourTakesADarkGlassFortyPercentTowardBlack() {
        let c = CoverScreenRenderer.unlitColor(r: 100, g: 50, b: 20)
        XCTAssertEqual([c.0, c.1, c.2], [60, 30, 12])
        let black = CoverScreenRenderer.unlitColor(r: 0, g: 0, b: 0)
        XCTAssertEqual([black.0, black.1, black.2], [0, 0, 0])
    }

    func testUnlitColourThresholdIsHalfLuminance() {
        // 128 grey is just over half: kept. 127 is just under: dimmed.
        XCTAssertEqual(CoverScreenRenderer.unlitColor(r: 128, g: 128, b: 128).0, 128)
        XCTAssertEqual(CoverScreenRenderer.unlitColor(r: 127, g: 127, b: 127).0, 76)
    }

    func testFlatSourceIsOneOpaqueColourAtTheLCDResolution() {
        let src = CoverScreenRenderer.flatSource(r: 1, g: 2, b: 3, count: 4)
        XCTAssertEqual(src.count, 4 * 4 * 4)
        for i in stride(from: 0, to: src.count, by: 4) {
            XCTAssertEqual(Array(src[i..<i + 4]), [1, 2, 3, 255])
        }
        XCTAssertEqual(CoverScreenRenderer.flatSource(r: 1, g: 2, b: 3, count: 0), [])
    }

    func testFlatSourceRendersThroughTheRealGrid() {
        let l = layout
        let src = CoverScreenRenderer.flatSource(r: 200, g: 200, b: 200, count: l.count)
        let out = CoverScreenRenderer.render(source: src, look: .pixel, layout: l, gridStrength: 1)
        XCTAssertEqual(out.count, l.lcdSide * l.lcdSide * 4)
        // The last column of every cell is gap (black at strength 1); the
        // first is lit.
        XCTAssertEqual(px(out, side: l.lcdSide, l.cell - 1, 0), [0, 0, 0, 255])
        XCTAssertGreaterThan(px(out, side: l.lcdSide, 0, 0)[0], 200)
    }

    func testRenderSpeedAtMiniSize() {
        let l = CoverScreenLayout.plan(side: 246, scale: 2, pixelSize: 1.5)
        let src = solid(l.count, 120, 80, 200)
        measure { _ = CoverScreenRenderer.render(source: src, look: .handheld, layout: l, gridStrength: 0.55) }
    }
}
