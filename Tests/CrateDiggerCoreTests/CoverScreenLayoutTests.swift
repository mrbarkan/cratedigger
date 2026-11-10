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
