import Foundation

/// Turns an existing theme into a Simple recipe, so Simple can open any theme.
///
/// Reads the six anchor tokens (frame `chassis`, panels `paper`, text `ink`, accent
/// `orange`, glass `oledSurface`, screen text `oledForeground`) from the theme's
/// primary layer, the one for its own `baseAppearance`, falling back to
/// `resolvedBase` for a token the theme does not set. Colours closer than
/// `mergeDistance` in OKLab become one swatch, and every job pins to its colour, so
/// the theme reads back as it was.
///
/// An adaptive theme (one that has the other appearance's layer too) also brings that
/// layer's colours: each one not within `mergeDistance` of an existing swatch is
/// appended, unpinned, while the palette has fewer than six swatches.
public enum SimplePaletteExtractor {
    public static let mergeDistance = 0.03

    static let anchorTokens: [ThemeJob: String] = [
        .frame: "chassis", .panels: "paper", .text: "ink",
        .accent: "orange", .glass: "oledSurface", .screenText: "oledForeground"
    ]

    public static func recipe(from definition: ThemeDefinition, resolvedBase: [String: String]) -> SimpleThemeRecipe {
        let primary = definition.baseAppearance
        let other: ThemeDefinition.BaseAppearance = primary == .dark ? .light : .dark
        let fallbackColor = PaletteColor(hex: primary == .dark ? "#171C22" : "#F5F8FA")!

        func jobColors(_ appearance: ThemeDefinition.BaseAppearance) -> [ThemeJob: PaletteColor] {
            let tokens = definition.resolved(for: appearance).colors ?? [:]
            var out: [ThemeJob: PaletteColor] = [:]
            for job in ThemeJob.allCases {
                let key = anchorTokens[job]!
                let color = tokens[key].flatMap(PaletteColor.init(hex:))
                    ?? resolvedBase[key].flatMap(PaletteColor.init(hex:))
                    ?? fallbackColor
                out[job] = PaletteColor(r: color.r, g: color.g, b: color.b)
            }
            return out
        }
        let jobColor = jobColors(primary)

        // Merge near-duplicates in job order; each swatch counts its jobs.
        var swatches: [PaletteColor] = []
        var uses: [Int] = []
        var swatchOf: [ThemeJob: Int] = [:]
        for job in ThemeJob.allCases {
            let color = jobColor[job]!
            if let found = swatches.firstIndex(where: { $0.distance(to: color) < mergeDistance }) {
                uses[found] += 1
                swatchOf[job] = found
            } else {
                swatches.append(color)
                uses.append(1)
                swatchOf[job] = swatches.count - 1
            }
        }
        let pinnedSwatches = Set(swatchOf.values)

        // The other layer's colours, as unpinned extras while there is room.
        if definition.variant(for: other) != nil {
            let otherColors = jobColors(other)
            for job in ThemeJob.allCases where swatches.count < SimpleThemeRecipe.maxPaletteCount {
                let color = otherColors[job]!
                if !swatches.contains(where: { $0.distance(to: color) < mergeDistance }) {
                    swatches.append(color)
                    uses.append(0)
                }
            }
        }

        let keep = keptSwatches(uses: uses, pinned: pinnedSwatches, limit: SimpleThemeRecipe.maxPaletteCount)
        let newIndex = Dictionary(uniqueKeysWithValues: keep.enumerated().map { ($1, $0) })

        var pins: [ThemeJob: Int] = [:]
        for job in ThemeJob.allCases {
            if let mapped = newIndex[swatchOf[job]!] {
                pins[job] = mapped
            } else {
                let color = jobColor[job]!
                let nearest = keep.min { swatches[$0].distance(to: color) < swatches[$1].distance(to: color) }!
                pins[job] = newIndex[nearest]!
            }
        }

        // A palette needs two swatches; a theme whose anchors are all one colour gets
        // a second so the editor has something to work with.
        var palette = keep.map { swatches[$0].hex }
        if palette.count < SimpleThemeRecipe.minPaletteCount {
            let base = swatches[keep[0]].oklch
            let extra = PaletteColor(oklch: OKLCH(l: base.l < 0.5 ? base.l + 0.4 : base.l - 0.4, c: base.c, h: base.h))
            palette.append(extra.hex)
        }

        var assignment: [ThemeJob: Int?] = [:]
        for (job, index) in pins { assignment[job] = .some(index) }
        return SimpleThemeRecipe(
            palette: palette,
            pins: pins,
            assignment: assignment,
            contrast: .standard,
            recipe: SimplePaletteRecipe.currentVersion
        )
    }

    /// Which swatches survive when there are more than `limit`: unpinned ones go first
    /// (least used, later first), a pinned one only when nothing unpinned is left.
    /// First-seen order is kept. The loop is a guard today (at most six jobs pin, and
    /// extras stop at six), but it is correct for any count.
    static func keptSwatches(uses: [Int], pinned: Set<Int>, limit: Int) -> [Int] {
        var keep = Array(uses.indices)
        while keep.count > limit {
            let drop = keep.enumerated().min { a, b in
                let pa = pinned.contains(a.element), pb = pinned.contains(b.element)
                if pa != pb { return !pa }
                return uses[a.element] != uses[b.element] ? uses[a.element] < uses[b.element] : a.element > b.element
            }!
            keep.remove(at: drop.offset)
        }
        return keep
    }
}
