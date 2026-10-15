#if canImport(XCTest)
import CoreGraphics
import XCTest
@testable import CrateDiggerCore

/// The drawing is the contract between the scenes and the renderer, so its
/// recording is checked here shape by shape.
final class BusyDrawingTests: XCTestCase {
    func testEachPenCallRecordsOneShape() {
        var d = BusyDrawing(size: BusyDrawing.sceneSize)
        d.line(0, 0, 10, 0, .cool)
        d.dot(5, 5, 1, .hot)
        d.block(1, 1, 2, 2, .dim)
        d.rect(0, 0, 4, 4, .foreground, fill: .background)
        XCTAssertEqual(d.shapes.count, 4)
        XCTAssertEqual(d.inks, [.cool, .hot, .dim, .foreground, .background])
    }

    func testBoundsCoverLinesCirclesAndText() {
        var d = BusyDrawing(size: BusyDrawing.sceneSize)
        d.line(10, 20, 30, 20)
        d.circle(50, 50, 10)
        d.text("OK", 100, 60, .hot, size: 8, align: .center)
        let b = d.bounds
        XCTAssertEqual(b.minX, 10, accuracy: 0.01)
        XCTAssertEqual(b.minY, 20, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(b.maxX, 104.8 - 0.01)   // 2 × 8 × 0.6 / 2 past centre
        XCTAssertEqual(b.maxY, 62, accuracy: 0.01)          // baseline + size × 0.25
    }

    func testClippedBracketsItsShapes() {
        var d = BusyDrawing(size: BusyDrawing.sceneSize)
        d.clipped(to: CGRect(x: 0, y: 0, width: 20, height: 10), radius: 5) { $0.circle(5, 5, 8, .cool) }
        guard case .clipBegin = d.shapes.first, case .clipEnd = d.shapes.last else {
            return XCTFail("clip not bracketed: \(d.shapes)")
        }
        XCTAssertEqual(d.shapes.count, 3)
    }

    func testArcBoundsFollowTheSweep() {
        var d = BusyDrawing(size: BusyDrawing.miniSize)
        d.arc(6, 2.2, 3.2, -0.7, 0.7, .cool)          // the download mini's antenna arc
        XCTAssertEqual(d.bounds.minY, 2.2 - 3.2 * sin(0.7), accuracy: 0.01)   // ≈ 0.14, not −1.0
        XCTAssertEqual(d.bounds.maxX, 9.2, accuracy: 0.01)                    // passes through angle 0
    }

    func testArcAtAHugeAngleStillBounds() {
        // At 1e17 adjacent Doubles are further apart than a quarter-turn, so
        // walking the raw angle would never advance; this must return.
        var d = BusyDrawing(size: BusyDrawing.sceneSize)
        d.arc(0, 0, 1, 1e17, 1e17 + 1, .cool)
        XCTAssertTrue(d.bounds.minX.isFinite && d.bounds.maxX.isFinite)
        XCTAssertLessThanOrEqual(d.bounds.width, 2.01)
    }

    func testEllipseWithNegativeRadiiIsBoundedByTheLargerMagnitude() {
        var d = BusyDrawing(size: BusyDrawing.sceneSize)
        d.ellipse(50, 50, rx: -10, ry: -4, rotation: 0, .hot)
        XCTAssertEqual(d.bounds.width, 20, accuracy: 0.01)
    }

    func testClippedShapesAreBoundedByTheClip() {
        var d = BusyDrawing(size: BusyDrawing.sceneSize)
        d.clipped(to: CGRect(x: 0, y: 0, width: 240, height: 100), radius: 0) { $0.rect(-78, 32, 88, 60) }
        XCTAssertEqual(d.bounds.minX, 0, accuracy: 0.01)
    }

    func testNonFiniteInputIsSanitised() {
        var d = BusyDrawing(size: BusyDrawing.miniSize)
        d.line(.nan, 1, .infinity, 2)
        XCTAssertTrue(d.bounds.minX.isFinite && d.bounds.maxX.isFinite)
    }

    func testEqualDrawingsCompareEqual() {
        func make() -> BusyDrawing { var d = BusyDrawing(size: BusyDrawing.miniSize); d.arc(6, 6, 3, -0.7, 0.7, .cool); return d }
        XCTAssertEqual(make(), make())
    }
}
#endif
