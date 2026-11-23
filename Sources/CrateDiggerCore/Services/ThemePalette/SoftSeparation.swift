import Foundation

/// Soft Blocks draws keys and wells without bevels or shadows, so a fill that is
/// nearly the colour of the surface under it would vanish. `separated` nudges such a
/// fill apart, once per theme change (never while drawing).
public enum SoftSeparation {
    /// WCAG contrast ratio a fill keeps against its surface.
    public static let minimumContrast: Double = 1.12

    private static let step = 0.02
    private static let limit = 0.30

    /// `fill` itself when it already stands apart from `surface`. Otherwise `fill` moved
    /// away from the surface, toward white if it is the lighter of the two and toward
    /// black if not, in steps of 0.02 up to 0.30, until the contrast reaches the minimum.
    /// When that direction has no room (a near-white fill on a near-white surface), the
    /// other direction is tried the same way; if neither reaches the minimum, the one
    /// with the higher contrast is returned.
    public static func separated(_ fill: PaletteColor, on surface: PaletteColor) -> PaletteColor {
        guard PaletteColor.contrast(fill, surface) < minimumContrast else { return fill }
        let towardWhite = fill.relativeLuminance >= surface.relativeLuminance
        let first = push(fill, on: surface, towardWhite: towardWhite)
        let firstContrast = PaletteColor.contrast(first, surface)
        if firstContrast >= minimumContrast { return first }
        let second = push(fill, on: surface, towardWhite: !towardWhite)
        return PaletteColor.contrast(second, surface) > firstContrast ? second : first
    }

    private static func push(_ fill: PaletteColor, on surface: PaletteColor, towardWhite: Bool) -> PaletteColor {
        let end: Double = towardWhite ? 1 : 0
        var result = fill
        var amount = step
        while amount <= limit + 1e-9 {
            result = PaletteColor(r: fill.r + (end - fill.r) * amount,
                                  g: fill.g + (end - fill.g) * amount,
                                  b: fill.b + (end - fill.b) * amount,
                                  a: fill.a)
            if PaletteColor.contrast(result, surface) >= minimumContrast { break }
            amount += step
        }
        return result
    }
}
