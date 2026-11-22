import Foundation

/// Turns an existing theme into a Simple recipe, so Simple can open any theme.
///
/// Reads the six anchor tokens (frame `chassis`, panels `paper`, text `ink`, accent
/// `orange`, glass `oledSurface`, screen text `oledForeground`) from the theme's own
/// appearance layer (dark if it has one, else light, else the shared colours), falling
/// back to `resolvedBase` for a token the theme does not set. Colours closer than
/// `mergeDistance` in OKLab become one swatch; past six swatches the least-used go
/// (ties drop the later one) and their jobs pin to the nearest survivor. Every job
/// ends up pinned, so the theme reads back as it was.
public enum SimplePaletteExtractor {
    public static let mergeDistance = 0.03

    static let anchorTokens: [ThemeJob: String] = [
        .frame: "chassis", .panels: "paper", .text: "ink",
        .accent: "orange", .glass: "oledSurface", .screenText: "oledForeground"
    ]

    public static func recipe(from definition: ThemeDefinition, resolvedBase: [String: String]) -> SimpleThemeRecipe {
        let appearance: ThemeDefinition.BaseAppearance =
            definition.dark != nil ? .dark : (definition.light != nil ? .light : definition.baseAppearance)
        let tokens = definition.resolved(for: appearance).colors ?? [:]

        var jobColor: [ThemeJob: PaletteColor] = [:]
        for job in ThemeJob.allCases {
            let key = anchorTokens[job]!
            let color = tokens[key].flatMap(PaletteColor.init(hex:))
                ?? resolvedBase[key].flatMap(PaletteColor.init(hex:))
                ?? PaletteColor(hex: appearance == .dark ? "#171C22" : "#F5F8FA")!
            jobColor[job] = PaletteColor(r: color.r, g: color.g, b: color.b)
        }

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

        // Keep the six most used (ties keep the earlier), preserving first-seen order.
        var keep = Array(swatches.indices)
        while keep.count > SimpleThemeRecipe.maxPaletteCount {
            let drop = keep.enumerated().min { a, b in
                uses[a.element] != uses[b.element] ? uses[a.element] < uses[b.element] : a.element > b.element
            }!
            keep.remove(at: drop.offset)
        }
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

        // A palette needs two swatches; a theme whose six anchors are one colour gets
        // a second so the editor has something to work with.
        var palette = keep.map { swatches[$0].hex }
        if palette.count < SimpleThemeRecipe.minPaletteCount {
            let base = swatches[keep[0]].oklch
            let other = PaletteColor(oklch: OKLCH(l: base.l < 0.5 ? base.l + 0.4 : base.l - 0.4, c: base.c, h: base.h))
            palette.append(other.hex)
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
}
