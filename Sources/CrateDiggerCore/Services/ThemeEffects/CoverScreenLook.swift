import Foundation

/// How the cover is shown on the compact and mini players' screen. The value
/// stored under `effectKey` is the grid strength.
public enum CoverScreenLook: String, CaseIterable, Sendable {
    case grid, pixel, handheld

    public var effectKey: String {
        switch self {
        case .grid: return "coverGrid"
        case .pixel: return "coverPixel"
        case .handheld: return "coverHandheld"
        }
    }

    /// First non-zero of handheld, pixel, grid; values at or below 0 are off.
    public static func resolve(effects: [String: Double]) -> (look: CoverScreenLook, strength: Double)? {
        let priority: [CoverScreenLook] = [.handheld, .pixel, .grid]
        for look in priority {
            if let value = effects[look.effectKey], value > 0 {
                return (look, value)
            }
        }
        return nil
    }

    public static let pixelSizes: [Double] = [1.5, 2, 3, 4]
    public static let defaultPixelSize: Double = 1.5

    /// Snaps a raw `coverPixelSize` to the nearest of 1.5, 2, 3, 4 points.
    /// nil, NaN or a value at or below 0 gives the default, 1.5. Ties go to the
    /// smaller size.
    public static func pixelSize(from raw: Double?) -> Double {
        guard let raw, raw.isFinite, raw > 0 else { return defaultPixelSize }
        var best = pixelSizes[0]
        for size in pixelSizes where abs(size - raw) < abs(best - raw) {
            best = size
        }
        return best
    }
}
