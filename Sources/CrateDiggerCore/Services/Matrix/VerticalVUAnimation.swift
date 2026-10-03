import Foundation

/// The spectrum in stereo halves: the left half of the matrix is the left
/// channel and the right half the right, mirrored so the bass sits on the
/// outer edges and the treble meets in the middle. Each column rises from the
/// bottom with its top segment as the peak.
///
/// The spectrum is measured once, on a mono mix, so the halves share one
/// shape: the 12 bands fold into 6 (each column showing the louder of its
/// pair), and each half is scaled by its channel's loudness against the
/// louder channel. Centred music draws symmetrically and a hard-panned part
/// tips the picture to its side. A true per-channel spectrum would need a
/// second FFT on the audio thread and new plumbing through every tap.
public struct VerticalVUAnimation: MatrixAnimation {
    /// The segments under the peak, a step dimmer so the peak reads as a cap.
    static let bodyIntensity = 0.75
    /// Columns per channel.
    static let halfWidth = MatrixFrame.columns / 2

    public private(set) var isAtRest = true

    public init() {}

    /// Cool at the bottom, hot at the top, like the red top segments of a
    /// hardware meter.
    public static func restingHeat(column: Int, row: Int) -> Double {
        Double(row) / Double(MatrixFrame.rows - 1)
    }

    /// Which of the six folded bands a column shows: 0 (bass) on both outer
    /// edges, 5 (treble) on both sides of the middle.
    static func band(forColumn column: Int) -> Int {
        column < halfWidth ? column : MatrixFrame.columns - 1 - column
    }

    /// Each channel's share of the louder one, so the louder side always
    /// draws the full spectrum. With no level to go on (a tap that measures
    /// bands but not levels yet) both sides draw it, rather than neither.
    static func channelWeights(left: Double, right: Double) -> (left: Double, right: Double) {
        let louder = max(left, right)
        guard louder > 0 else { return (1, 1) }
        return (left / louder, right / louder)
    }

    public mutating func frame(for input: MatrixInput) -> MatrixFrame {
        let folded = (0..<Self.halfWidth).map { max(input.bands[2 * $0], input.bands[2 * $0 + 1]) }
        let weights = Self.channelWeights(left: input.left, right: input.right)

        var frame = MatrixFrame.dark
        var anyLit = false
        for column in 0..<MatrixFrame.columns {
            let weight = column < Self.halfWidth ? weights.left : weights.right
            let level = folded[Self.band(forColumn: column)] * weight
            let lit = min(max(Int((level * Double(MatrixFrame.rows)).rounded()), 0), MatrixFrame.rows)
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
