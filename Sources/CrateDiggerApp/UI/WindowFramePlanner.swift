import CoreGraphics

enum WindowFramePlanningContext {
    case initialLaunch
    case clampToVisibleFrame
}

struct PlannedWindowFrame: Equatable {
    let frame: CGRect
    let minimumSize: CGSize
}

enum WindowFramePlanner {
    static let outerMargin: CGFloat = 28
    static let targetSize = CGSize(width: 1400, height: 920)
    static let minimumSize = CGSize(width: 1200, height: 820)

    static func plan(
        visibleFrame: CGRect,
        currentFrame: CGRect?,
        context: WindowFramePlanningContext
    ) -> PlannedWindowFrame {
        let availableWidth = max(1, visibleFrame.width - (outerMargin * 2))
        let availableHeight = max(1, visibleFrame.height - (outerMargin * 2))
        let adaptiveMinimumSize = CGSize(
            width: min(minimumSize.width, availableWidth),
            height: min(minimumSize.height, availableHeight)
        )

        let targetSize = CGSize(
            width: min(max(Self.targetSize.width, adaptiveMinimumSize.width), availableWidth),
            height: min(max(Self.targetSize.height, adaptiveMinimumSize.height), availableHeight)
        )

        let plannedSize: CGSize
        let plannedOrigin: CGPoint
        switch context {
        case .initialLaunch:
            plannedSize = targetSize
            plannedOrigin = centeredOrigin(for: plannedSize, in: visibleFrame)
        case .clampToVisibleFrame:
            let baseSize = currentFrame?.size ?? targetSize
            plannedSize = CGSize(
                width: min(max(baseSize.width, adaptiveMinimumSize.width), availableWidth),
                height: min(max(baseSize.height, adaptiveMinimumSize.height), availableHeight)
            )
            if let currentFrame {
                plannedOrigin = clampedOrigin(for: CGRect(origin: currentFrame.origin, size: plannedSize), in: visibleFrame)
            } else {
                plannedOrigin = centeredOrigin(for: plannedSize, in: visibleFrame)
            }
        }

        return PlannedWindowFrame(
            frame: CGRect(origin: plannedOrigin, size: plannedSize),
            minimumSize: adaptiveMinimumSize
        )
    }

    private static func centeredOrigin(for size: CGSize, in visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.midY - (size.height / 2)
        )
    }

    private static func clampedOrigin(for frame: CGRect, in visibleFrame: CGRect) -> CGPoint {
        let maxX = visibleFrame.maxX - frame.width
        let maxY = visibleFrame.maxY - frame.height

        return CGPoint(
            x: min(max(frame.origin.x, visibleFrame.minX), maxX),
            y: min(max(frame.origin.y, visibleFrame.minY), maxY)
        )
    }
}
