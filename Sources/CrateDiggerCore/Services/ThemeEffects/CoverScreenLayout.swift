import Foundation

/// The geometry of the cover screen, in whole device pixels, so the LCD grid
/// can never land between them.
public struct CoverScreenLayout: Equatable, Sendable {
    /// Device pixels per LCD pixel, at least 3.
    public let cell: Int
    /// LCD pixels across (and down). 0 when the side is too small for a screen.
    public let count: Int
    /// `cell * count`, in device pixels.
    public let lcdSide: Int
    /// The bezel band on the top and left, in device pixels. The bottom and
    /// right get one more when an odd pixel is left over.
    public let band: Int

    public static let minimumCount = 8

    public init(cell: Int, count: Int, lcdSide: Int, band: Int) {
        self.cell = cell
        self.count = count
        self.lcdSide = lcdSide
        self.band = band
    }

    /// - Parameters:
    ///   - side: the well's side in points.
    ///   - scale: the screen's backing scale.
    ///   - pixelSize: points per LCD pixel (already snapped).
    ///   - minimumBand: the thinnest bezel band, in points.
    public static func plan(side: Double, scale: Double, pixelSize: Double,
                            minimumBand: Double = 6) -> CoverScreenLayout {
        let safeScale = (scale.isFinite && scale > 0) ? scale : 1
        let rawCell = (pixelSize * safeScale).rounded()
        let cell = rawCell.isFinite ? max(3, Int(rawCell)) : 3
        guard side.isFinite, side > 0 else {
            return CoverScreenLayout(cell: cell, count: 0, lcdSide: 0, band: 0)
        }
        let wellPixels = Int((side * safeScale).rounded())
        let minBandPixels = Int((max(0, minimumBand) * safeScale).rounded())
        let available = wellPixels - 2 * minBandPixels
        let count = available > 0 ? available / cell : 0
        guard count >= minimumCount else {
            return CoverScreenLayout(cell: cell, count: 0, lcdSide: 0, band: 0)
        }
        let lcdSide = cell * count
        let band = (wellPixels - lcdSide) / 2
        return CoverScreenLayout(cell: cell, count: count, lcdSide: lcdSide, band: band)
    }

    /// The offset in points that moves an origin onto the device pixel grid.
    public static func pixelSnap(origin: Double, scale: Double) -> Double {
        guard scale.isFinite, scale > 0, origin.isFinite else { return 0 }
        let device = origin * scale
        return (device.rounded() - device) / scale
    }
}
