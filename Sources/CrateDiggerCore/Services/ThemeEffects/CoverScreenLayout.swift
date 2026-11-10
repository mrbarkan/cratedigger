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

    /// The largest well, in device pixels, that gets a screen. Far past any
    /// real one (the players' wells are about 500); it bounds the `Int`
    /// conversions in `plan`, which trap on a huge finite value, and the
    /// renderer's buffer, which grows with its square.
    public static let maximumPixels = 1 << 14

    public init(cell: Int, count: Int, lcdSide: Int, band: Int) {
        self.cell = cell
        self.count = count
        self.lcdSide = lcdSide
        self.band = band
    }

    /// Total: any input, NaN and infinities included, gives a layout, at
    /// worst one with no screen (`count == 0`).
    ///
    /// - Parameters:
    ///   - side: the well's side in points.
    ///   - scale: the screen's backing scale. Not a positive number: 1.
    ///   - pixelSize: points per LCD pixel (already snapped). Not a finite
    ///     number: the smallest cell.
    ///   - minimumBand: the thinnest bezel band, in points.
    public static func plan(side: Double, scale: Double, pixelSize: Double,
                            minimumBand: Double = 6) -> CoverScreenLayout {
        let safeScale = (scale.isFinite && scale > 0) ? scale : 1
        let cell = pixelSize.isFinite ? max(3, devicePixels(pixelSize * safeScale) ?? 3) : 3
        let noScreen = CoverScreenLayout(cell: cell, count: 0, lcdSide: 0, band: 0)
        guard side.isFinite, side > 0, side * safeScale <= Double(maximumPixels),
              let wellPixels = devicePixels(side * safeScale) else { return noScreen }
        let minBandPixels = devicePixels(minimumBand * safeScale) ?? 0
        let available = wellPixels - 2 * minBandPixels
        let count = available > 0 ? available / cell : 0
        guard count >= minimumCount else { return noScreen }
        let lcdSide = cell * count
        let band = (wellPixels - lcdSide) / 2
        return CoverScreenLayout(cell: cell, count: count, lcdSide: lcdSide, band: band)
    }

    /// `value` rounded to whole device pixels and clamped to
    /// `0...maximumPixels`, so the `Int` conversion can never trap; nil for
    /// NaN.
    private static func devicePixels(_ value: Double) -> Int? {
        guard !value.isNaN else { return nil }
        return Int(min(max(value.rounded(), 0), Double(maximumPixels)))
    }

    /// The offset in points that moves an origin onto the device pixel grid.
    public static func pixelSnap(origin: Double, scale: Double) -> Double {
        guard scale.isFinite, scale > 0, origin.isFinite else { return 0 }
        let device = origin * scale
        return (device.rounded() - device) / scale
    }
}
