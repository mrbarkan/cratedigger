import XCTest
@testable import CrateDiggerCore

/// The NOW matrix is drawn as LED segments of a fixed shape with clear gaps,
/// not cells stretched to fill whatever frame the pane hands it. A wider
/// window widens the gutters, never the LEDs.
final class MatrixLayoutTests: XCTestCase {

    /// About the NOW pane's matrix in a normal window.
    private let typical = CGSize(width: 380, height: 66)

    func testSegmentsSpanTheWholeFrame() {
        let layout = MatrixLayout(size: typical)
        let bottomLeft = layout.rect(column: 0, row: 0)
        let topRight = layout.rect(column: MatrixFrame.columns - 1, row: MatrixFrame.rows - 1)
        XCTAssertEqual(bottomLeft.minX, 0, accuracy: 0.001)
        XCTAssertEqual(bottomLeft.maxY, typical.height, accuracy: 0.001)
        XCTAssertEqual(topRight.maxX, typical.width, accuracy: 0.001)
        XCTAssertEqual(topRight.minY, 0, accuracy: 0.001)
    }

    /// Row 0 is the bottom, as on a hardware meter and in `MatrixFrame`.
    func testRowZeroIsTheBottom() {
        let layout = MatrixLayout(size: typical)
        XCTAssertGreaterThan(layout.rect(column: 0, row: 0).minY, layout.rect(column: 0, row: 1).minY)
    }

    func testRowsAreSeparatedByAClearGap() {
        let layout = MatrixLayout(size: typical)
        let gap = layout.rect(column: 0, row: 0).minY - layout.rect(column: 0, row: 1).maxY
        XCTAssertEqual(gap, layout.segment.height * MatrixLayout.rowGapRatio, accuracy: 0.001)
    }

    /// The bug this replaces: a wide window stretched every cell into a brick.
    func testAWideFrameWidensTheGuttersNotTheSegments() {
        let normal = MatrixLayout(size: typical)
        let wide = MatrixLayout(size: CGSize(width: typical.width * 2, height: typical.height))
        XCTAssertEqual(wide.segment, normal.segment)
        XCTAssertLessThanOrEqual(wide.segment.width, wide.segment.height * MatrixLayout.maxAspect + 0.001)
        XCTAssertGreaterThan(wide.columnPitch, normal.columnPitch)
    }

    /// A narrow frame narrows the segments before it closes the gutters, so
    /// the columns never merge back into one slab.
    func testANarrowFrameKeepsTheGutter() {
        let layout = MatrixLayout(size: CGSize(width: 150, height: typical.height))
        let gutter = layout.rect(column: 1, row: 0).minX - layout.rect(column: 0, row: 0).maxX
        XCTAssertEqual(gutter, layout.segment.height * MatrixLayout.minGutterRatio, accuracy: 0.001)
        XCTAssertLessThan(layout.segment.width, layout.segment.height * MatrixLayout.maxAspect)
    }

    func testAnEmptyFrameHasNoSegments() {
        XCTAssertTrue(MatrixLayout(size: .zero).isEmpty)
        XCTAssertTrue(MatrixLayout(size: CGSize(width: 3, height: 66)).isEmpty)
        XCTAssertFalse(MatrixLayout(size: typical).isEmpty)
    }

    // MARK: - Two inks

    /// The panel lights in two inks, cool and hot, never a blend between them:
    /// a vertical VU's top two rows are hot, like a hardware meter's red caps.
    func testVerticalVUIsHotOnlyInItsTopTwoRows() {
        let hotRows = (0..<MatrixFrame.rows).filter {
            MatrixCell.isHot(heat: VerticalVUAnimation.restingHeat(column: 0, row: $0))
        }
        XCTAssertEqual(hotRows, [4, 5])
    }

    func testHorizontalVUIsHotOnlyInItsLastThreeColumns() {
        let hotColumns = (0..<MatrixFrame.columns).filter {
            MatrixCell.isHot(heat: HorizontalVUAnimation.restingHeat(column: $0, row: 0))
        }
        XCTAssertEqual(hotColumns, [9, 10, 11])
    }
}
