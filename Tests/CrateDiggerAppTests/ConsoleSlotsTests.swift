import CrateDiggerCore
import XCTest
@testable import CrateDiggerApp

final class ConsoleSlotsTests: XCTestCase {
    private let geometry = CarbonGeometry.standard
    private var metrics: CompactDeckMetrics { CompactDeckMetrics(geometry: geometry) }

    /// A window's content size: its frame less the chassis insets.
    private func content(width: CGFloat, height: CGFloat) -> CGSize {
        CGSize(width: width - 2 * geometry.chassisInsetH, height: height - 2 * geometry.chassisInsetV)
    }

    func testTheDisplayKeepsItsRowInBothLayouts() {
        let full = ConsoleSlots.display(in: .full, size: content(width: 1400, height: 920), geometry: geometry)
        let compact = ConsoleSlots.display(
            in: .compact, size: content(width: 1400, height: metrics.windowHeight), geometry: geometry)
        XCTAssertEqual(full.minY, 0)
        XCTAssertEqual(compact.minY, 0)
        XCTAssertEqual(full.height, geometry.headerHeight)
        XCTAssertEqual(compact.height, geometry.headerHeight)
    }

    func testFullDisplaySitsBetweenTheBrandBlockAndTheSwitcher() {
        let size = content(width: 1400, height: 920)
        let display = ConsoleSlots.display(in: .full, size: size, geometry: geometry)
        XCTAssertEqual(display.minX, geometry.brandWidth + geometry.mainGap, accuracy: 0.001)
        XCTAssertEqual(display.maxX, size.width - geometry.viewSwitchWidth - geometry.mainGap, accuracy: 0.001)
    }

    func testCompactDisplayRunsFromTheArtColumnToTheMargin() {
        let size = content(width: 1300, height: metrics.windowHeight)
        let display = ConsoleSlots.display(in: .compact, size: size, geometry: geometry)
        XCTAssertEqual(display.minX, metrics.artSide + geometry.mainGap, accuracy: 0.001)
        XCTAssertEqual(display.maxX, size.width, accuracy: 0.001)
    }

    /// What lets the transport ride the window's bottom edge through a fold.
    func testTheTransportSitsOnTheBottomEdgeInBothLayouts() {
        let fullSize = content(width: 1400, height: 920)
        let compactSize = content(width: 1400, height: metrics.windowHeight)
        let full = ConsoleSlots.transport(in: .full, size: fullSize, geometry: geometry)
        let compact = ConsoleSlots.transport(in: .compact, size: compactSize, geometry: geometry)
        XCTAssertEqual(full.maxY, fullSize.height, accuracy: 0.001)
        XCTAssertEqual(compact.maxY, compactSize.height, accuracy: 0.001)
        XCTAssertEqual(full.minX, 0)
        XCTAssertEqual(full.width, fullSize.width, accuracy: 0.001)
    }

    func testCompactTransportSitsUnderTheDisplayWithTheRowGapBetween() {
        let size = content(width: 1300, height: metrics.windowHeight)
        let display = ConsoleSlots.display(in: .compact, size: size, geometry: geometry)
        let transport = ConsoleSlots.transport(in: .compact, size: size, geometry: geometry)
        XCTAssertEqual(transport.minX, display.minX, accuracy: 0.001)
        XCTAssertEqual(transport.width, display.width, accuracy: 0.001)
        XCTAssertEqual(transport.minY, display.maxY + geometry.chassisRowGap, accuracy: 0.001)
    }

    /// The compact window is only as wide as the deck needs.
    func testCompactTransportKeepsItsMinimumWidthAtTheNarrowestWindow() {
        let size = content(width: metrics.minWindowWidth, height: metrics.windowHeight)
        let transport = ConsoleSlots.transport(in: .compact, size: size, geometry: geometry)
        XCTAssertEqual(transport.width, metrics.footerMinWidth, accuracy: 0.001)
    }
}
