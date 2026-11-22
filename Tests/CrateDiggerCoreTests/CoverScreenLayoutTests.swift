import XCTest
@testable import CrateDiggerCore

final class CoverScreenLayoutTests: XCTestCase {
    private func check(_ side: Double, _ scale: Double, cell: Int, count: Int, lcd: Int, band: Int,
                       file: StaticString = #filePath, line: UInt = #line) {
        let l = CoverScreenLayout.plan(side: side, scale: scale, pixelSize: 1.5)
        XCTAssertEqual(l, CoverScreenLayout(cell: cell, count: count, lcdSide: lcd, band: band), file: file, line: line)
    }

    func testCompactWell() {
        check(230, 2, cell: 3, count: 145, lcd: 435, band: 12)
        check(230, 1, cell: 3, count: 72, lcd: 216, band: 7)
    }

    func testMiniArt() {
        check(246, 2, cell: 3, count: 156, lcd: 468, band: 12)
        check(246, 1, cell: 3, count: 78, lcd: 234, band: 6)
    }

    func testCompactOddLeftoverGoesBottomRight() {
        let l = CoverScreenLayout.plan(side: 230, scale: 2, pixelSize: 1.5)
        XCTAssertEqual(460 - l.lcdSide - l.band, 13)
    }

    func testCellNeverBelowThree() {
        XCTAssertEqual(CoverScreenLayout.plan(side: 230, scale: 1, pixelSize: 2).cell, 3)
        XCTAssertEqual(CoverScreenLayout.plan(side: 230, scale: 1, pixelSize: 3).cell, 3)
        XCTAssertEqual(CoverScreenLayout.plan(side: 230, scale: 1, pixelSize: 4).cell, 4)
        XCTAssertEqual(CoverScreenLayout.plan(side: 230, scale: 2, pixelSize: 2).cell, 4)
        XCTAssertEqual(CoverScreenLayout.plan(side: 230, scale: 2, pixelSize: 3).cell, 6)
        XCTAssertEqual(CoverScreenLayout.plan(side: 230, scale: 2, pixelSize: 4).cell, 8)
    }

    func testTooSmallHasNoScreen() {
        XCTAssertEqual(CoverScreenLayout.plan(side: 20, scale: 2, pixelSize: 1.5).count, 0)
        XCTAssertEqual(CoverScreenLayout.plan(side: 0, scale: 2, pixelSize: 1.5).count, 0)
        XCTAssertEqual(CoverScreenLayout.plan(side: 12, scale: 1, pixelSize: 1.5).count, 0)
        // Exactly 8 cells fits; 7 does not.
        XCTAssertEqual(CoverScreenLayout.plan(side: 12 + 24, scale: 1, pixelSize: 1.5).count, 8)
        XCTAssertEqual(CoverScreenLayout.plan(side: 12 + 23, scale: 1, pixelSize: 1.5).count, 0)
    }

    /// A side that is not a positive, finite number has no screen.
    func testNonsenseSideHasNoScreen() {
        for side in [Double.nan, .infinity, -.infinity, 0, -230, -.leastNonzeroMagnitude] {
            let l = CoverScreenLayout.plan(side: side, scale: 2, pixelSize: 1.5)
            XCTAssertEqual(l.count, 0, "side \(side)")
            XCTAssertEqual(l.lcdSide, 0, "side \(side)")
            XCTAssertEqual(l.band, 0, "side \(side)")
            XCTAssertEqual(l.cell, 3, "side \(side)")
        }
    }

    /// A scale that is not a positive, finite number plans at 1x.
    func testNonsenseScalePlansAtOneX() {
        let oneX = CoverScreenLayout.plan(side: 230, scale: 1, pixelSize: 1.5)
        for scale in [Double.nan, .infinity, -.infinity, 0, -2] {
            XCTAssertEqual(CoverScreenLayout.plan(side: 230, scale: scale, pixelSize: 1.5), oneX, "scale \(scale)")
        }
    }

