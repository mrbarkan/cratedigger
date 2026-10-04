import Foundation

/// Classic stereo bars: the left channel on the top three rows, the right on
/// the bottom three, each filling from the left with its last column as the
/// peak. The spectrum plays no part here.
public struct HorizontalVUAnimation: MatrixAnimation {
    public private(set) var isAtRest = true

    public init() {}

    /// Cool on the left, hot at the far end of the bar.
    public static func restingHeat(column: Int, row: Int) -> Double {
        Double(column) / Double(MatrixFrame.columns - 1)
    }

    public mutating func frame(for input: MatrixInput) -> MatrixFrame {
        var frame = MatrixFrame.dark
        let half = MatrixFrame.rows / 2
        let leftLit = Self.lit(input.left)
        let rightLit = Self.lit(input.right)
        for row in 0..<MatrixFrame.rows {
            let lit = row >= half ? leftLit : rightLit
            for column in 0..<lit {
                frame[column: column, row: row] = MatrixCell(
                    intensity: column == lit - 1 ? 1 : VerticalVUAnimation.bodyIntensity,
                    heat: Self.restingHeat(column: column, row: row)
                )
            }
        }
        // Stateless: nothing outlives the frame, so a dark frame is rest.
        isAtRest = leftLit == 0 && rightLit == 0
        return frame
    }

    private static func lit(_ level: Double) -> Int {
        min(max(Int((level * Double(MatrixFrame.columns)).rounded()), 0), MatrixFrame.columns)
    }
}
