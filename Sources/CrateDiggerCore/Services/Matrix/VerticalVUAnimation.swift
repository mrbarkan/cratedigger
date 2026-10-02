import Foundation

/// The spectrum: one column per band, 20 Hz on the left to 20 kHz on the
/// right, rising from the bottom with its top segment as the peak.
public struct VerticalVUAnimation: MatrixAnimation {
    /// The segments under the peak, a step dimmer so the peak reads as a cap.
    static let bodyIntensity = 0.75

    public private(set) var isAtRest = true

    public init() {}

    /// Cool at the bottom, hot at the top, like the red top segments of a
    /// hardware meter.
    public static func restingHeat(column: Int, row: Int) -> Double {
        Double(row) / Double(MatrixFrame.rows - 1)
    }

    public mutating func frame(for input: MatrixInput) -> MatrixFrame {
        var frame = MatrixFrame.dark
        var anyLit = false
        for column in 0..<MatrixFrame.columns {
            let lit = min(max(Int((input.bands[column] * Double(MatrixFrame.rows)).rounded()), 0), MatrixFrame.rows)
            for row in 0..<lit {
                frame[column: column, row: row] = MatrixCell(
                    intensity: row == lit - 1 ? 1 : Self.bodyIntensity,
                    heat: Self.restingHeat(column: column, row: row)
                )
                anyLit = true
            }
        }
        // Stateless: nothing outlives the frame, so a dark frame is rest.
        isAtRest = !anyLit
        return frame
    }
}