    /// A pixel size that is not a positive, finite number is the smallest cell.
    func testNonsensePixelSizeIsTheSmallestCell() {
        let smallest = CoverScreenLayout.plan(side: 230, scale: 2, pixelSize: 1.5)
        XCTAssertEqual(smallest.cell, 3)
        for pixelSize in [Double.nan, .infinity, -.infinity, 0, -4] {
            XCTAssertEqual(CoverScreenLayout.plan(side: 230, scale: 2, pixelSize: pixelSize), smallest,
                           "pixelSize \(pixelSize)")
        }
    }

    /// Huge but finite inputs used to trap in the `Int` conversion. Now each
    /// gives a layout, with no screen.
    func testHugeFiniteInputsHaveNoScreenAndDoNotTrap() {
        let huge = [1e300, Double.greatestFiniteMagnitude, Double(Int.max), 1e19]
        for value in huge {
            XCTAssertEqual(CoverScreenLayout.plan(side: value, scale: 2, pixelSize: 1.5).count, 0, "side \(value)")
            XCTAssertEqual(CoverScreenLayout.plan(side: 230, scale: value, pixelSize: 1.5).count, 0, "scale \(value)")
            XCTAssertEqual(CoverScreenLayout.plan(side: 230, scale: 2, pixelSize: value).count, 0, "pixelSize \(value)")
            XCTAssertEqual(CoverScreenLayout.plan(side: 230, scale: 2, pixelSize: -value).cell, 3, "pixelSize -\(value)")
            XCTAssertEqual(CoverScreenLayout.plan(side: 230, scale: 2, pixelSize: 1.5, minimumBand: value).count, 0,
                           "minimumBand \(value)")
        }
        // Just inside the ceiling still plans a screen.
        let largest = Double(CoverScreenLayout.maximumPixels) / 2
        XCTAssertGreaterThan(CoverScreenLayout.plan(side: largest, scale: 2, pixelSize: 1.5).count, 0)
        XCTAssertEqual(CoverScreenLayout.plan(side: largest + 1, scale: 2, pixelSize: 1.5).count, 0)
        // A NaN band is no band rather than a trap.
        XCTAssertGreaterThan(CoverScreenLayout.plan(side: 230, scale: 2, pixelSize: 1.5, minimumBand: .nan).count, 0)
    }

    func testPixelSnap() {
        XCTAssertEqual(CoverScreenLayout.pixelSnap(origin: 18, scale: 2), 0)
        XCTAssertEqual(CoverScreenLayout.pixelSnap(origin: 13, scale: 1), 0)
        XCTAssertEqual(CoverScreenLayout.pixelSnap(origin: 10.3, scale: 1), -0.3, accuracy: 1e-9)
        XCTAssertEqual(CoverScreenLayout.pixelSnap(origin: 10.7, scale: 1), 0.3, accuracy: 1e-9)
        XCTAssertEqual(CoverScreenLayout.pixelSnap(origin: 10.3, scale: 2), 0.2, accuracy: 1e-9)
        XCTAssertEqual(CoverScreenLayout.pixelSnap(origin: 10.1, scale: 2), -0.1, accuracy: 1e-9)
    }

    func testSweepInvariants() {
        for scale in [1.0, 2.0] {
            for pixelSize in CoverScreenLook.pixelSizes {
                var side = 20.0
                while side <= 700 {
                    let l = CoverScreenLayout.plan(side: side, scale: scale, pixelSize: pixelSize)
                    let well = Int((side * scale).rounded())
                    XCTAssertLessThanOrEqual(2 * l.band + l.lcdSide, well, "side \(side) @\(scale)x")
                    XCTAssertEqual(l.lcdSide % l.cell, 0)
                    XCTAssertEqual(l.lcdSide, l.cell * l.count)
                    XCTAssertGreaterThanOrEqual(l.cell, 3)
                    if l.count > 0 {
                        XCTAssertGreaterThanOrEqual(l.count, 8)
                        XCTAssertGreaterThanOrEqual(l.band, Int((6 * scale).rounded()))
                    }
                    side += 0.7
                }
            }
        }
    }
}
