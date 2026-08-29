import XCTest
@testable import CrateDiggerCore

final class ArtworkQualityTests: XCTestCase {

    func testNothingAtAllIsMissing() {
        XCTAssertEqual(ArtworkQuality.verdict(longEdges: []), .missing)
        XCTAssertEqual(ArtworkQuality.verdict(longEdges: [0]), .missing)
    }

    func testSmallCoverIsLowResolution() {
        XCTAssertEqual(ArtworkQuality.verdict(longEdges: [300]), .lowResolution)
        XCTAssertEqual(ArtworkQuality.verdict(longEdges: [499]), .lowResolution)
    }

    func testThresholdIsInclusive() {
        XCTAssertEqual(ArtworkQuality.verdict(longEdges: [500]), .adequate)
    }

    /// The best image the album has decides — a big cover.jpg is not dragged
    /// down to "low res" by the thumbnail its tags happen to carry.
    func testBestAvailableDecides() {
        XCTAssertEqual(ArtworkQuality.verdict(longEdges: [300, 1400]), .adequate)
        XCTAssertEqual(ArtworkQuality.verdict(longEdges: [300, 420]), .lowResolution)
    }

    func testCustomThreshold() {
        XCTAssertEqual(ArtworkQuality.verdict(longEdges: [800], threshold: 1000), .lowResolution)
    }

    /// The repair pass must be able to refuse: a smaller candidate is a
    /// downgrade, however well-intentioned the fetch was.
    func testUpgradeRejectsSmallerCandidate() {
        XCTAssertFalse(ArtworkQuality.isUpgrade(from: 600, to: 300))
        XCTAssertFalse(ArtworkQuality.isUpgrade(from: 600, to: 600))
        XCTAssertTrue(ArtworkQuality.isUpgrade(from: 600, to: 1200))
    }

    func testAnythingBeatsNothing() {
        XCTAssertTrue(ArtworkQuality.isUpgrade(from: nil, to: 300))
        XCTAssertTrue(ArtworkQuality.isUpgrade(from: 0, to: 300))
        XCTAssertFalse(ArtworkQuality.isUpgrade(from: nil, to: 0))
    }

    func testLongEdgeTakesTheLargerSide() {
        XCTAssertEqual(ArtworkDimensions(width: 1400, height: 900).longEdge, 1400)
        XCTAssertEqual(ArtworkDimensions(width: 900, height: 1400).longEdge, 1400)
    }
}
