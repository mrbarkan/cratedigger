#if canImport(XCTest)
import CoreGraphics
import XCTest
@testable import CrateDiggerCore

/// `BusyNoise.unit` is the sketch's hash (html:222), and it decides which
/// cells a secure read re-reads, how tall a scan's bars stand and where a dig
/// turns up a find. These pin it to values computed outside Swift, so a
/// constant mistyped in the port fails here rather than moving a find.
final class BusyNoiseTests: XCTestCase {
    func testUnitStaysInHalfOpenUnitRange() {
        for i in 0..<500 {
            let u = BusyNoise.unit(Double(i))
            XCTAssert(u >= 0 && u < 1, "\(i)")
        }
    }

    /// Expected values are literals from the sketch's own `rnd` run in
    /// JavaScript (`Math.sin(i * 127.1 + 311.7) * 43758.5453`, fractional
    /// part), not recomputed here. The tolerance allows for libm and V8
    /// disagreeing in the last bit of `sin`, which the ×43758 amplifies to
    /// around 1e-11; a wrong constant moves the value far more than that.
    func testUnitMatchesTheSketchAtPinnedIndices() {
        XCTAssertEqual(BusyNoise.unit(0), 0.81931173014527303, accuracy: 1e-9)
        XCTAssertEqual(BusyNoise.unit(1), 0.10468242550996365, accuracy: 1e-9)
        XCTAssertEqual(BusyNoise.unit(7), 0.91785499376419466, accuracy: 1e-9)
    }

    func testNonFiniteIndexReadsAsZero() {
        XCTAssertEqual(BusyNoise.unit(.nan), 0)
        XCTAssertEqual(BusyNoise.unit(.infinity), 0)
    }

    func testRingClosesOnItself() {
        let r = BusyNoise.ring(0, 0, 10, segments: 16)
        XCTAssertEqual(r.count, 17)
        XCTAssertEqual(r.first!.x, r.last!.x, accuracy: 1e-9)
        XCTAssertEqual(r.first!.y, r.last!.y, accuracy: 1e-9)
    }
}
#endif
