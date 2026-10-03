#if canImport(XCTest)
import CoreGraphics
import XCTest
@testable import CrateDiggerApp

final class CompactDeckMetricsTests: XCTestCase {
    func testStandardGeometryNumbers() {
        let m = CompactDeckMetrics(geometry: .standard)
        XCTAssertEqual(m.rowHeight, 274, accuracy: 0.001)        // 170 + 12 + 92
        XCTAssertEqual(m.artSide, 230, accuracy: 0.001)          // 274 - 18 - 20 - 6
        XCTAssertEqual(m.transportWidth, 420, accuracy: 0.001)   // 6×46 + 78 + 6×11
        XCTAssertEqual(m.footerMinWidth, 896, accuracy: 0.001)   // 52 + 2×184 + 2×28 + 420
        XCTAssertEqual(m.windowHeight, 302, accuracy: 0.001)     // 2×14 + 274
        XCTAssertEqual(m.minWindowWidth, 1174, accuracy: 0.001)  // 2×18 + 230 + 12 + 896
    }

    func testLocateKeyIsTheOnlyAsymmetry() {
        XCTAssertEqual(TransportCluster.keyCounts(showsLocate: true).left, 4)
        XCTAssertEqual(TransportCluster.keyCounts(showsLocate: true).right, 3)
        XCTAssertEqual(TransportCluster.keyCounts(showsLocate: false).left, 3)
        XCTAssertEqual(TransportCluster.keyCounts(showsLocate: false).right, 3)
    }
}
#endif
