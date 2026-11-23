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

    /// How far `separated(_:onAll:)` may mix toward white or black: further than the
    /// one-surface limit, since a key may need to travel past one surface to clear another.
    private static let multiSurfaceLimit = 0.50

    /// `fill` moved just far enough to stand apart from every surface in `surfaces`,
    /// for a fill (a key) that can sit on several (the case, a well, the paper).
    ///
    /// `fill` itself when it already clears them all, or when there are none. Otherwise
    /// both directions are tried in steps of 0.02 up to 0.50, and the smallest mix that
    /// clears every surface wins; at equal mix, the direction away from the surface
    /// nearest the fill in luminance. If no mix clears them all, the candidate whose
    /// lowest contrast against any surface is highest.
    public static func separated(_ fill: PaletteColor, onAll surfaces: [PaletteColor]) -> PaletteColor {
        func worst(_ color: PaletteColor) -> Double {
            surfaces.map { PaletteColor.contrast(color, $0) }.min() ?? .infinity
        }
        guard !surfaces.isEmpty, worst(fill) < minimumContrast else { return fill }

        let fillLuminance = fill.relativeLuminance
        let nearest = surfaces.min {
            abs($0.relativeLuminance - fillLuminance) < abs($1.relativeLuminance - fillLuminance)
        }!
        // Away from the nearest surface first, so it wins a tie at the same mix.
        let preferWhite = fillLuminance >= nearest.relativeLuminance
        let ends: [Double] = preferWhite ? [1, 0] : [0, 1]

        var best = fill
        var bestWorst = worst(fill)
        let steps = Int((multiSurfaceLimit / step).rounded())
        for k in 1...steps {
            let amount = Double(k) * step
            for end in ends {
                let candidate = PaletteColor(r: fill.r + (end - fill.r) * amount,
                                             g: fill.g + (end - fill.g) * amount,
                                             b: fill.b + (end - fill.b) * amount,
                                             a: fill.a)
                let candidateWorst = worst(candidate)
                if candidateWorst >= minimumContrast { return candidate }
                if candidateWorst > bestWorst {
                    best = candidate
                    bestWorst = candidateWorst
                }
            }
        }
        return best
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
