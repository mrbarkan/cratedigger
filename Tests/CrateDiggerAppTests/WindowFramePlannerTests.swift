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
            mode: .workspace,
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
            mode: .workspace,
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
            mode: .workspace,
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
            mode: .workspace,
            context: .clampToVisibleFrame
        )

        XCTAssertEqual(plan.frame.size.width, currentFrame.width, accuracy: 0.001)
        XCTAssertEqual(plan.frame.size.height, currentFrame.height, accuracy: 0.001)
        XCTAssertEqual(plan.frame.origin.x, currentFrame.origin.x, accuracy: 0.001)
        XCTAssertEqual(plan.frame.origin.y, currentFrame.origin.y, accuracy: 0.001)
    }
}
#endif
