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
    /// black if not, in steps of 0.02 up to 0.30, until the contrast reaches the minimum
    /// (the last step if it never does).
    public static func separated(_ fill: PaletteColor, on surface: PaletteColor) -> PaletteColor {
        guard PaletteColor.contrast(fill, surface) < minimumContrast else { return fill }
        let target = fill.relativeLuminance >= surface.relativeLuminance
            ? PaletteColor(r: 1, g: 1, b: 1, a: fill.a)
            : PaletteColor(r: 0, g: 0, b: 0, a: fill.a)
        var result = fill
        var amount = step
        while amount <= limit + 1e-9 {
            result = PaletteColor(r: fill.r + (target.r - fill.r) * amount,
                                  g: fill.g + (target.g - fill.g) * amount,
                                  b: fill.b + (target.b - fill.b) * amount,
                                  a: fill.a)
            if PaletteColor.contrast(result, surface) >= minimumContrast { break }
            amount += step
        }
        return result
    }
}
