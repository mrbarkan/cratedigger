import Foundation

/// Light closing in from the border. Loudness sets how many rings are lit
/// from the edge inward, and each ring's brightness follows its own part of
/// the spectrum: the outer ring the bass, the middle the mids, the inner the
/// treble.
public struct FrameAnimation: MatrixAnimation {
    /// Rings 0 (the border) to 2 (the centre two rows).
    static let ringCount = 3

    public private(set) var isAtRest = true

    public init() {}

    /// A cell's distance in from the nearest edge: 0 on the border, 2 in the
    /// middle of the grid.
    public static func ring(column: Int, row: Int) -> Int {
        min(column, MatrixFrame.columns - 1 - column, row, MatrixFrame.rows - 1 - row)
    }

    /// Cool on the border, hot in the middle.
    public static func restingHeat(column: Int, row: Int) -> Double {
        Double(ring(column: column, row: row)) / Double(ringCount - 1)
    }

    public mutating func frame(for input: MatrixInput) -> MatrixFrame {
        let depth = input.loudness * Double(Self.ringCount)
        // Ring k is lit by however much of it the depth covers: whole rings
        // up to ⌊depth⌋, the innermost lit one by the fractional part. Written
        // this way, a depth that lands exactly on a ring boundary lights that
        // ring fully rather than scaling it by a fraction of zero.
        let bandsPerRing = MatrixFrame.columns / Self.ringCount
        var ringIntensity = [Double](repeating: 0, count: Self.ringCount)
        for ring in 0..<Self.ringCount {
            let coverage = min(max(depth - Double(ring), 0), 1)
            guard coverage > 0 else { continue }
            let group = input.bands[(ring * bandsPerRing)..<((ring + 1) * bandsPerRing)]
            ringIntensity[ring] = min(group.reduce(0, +) / Double(bandsPerRing) * coverage, 1)
        }

        var frame = MatrixFrame.dark
        var anyLit = false
        for row in 0..<MatrixFrame.rows {
            for column in 0..<MatrixFrame.columns {
                let ring = Self.ring(column: column, row: row)
                let intensity = ringIntensity[ring]
                guard intensity > 0 else { continue }
                frame[column: column, row: row] = MatrixCell(
                    intensity: intensity,
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
