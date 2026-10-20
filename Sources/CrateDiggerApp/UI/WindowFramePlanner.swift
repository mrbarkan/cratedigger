import CoreGraphics

enum WindowFramePlanningContext {
    case initialLaunch
    case clampToVisibleFrame
}

struct PlannedWindowFrame: Equatable {
    let frame: CGRect
    let minimumSize: CGSize
}

struct CompactWindowPlan: Equatable {
    let frame: CGRect
    let minimumSize: CGSize
    let maximumSize: CGSize
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

    /// The compact player's frame: a fixed height from the theme's geometry,
    /// a width between the deck's minimum and the screen (the one it was last
    /// left at, else `fallbackWidth`, the full window's), and always clamped
    /// on screen. Folding into it (`centred`) puts it in the middle of the
    /// screen; otherwise it stays where it was last left (`savedFrame`), and
    /// with nowhere to stay it is centred too.
    static func compactPlan(
        visibleFrame: CGRect,
        savedFrame: CGRect?,
        fallbackWidth: CGFloat?,
        centred: Bool = false,
        metrics: CompactDeckMetrics
    ) -> CompactWindowPlan {
        let availableWidth = max(1, visibleFrame.width - (outerMargin * 2))
        let height = min(metrics.windowHeight, max(1, visibleFrame.height))
        let minWidth = min(metrics.minWindowWidth, availableWidth)
        let maxWidth = max(minWidth, visibleFrame.width)

        let wanted = savedFrame?.width ?? fallbackWidth ?? targetSize.width
        let width = min(max(wanted, minWidth), max(minWidth, availableWidth))
        let size = CGSize(width: width, height: height)

        let origin: CGPoint
        if !centred, let savedFrame {
            origin = savedFrame.origin
        } else {
            origin = centeredOrigin(for: size, in: visibleFrame)
        }

        return CompactWindowPlan(
            frame: CGRect(origin: clampedOrigin(for: CGRect(origin: origin, size: size), in: visibleFrame), size: size),
            minimumSize: CGSize(width: minWidth, height: height),
            maximumSize: CGSize(width: maxWidth, height: height)
        )
    }

    /// A user resize held to the window's limits. `NSWindow.minSize` is not
    /// enforced against the hosting view's layout during a live resize, so
    /// both layouts apply their own limits in `windowWillResize`.
    static func clampedSize(_ size: CGSize, minimum: CGSize, maximum: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, minimum.width), maximum.width),
            height: min(max(size.height, minimum.height), maximum.height)
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
