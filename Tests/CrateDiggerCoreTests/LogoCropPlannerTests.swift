#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// The cropper's geometry: where an image lands in the header slot for a
/// given zoom and drag. The editor's viewport, its 1:1 preview and the
/// exported bitmap all draw from `imageRect`, so this is the only place the
/// framing is decided.
final class LogoCropPlannerTests: XCTestCase {
    private let slot = CGSize(width: 110, height: 20)

    func testFitCentresTheWholeImageInsideTheSlot() {
        let rect = LogoCropPlanner.imageRect(image: CGSize(width: 400, height: 400), in: slot, crop: .fit)
        XCTAssertEqual(rect, CGRect(x: 45, y: 0, width: 20, height: 20), "a square fits the height and sits in the middle")

        let wide = LogoCropPlanner.imageRect(image: CGSize(width: 1100, height: 100), in: slot, crop: .fit)
        XCTAssertEqual(wide, CGRect(x: 0, y: 5, width: 110, height: 10), "a wide image fits the width")
    }

    func testZoomGrowsAboutTheCentre() {
        let rect = LogoCropPlanner.imageRect(image: CGSize(width: 400, height: 400), in: slot, crop: LogoCrop(zoom: 2))
        XCTAssertEqual(rect, CGRect(x: 35, y: -10, width: 40, height: 40))
    }

    func testFillZoomCoversTheSlot() {
        let image = CGSize(width: 400, height: 400)
        let zoom = LogoCropPlanner.fillZoom(image: image, in: slot)
        let rect = LogoCropPlanner.imageRect(image: image, in: slot, crop: LogoCrop(zoom: zoom))
        XCTAssertEqual(rect.width, 110, accuracy: 0.001)
        XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
    }

    /// Enlarged past the slot, a drag stops when the image's edge reaches the
    /// slot's edge: no chassis ever shows through the middle of a logo.
    func testDragCannotUncoverTheSlotWhenZoomedIn() {
        let image = CGSize(width: 1100, height: 100)   // fits the width exactly
        let crop = LogoCrop(zoom: 2, offset: CGSize(width: 5, height: 5))   // way past any bound
        let rect = LogoCropPlanner.imageRect(image: image, in: slot, crop: crop)
        XCTAssertEqual(rect.minX, 0, accuracy: 0.001, "slid right until its left edge met the slot's")
        XCTAssertEqual(rect.maxY, 20, accuracy: 0.001)
    }

    /// Smaller than the slot, a drag stops at the slot's edge from the inside,
    /// so a mark can be parked flush right but never pushed out of view.
    func testDragKeepsASmallMarkInsideTheSlot() {
        let image = CGSize(width: 400, height: 400)
        let crop = LogoCrop(zoom: 1, offset: CGSize(width: 5, height: 0))
        let rect = LogoCropPlanner.imageRect(image: image, in: slot, crop: crop)
        XCTAssertEqual(rect.maxX, 110, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.001)
    }

    func testClampKeepsZoomInRange() {
        let clamped = LogoCropPlanner.clamped(LogoCrop(zoom: 99), image: CGSize(width: 10, height: 10), in: slot)
        XCTAssertEqual(clamped.zoom, LogoCrop.zoomRange.upperBound)
        let tiny = LogoCropPlanner.clamped(LogoCrop(zoom: 0), image: CGSize(width: 10, height: 10), in: slot)
        XCTAssertEqual(tiny.zoom, LogoCrop.zoomRange.lowerBound)
    }

    /// Offsets are slot-relative, so the same crop drawn in a viewport four
    /// times the slot's size is the same picture, four times bigger.
    func testCropIsIndependentOfTheFrameItIsDrawnIn() {
        let image = CGSize(width: 800, height: 300)
        let crop = LogoCrop(zoom: 1.5, offset: CGSize(width: 0.1, height: -0.05))
        let small = LogoCropPlanner.imageRect(image: image, in: slot, crop: crop)
        let large = LogoCropPlanner.imageRect(image: image, in: CGSize(width: 440, height: 80), crop: crop)
        XCTAssertEqual(large.minX, small.minX * 4, accuracy: 0.001)
        XCTAssertEqual(large.minY, small.minY * 4, accuracy: 0.001)
        XCTAssertEqual(large.width, small.width * 4, accuracy: 0.001)
    }

    func testDegenerateImageDoesNotDivideByZero() {
        let rect = LogoCropPlanner.imageRect(image: .zero, in: slot, crop: .fit)
        XCTAssertFalse(rect.width.isNaN)
        XCTAssertFalse(rect.origin.x.isNaN)
    }
}
#endif
