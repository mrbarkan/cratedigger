import Foundation

/// The legibility floors every Simple theme keeps (WCAG 2 contrast ratios), and the
/// one way they are enforced: move the foreground's OKLCH lightness away from the
/// background, and only when the foreground has run out of room (L at 0 or 1), move
/// the background the other way. Hue, chroma and alpha are never touched.
public enum ContrastFloors {
    /// Foregrounds that are optional overrides in `CarbonTheme`. Simple never writes
    /// them, so while one is unset the token it follows is the one that has to read.
    static let fallbacks: [String: String] = [
        "columnHeaderInk": "ink3",
        "chassisInk": "ink2",
    ]

    /// Every pair, in the order `enforce` settles them. Primary ink comes first so a
    /// panel that has to give way does so before the quieter inks are measured on it.
    ///
    /// `selectionInk` is measured on `paper`. A selected row (`CarbonSelectionSlot`)
    /// is lit by `selectionSpread` at 90% (dark) or 85% (light) at its leading edge
    /// and fades to clear across the row, so the text runs out onto the panel itself.
    /// Simple never writes `selectionSpread` (it stays with the theme it inherits),
    /// which leaves the panel as the one part of that fill the recipe controls.
    public static func pairs(contrast: SimpleContrast) -> [(foreground: String, background: String, minimum: Double)] {
        let ink: Double
        switch contrast {
        case .soft: ink = 4.5
        case .standard: ink = 7
        case .high: ink = 10
        }
        return [
            ("ink", "paper", ink),
            ("ink", "well", ink),
            ("ink2", "paper", 4.5),
            ("ink3", "paper", 3),
            ("columnHeaderInk", "paper", 3),
            ("chassisInk", "metal", 4.5),
            ("chassisInk", "chassis", 4.5),
            ("oledForeground", "oledSurface", 7),
            ("oledForegroundMuted", "oledSurface", 3),
            ("selectionInk", "paper", 4.5),
        ]
    }

    /// The key that actually draws `foreground` in `tokens`: the token itself when set,
    /// else the token an unset override follows. `nil` when neither is there.
    static func foregroundKey(_ foreground: String, in tokens: [String: String]) -> String? {
        if tokens[foreground] != nil { return foreground }
        if let fallback = fallbacks[foreground], tokens[fallback] != nil { return fallback }
        return nil
    }

    /// `tokens` with every floor holding. A pair whose tokens are missing or not valid
    /// hex is skipped. Tokens no pair touches come back unchanged, byte for byte.
    public static func enforce(_ tokens: [String: String], contrast: SimpleContrast) -> [String: String] {
        var out = tokens
        let floors = pairs(contrast: contrast)
        // Moving a background can unsettle a pair already passed; a few sweeps settle
        // it, because every move only ever widens the gap it was made for.
        for _ in 0..<6 {
            var changed = false
            for pair in floors {
                guard let fgKey = foregroundKey(pair.foreground, in: out),
                      let fg = out[fgKey].flatMap(PaletteColor.init(hex:)),
                      let bg = out[pair.background].flatMap(PaletteColor.init(hex:)),
                      PaletteColor.contrast(fg, bg) < pair.minimum else { continue }
                let fixed = settle(foreground: fg, background: bg, minimum: pair.minimum)
                out[fgKey] = fixed.foreground.hex
                out[pair.background] = fixed.background.hex
                changed = true
            }
            if !changed { break }
        }
        return out
    }

    // MARK: Internals

    /// Aim a little past the floor so rounding to 8-bit hex cannot drop back under it.
    private static let margin = 0.02

    private static func settle(foreground: PaletteColor, background: PaletteColor,
                               minimum: Double) -> (foreground: PaletteColor, background: PaletteColor) {
        let fgL = foreground.oklch.l, bgL = background.oklch.l
        // Away from the background; a tie goes toward whichever end has more room.
        let direction: Double = fgL > bgL ? 1 : fgL < bgL ? -1 : (bgL < 0.5 ? 1 : -1)
        let target = minimum + margin

        if let fixed = move(foreground, direction: direction,
                            until: { PaletteColor.contrast($0, background) >= target },
                            floor: { PaletteColor.contrast($0, background) >= minimum }) {
            return (fixed, background)
        }
        // The foreground is out of room: pin it at its limit and push the background.
        let pinned = moved(foreground, toL: direction > 0 ? 1 : 0)
        let pushed = move(background, direction: -direction,
                          until: { PaletteColor.contrast(pinned, $0) >= target },
                          floor: { PaletteColor.contrast(pinned, $0) >= minimum })
        return (pinned, pushed ?? moved(background, toL: direction > 0 ? 0 : 1))
    }

    /// The smallest lightness move of `color` in `direction` that satisfies `until`,
    /// checked again after rounding to hex against `floor`. `nil` when even the end of
    /// the range does not reach it.
    private static func move(_ color: PaletteColor, direction: Double,
                             until reaches: (PaletteColor) -> Bool,
                             floor holds: (PaletteColor) -> Bool) -> PaletteColor? {
        let start = color.oklch.l
        let limit: Double = direction > 0 ? 1 : 0
        guard reaches(moved(color, toL: limit)) else {
            let end = rounded(moved(color, toL: limit))
            return holds(end) ? end : nil
        }
        var near = start, far = limit
        for _ in 0..<40 {
            let mid = (near + far) / 2
            if reaches(moved(color, toL: mid)) { far = mid } else { near = mid }
        }
        // Rounding to 8 bits can land a hair short; step on until the hex holds.
        var l = far
        while true {
            let candidate = rounded(moved(color, toL: l))
            if holds(candidate) { return candidate }
            if l == limit { return nil }
            l = direction > 0 ? min(l + 0.002, 1) : max(l - 0.002, 0)
        }
    }

    private static func moved(_ color: PaletteColor, toL l: Double) -> PaletteColor {
        var lch = color.oklch
        lch.l = l
        return PaletteColor(oklch: lch, alpha: color.a)
    }

    /// The colour as it will be written, so every check measures what ships.
    private static func rounded(_ color: PaletteColor) -> PaletteColor {
        PaletteColor(hex: color.hex) ?? color
    }
}
