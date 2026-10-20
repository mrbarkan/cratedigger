#if canImport(XCTest)
import CoreGraphics
import XCTest
@testable import CrateDiggerApp

final class WindowFramePlannerTests: XCTestCase {
    func testInitialLaunchUsesWorkspaceTargetOnLargeScreen() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1800, height: 1100)

        let plan = WindowFramePlanner.plan(
            visibleFrame: visibleFrame,
            currentFrame: nil,
            context: .initialLaunch
        )

        XCTAssertEqual(plan.frame.size.width, 1400, accuracy: 0.001)
        XCTAssertEqual(plan.frame.size.height, 920, accuracy: 0.001)
        XCTAssertEqual(plan.minimumSize.width, 1200, accuracy: 0.001)
        XCTAssertEqual(plan.minimumSize.height, 820, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(plan.frame.minX, visibleFrame.minX)
        XCTAssertGreaterThanOrEqual(plan.frame.minY, visibleFrame.minY)
        XCTAssertLessThanOrEqual(plan.frame.maxX, visibleFrame.maxX)
        XCTAssertLessThanOrEqual(plan.frame.maxY, visibleFrame.maxY)
    }

    func testInitialLaunchClampsToSmallScreen() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1100, height: 800)

        let plan = WindowFramePlanner.plan(
            visibleFrame: visibleFrame,
            currentFrame: CGRect(x: 50, y: 40, width: 1400, height: 920),
            context: .initialLaunch
        )

        XCTAssertLessThanOrEqual(plan.frame.width, visibleFrame.width - (WindowFramePlanner.outerMargin * 2))
        XCTAssertLessThanOrEqual(plan.frame.height, visibleFrame.height - (WindowFramePlanner.outerMargin * 2))
        XCTAssertLessThanOrEqual(plan.minimumSize.width, plan.frame.width)
        XCTAssertLessThanOrEqual(plan.minimumSize.height, plan.frame.height)
    }

    func testClampToVisibleFrameShrinksOversizedRestoredFrame() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1100, height: 800)
        let currentFrame = CGRect(x: -200, y: -100, width: 1600, height: 1100)

        let plan = WindowFramePlanner.plan(
            visibleFrame: visibleFrame,
            currentFrame: currentFrame,
            context: .clampToVisibleFrame
        )

        XCTAssertLessThanOrEqual(plan.frame.maxX, visibleFrame.maxX)
        XCTAssertLessThanOrEqual(plan.frame.maxY, visibleFrame.maxY)
        XCTAssertGreaterThanOrEqual(plan.frame.minX, visibleFrame.minX)
        XCTAssertGreaterThanOrEqual(plan.frame.minY, visibleFrame.minY)
        XCTAssertLessThanOrEqual(plan.frame.width, visibleFrame.width - (WindowFramePlanner.outerMargin * 2))
        XCTAssertLessThanOrEqual(plan.frame.height, visibleFrame.height - (WindowFramePlanner.outerMargin * 2))
    }

    func testClampToVisibleFrameKeepsCurrentSizeWhenAlreadyValid() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1800, height: 1100)
        let currentFrame = CGRect(x: 80, y: 70, width: 1400, height: 920)

        let plan = WindowFramePlanner.plan(
            visibleFrame: visibleFrame,
            currentFrame: currentFrame,
            context: .clampToVisibleFrame
        )

        XCTAssertEqual(plan.frame.size.width, currentFrame.width, accuracy: 0.001)
        XCTAssertEqual(plan.frame.size.height, currentFrame.height, accuracy: 0.001)
        XCTAssertEqual(plan.frame.origin.x, currentFrame.origin.x, accuracy: 0.001)
        XCTAssertEqual(plan.frame.origin.y, currentFrame.origin.y, accuracy: 0.001)
    }

    // MARK: - Compact player

    private func tallGeometry() -> CarbonGeometry {
        var g = CarbonGeometry.standard
        g.headerHeight = 190
        g.footerHeight = 100
        return g
    }

    func testCompactHeightFollowsGeometry() {
        let visible = CGRect(x: 0, y: 0, width: 1800, height: 1100)
        let standard = WindowFramePlanner.compactPlan(
            visibleFrame: visible, savedFrame: nil, fallbackWidth: nil,
            metrics: CompactDeckMetrics(geometry: .standard))
        XCTAssertEqual(standard.frame.height, 302, accuracy: 0.001)
        XCTAssertEqual(standard.minimumSize.height, 302, accuracy: 0.001)
        XCTAssertEqual(standard.maximumSize.height, 302, accuracy: 0.001)

        let tallMetrics = CompactDeckMetrics(geometry: tallGeometry())
        let tall = WindowFramePlanner.compactPlan(
            visibleFrame: visible, savedFrame: standard.frame, fallbackWidth: nil, metrics: tallMetrics)
        XCTAssertEqual(tall.frame.height, tallMetrics.windowHeight, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(tall.minimumSize.width, tallMetrics.minWindowWidth - 0.001)
    }

    func testFoldingCentresTheCompactDeckOnScreen() {
        let visible = CGRect(x: 0, y: 25, width: 1800, height: 1075)
        let saved = CGRect(x: 300, y: 40, width: 1250, height: 302)
        let plan = WindowFramePlanner.compactPlan(
            visibleFrame: visible, savedFrame: saved, fallbackWidth: 1400, centred: true,
            metrics: CompactDeckMetrics(geometry: .standard))
        XCTAssertEqual(plan.frame.width, 1250, accuracy: 0.001)   // the saved width survives
        XCTAssertEqual(plan.frame.midX, visible.midX, accuracy: 0.001)
        XCTAssertEqual(plan.frame.midY, visible.midY, accuracy: 0.001)
    }

    func testFirstFoldTakesTheFullWindowsWidthAndCentres() {
        let visible = CGRect(x: 0, y: 0, width: 1800, height: 1100)
        let plan = WindowFramePlanner.compactPlan(
            visibleFrame: visible, savedFrame: nil, fallbackWidth: 1400, centred: true,
            metrics: CompactDeckMetrics(geometry: .standard))
        XCTAssertEqual(plan.frame.width, 1400, accuracy: 0.001)
        XCTAssertEqual(plan.frame.midX, visible.midX, accuracy: 0.001)
        XCTAssertEqual(plan.frame.midY, visible.midY, accuracy: 0.001)
        XCTAssertEqual(plan.minimumSize.width, 1174, accuracy: 0.001)
    }

    /// Launch, and a screen or theme change, leave the deck where it was.
    func testCompactPlanRestoresSavedFrameWhenNotFolding() {
        let visible = CGRect(x: 0, y: 0, width: 1800, height: 1100)
        let saved = CGRect(x: 300, y: 40, width: 1250, height: 302)
        let plan = WindowFramePlanner.compactPlan(
            visibleFrame: visible, savedFrame: saved, fallbackWidth: 1400,
            metrics: CompactDeckMetrics(geometry: .standard))
        XCTAssertEqual(plan.frame, saved)
    }

    func testCompactPlanClampsOnNarrowScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1100, height: 700)
        let plan = WindowFramePlanner.compactPlan(
            visibleFrame: visible,
            savedFrame: CGRect(x: 900, y: 650, width: 1300, height: 302),
            fallbackWidth: nil,
            metrics: CompactDeckMetrics(geometry: .standard))
        XCTAssertGreaterThanOrEqual(plan.frame.minX, visible.minX)
        XCTAssertGreaterThanOrEqual(plan.frame.minY, visible.minY)
        XCTAssertLessThanOrEqual(plan.frame.maxX, visible.maxX)
        XCTAssertLessThanOrEqual(plan.frame.maxY, visible.maxY)
        XCTAssertLessThanOrEqual(plan.minimumSize.width, plan.frame.width)
        XCTAssertEqual(plan.frame.height, 302, accuracy: 0.001)
    }

    func testCompactWidthNeverDropsBelowItsMinimumOnALargeScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1800, height: 1100)
        let plan = WindowFramePlanner.compactPlan(
            visibleFrame: visible,
            savedFrame: CGRect(x: 0, y: 0, width: 600, height: 302),
            fallbackWidth: nil,
            metrics: CompactDeckMetrics(geometry: .standard))
        XCTAssertEqual(plan.frame.width, 1174, accuracy: 0.001)
    }

    func testResizeClampHoldsTheCompactWindowToItsLimits() {
        let minimum = CGSize(width: 1174, height: 302)
        let maximum = CGSize(width: 1512, height: 302)
        XCTAssertEqual(WindowFramePlanner.clampedSize(CGSize(width: 545, height: 302), minimum: minimum, maximum: maximum),
                       CGSize(width: 1174, height: 302))
        XCTAssertEqual(WindowFramePlanner.clampedSize(CGSize(width: 1300, height: 600), minimum: minimum, maximum: maximum),
                       CGSize(width: 1300, height: 302))
        XCTAssertEqual(WindowFramePlanner.clampedSize(CGSize(width: 4000, height: 100), minimum: minimum, maximum: maximum),
                       CGSize(width: 1512, height: 302))
    }

    /// The full window's floor holds during a drag, not only at launch: it
    /// used to be draggable down to 645 pt wide.
    func testResizeClampHoldsTheFullWindowToItsMinimum() {
        let plan = WindowFramePlanner.plan(
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1080),
            currentFrame: nil,
            context: .initialLaunch)
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        XCTAssertEqual(WindowFramePlanner.clampedSize(CGSize(width: 645, height: 400), minimum: plan.minimumSize, maximum: unbounded),
                       CGSize(width: 1200, height: 820))
        XCTAssertEqual(WindowFramePlanner.clampedSize(CGSize(width: 1500, height: 1000), minimum: plan.minimumSize, maximum: unbounded),
                       CGSize(width: 1500, height: 1000))
    }
}
#endif
