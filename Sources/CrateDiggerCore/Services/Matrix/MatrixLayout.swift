import CoreGraphics

/// Where each LED of the NOW matrix sits inside the frame the pane gives it.
///
/// The LEDs are segments of a fixed shape with clear gaps between them, the
/// way a hardware graphic-EQ meter is built, not cells stretched to fill the
/// frame. Their height comes from the frame's height; their width is capped
/// at `maxAspect` times that, and whatever width is left over goes into the
/// gutters between columns. So a wider window spaces the columns out and
/// never turns the LEDs into bricks, which is how the solid 12 × 6 slab this
/// replaced came to outweigh the track title beside it.
///
/// The first column starts on the frame's leading edge and the last ends on
/// its trailing edge, so the matrix lines up with whatever the pane aligns its
/// frame to.
public struct MatrixLayout: Equatable, Sendable {
    /// The gap between rows, as a fraction of a segment's height.
    public static let rowGapRatio: CGFloat = 0.45
    /// The widest a segment may be, as a multiple of its height.
    public static let maxAspect: CGFloat = 2.0
    /// The narrowest gutter between columns, as a fraction of a segment's
    /// height. A narrow frame shrinks the segments before it goes below this.
    public static let minGutterRatio: CGFloat = 0.45

    public let size: CGSize
    public let segment: CGSize
    /// From one column's leading edge to the next one's.
    public let columnPitch: CGFloat
    /// From one row's top edge to the next one's.
    public let rowPitch: CGFloat

    public init(size: CGSize, columns: Int = MatrixFrame.columns, rows: Int = MatrixFrame.rows) {
        self.size = size
        let height = size.height / (CGFloat(rows) + CGFloat(rows - 1) * Self.rowGapRatio)
        let minGutter = height * Self.minGutterRatio
        let widthThatFits = (size.width - CGFloat(columns - 1) * minGutter) / CGFloat(columns)
        let width = min(height * Self.maxAspect, widthThatFits)
        guard height > 0, width > 0 else {
            segment = .zero
            columnPitch = 0
            rowPitch = 0
            return
        }
        segment = CGSize(width: width, height: height)
        columnPitch = columns > 1 ? (size.width - width) / CGFloat(columns - 1) : 0
        rowPitch = height * (1 + Self.rowGapRatio)
    }

    /// True when the frame is too small to draw any LED.
    public var isEmpty: Bool { segment.width <= 0 || segment.height <= 0 }

    /// The segment for one cell, in the frame's own coordinates (y down).
    /// Row 0 is the bottom, as in `MatrixFrame`.
    public func rect(column: Int, row: Int) -> CGRect {
        CGRect(x: CGFloat(column) * columnPitch,
               y: size.height - segment.height - CGFloat(row) * rowPitch,
               width: segment.width,
               height: segment.height)
    }
}
