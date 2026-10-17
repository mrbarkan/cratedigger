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

    /// The titlebar LED's compact spot: flush with the art column's trailing
    /// edge, and its whole hit square clear of the display, which starts one
    /// `mainGap` further right. A theme that widens the gap or the margins
    /// must not put the lamp back on the glass.
    func testStatusLampSitsOverTheArtColumnClearOfTheDisplay() {
        for geometry in [CarbonGeometry.standard, wideMarginGeometry()] {
            let m = CompactDeckMetrics(geometry: geometry)
            let artTrailing = geometry.chassisInsetH + m.artSide
            let displayLeading = artTrailing + geometry.mainGap
            XCTAssertEqual(m.statusLampCenterX + CompactDeckMetrics.statusLampHitSide / 2, artTrailing, accuracy: 0.001)
            XCTAssertLessThanOrEqual(m.statusLampCenterX + CompactDeckMetrics.statusLampHitSide / 2, displayLeading)
            XCTAssertGreaterThan(m.statusLampCenterX - CompactDeckMetrics.statusLampHitSide / 2, geometry.chassisInsetH)
        }
        XCTAssertEqual(CompactDeckMetrics(geometry: .standard).statusLampCenterX, 239, accuracy: 0.001) // 18 + 230 - 9
    }

    private func wideMarginGeometry() -> CarbonGeometry {
        var geometry = CarbonGeometry.standard
        geometry.chassisInsetH = 30
        geometry.mainGap = 6
        return geometry
    }

    /// The full footer and the compact one share one transport: no key
    /// either side of PLAY that the other lacks, so the dome is centred
    /// without padding.
    func testTransportIsSymmetric() {
        XCTAssertEqual(TransportCluster.keysPerSide, 3)
    }
}
#endif
