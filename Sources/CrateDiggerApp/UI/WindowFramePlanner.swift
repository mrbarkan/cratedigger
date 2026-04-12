import CoreGraphics

enum WindowLayoutMode {
    case emptyCompact
    case workspace

    var targetSize: CGSize {
        switch self {
        case .emptyCompact:
            return CGSize(width: 960, height: 620)
        case .workspace:
            return CGSize(width: 1180, height: 760)
        }
    }

    var minimumSize: CGSize {
        switch self {
        case .emptyCompact:
            return CGSize(width: 760, height: 540)
        case .workspace:
            return CGSize(width: 940, height: 620)
        }
    }

    var collapsesInspector: Bool {
        self == .emptyCompact
    }
}

enum WindowFramePlanningContext {
    case initialLaunch
    case layoutTransition
    case clampToVisibleFrame
}

struct PlannedWindowFrame: Equatable {
    let frame: CGRect
    let minimumSize: CGSize
}

enum WindowFramePlanner {
    static let outerMargin: CGFloat = 28

    static func plan(
        visibleFrame: CGRect,
        currentFrame: CGRect?,
        mode: WindowLayoutMode,
        context: WindowFramePlanningContext
    ) -> PlannedWindowFrame {
        let availableWidth = max(1, visibleFrame.width - (outerMargin * 2))
        let availableHeight = max(1, visibleFrame.height - (outerMargin * 2))
        let adaptiveMinimumSize = CGSize(
            width: min(mode.minimumSize.width, availableWidth),
            height: min(mode.minimumSize.height, availableHeight)
        )

        let targetSize = CGSize(
            width: min(max(mode.targetSize.width, adaptiveMinimumSize.width), availableWidth),
            height: min(max(mode.targetSize.height, adaptiveMinimumSize.height), availableHeight)
        )

        let plannedSize: CGSize
        switch context {
        case .initialLaunch, .layoutTransition:
            plannedSize = targetSize
        case .clampToVisibleFrame:
            let baseSize = currentFrame?.size ?? targetSize
            plannedSize = CGSize(
                width: min(max(baseSize.width, adaptiveMinimumSize.width), availableWidth),
                height: min(max(baseSize.height, adaptiveMinimumSize.height), availableHeight)
            )
        }

        let plannedOrigin: CGPoint
        switch context {
        case .initialLaunch, .layoutTransition:
            plannedOrigin = centeredOrigin(for: plannedSize, in: visibleFrame)
        case .clampToVisibleFrame:
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
