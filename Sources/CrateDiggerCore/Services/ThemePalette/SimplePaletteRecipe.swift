import Foundation

/// Simple mode's recipe: six job colours in, every colour token Simple owns out.
///
/// Each token follows one job through a transform measured from Carbon's own tokens
/// (`SimplePaletteRecipeTable`), so Carbon's job colours give back Carbon, and any
/// other palette is dressed the way Carbon dresses its own. Then `ContrastFloors`
/// makes sure everything reads.
///
/// Never written: the optional overrides (`lamp…`, `transportLamp`, `keyLamp`,
/// `meterHot`, `chassisInk`, `columnHeaderInk`) and the selection's light
/// (`selectionGlow`, `selectionSpread`). Left unset they keep following what they
/// follow in every shipped theme.
public enum SimplePaletteRecipe {
    public static let currentVersion = 1

    /// Exactly the keys `tokens(...)` returns, whatever the input.
    public static let simpleWrittenTokens: Set<String> = Set(SimplePaletteRecipeTable.dark.tokens.keys)

    /// The minimum OKLab distance kept between the frame and the panels, so they read
    /// as two surfaces even from a palette of near-identical colours. (Carbon's own
    /// pair sits at 0.019 dark and 0.013 light, relying on bevels; a generated theme
    /// cannot count on the palette to supply the difference.)
    static let frameToPanelsSeparation = 0.04

    /// `jobColors` should hold all six jobs; a missing one takes Carbon's colour for
    /// that job in `appearance`. Alpha in a job colour is ignored.
    public static func tokens(
        jobColors: [ThemeJob: PaletteColor],
        contrast: SimpleContrast,
        appearance: ThemeDefinition.BaseAppearance
    ) -> [String: String] {
        let table = appearance == .dark ? SimplePaletteRecipeTable.dark : SimplePaletteRecipeTable.light

        // A pale glass (an LCD rather than an OLED) brings its own screen tokens and
        // flips the screen text dark, in either appearance.
        let paleGlass = (jobColors[.glass]?.oklch.l ?? 0) >= 0.5
        var ranges = table.ranges
        if paleGlass {
            ranges[.glass] = SimplePaletteRecipeTable.paleGlassRange
            ranges[.screenText] = SimplePaletteRecipeTable.paleScreenTextRange
        }

        var bases: [ThemeJob: JobBase] = [:]
        for job in ThemeJob.allCases {
            let range = ranges[job]!
            bases[job] = JobBase.place(jobColors[job].map(\.opaque) ?? range.fallback, in: range)
        }
        var frame = bases[.frame]!, panels = bases[.panels]!
        separate(frame: &frame, panels: &panels, panelsSide: table.panelsSide)
        bases[.frame] = frame
        bases[.panels] = panels

        let context = Context(bases: bases, ranges: ranges, contrast: contrast)
        var out: [String: String] = [:]
        for (key, transform) in table.tokens {
            out[key] = transform.hex(in: context)
        }
        if paleGlass {
            for (key, transform) in SimplePaletteRecipeTable.paleGlassTokens {
                out[key] = transform.hex(in: context)
            }
        }
        return ContrastFloors.enforce(out, contrast: contrast)
    }

    /// Pushes the frame and the panels apart along lightness until they are
    /// `frameToPanelsSeparation` apart, splitting the move between them. They part in
    /// the order they already have; a tie takes the table's (panels darker than the
    /// frame in dark, lighter in light).
    static func separate(frame: inout JobBase, panels: inout JobBase, panelsSide: Double) {
        // Measured on the colours as they will be written (8-bit hex), with a hair
        // of headroom, so rounding cannot take a pair back under the minimum.
        let target = frameToPanelsSeparation + 0.0005
        func written(_ base: JobBase) -> PaletteColor { PaletteColor(hex: base.color.hex) ?? base.color }
        func gap() -> Double { written(frame).distance(to: written(panels)) }
        guard gap() < target else { return }

        let deltaL = panels.lch.l - frame.lch.l
        let side = abs(deltaL) > 0.002 ? (deltaL > 0 ? 1.0 : -1.0) : panelsSide
        // Only lightness moves, so the hue/chroma part of the gap stays as it is.
        let current = frame.color.distance(to: panels.color)
        let chromaPart = max(current * current - deltaL * deltaL, 0)
        let neededL = max(target * target - chromaPart, 0).squareRoot()
        let extra = max(neededL - abs(deltaL), 0)

        // Half each; whichever runs into 0 or 1 hands the rest to the other.
        let panelsRoom = side > 0 ? 1 - panels.lch.l : panels.lch.l
        let frameRoom = side > 0 ? frame.lch.l : 1 - frame.lch.l
        var panelsMove = min(extra / 2, panelsRoom)
        let frameMove = min(extra - panelsMove, frameRoom)
        panelsMove = min(extra - frameMove, panelsRoom)
        panels.setLightness(clamp(panels.lch.l + side * panelsMove))
        frame.setLightness(clamp(frame.lch.l - side * frameMove))

        // Gamut clipping and rounding can leave it a hair short: step on, frame first.
        var steps = 0
        while gap() < target, steps < 200 {
            steps += 1
            let frameL = clamp(frame.lch.l - side * 0.001)
            if frameL != frame.lch.l {
                frame.setLightness(frameL)
            } else {
                let panelsL = clamp(panels.lch.l + side * 0.001)
                guard panelsL != panels.lch.l else { break }
                panels.setLightness(panelsL)
            }
        }
    }

    static func clamp(_ l: Double) -> Double { min(max(l, 0), 1) }
}

// MARK: - Transforms

/// The lightness band a job colour may take in one appearance. A colour inside it is
/// used exactly; outside it keeps its hue and chroma at `reference` (Carbon's own
/// lightness for that job), so a cream panel is the panel in Light and a deep
/// cream-tinted panel in Dark.
struct JobRange: Sendable {
    let range: ClosedRange<Double>
    let reference: Double
    /// Carbon's colour for the job, for a palette that left it out.
    let fallback: PaletteColor

    init(_ range: ClosedRange<Double>, reference: Double, fallback: String) {
        self.range = range
        self.reference = reference
        self.fallback = PaletteColor(hex: fallback)!
    }
}

/// A job's colour once placed in its band.
struct JobBase: Sendable {
    private(set) var lch: OKLCH
    /// Set while the base is the job colour unchanged, so its anchor token is written
    /// as the very hex it came in as, with no OKLCH round trip.
    private(set) var exact: PaletteColor?

    var color: PaletteColor { exact ?? PaletteColor(oklch: lch) }

    static func place(_ color: PaletteColor, in band: JobRange) -> JobBase {
        var lch = color.oklch
        if band.range.contains(lch.l) {
            return JobBase(lch: lch, exact: color)
        }
        lch.l = band.reference
        return JobBase(lch: lch, exact: nil)
    }

    mutating func setLightness(_ l: Double) {
        lch.l = l
        exact = nil
    }
}

struct Context {
    let bases: [ThemeJob: JobBase]
    let ranges: [ThemeJob: JobRange]
    let contrast: SimpleContrast

    /// How far the secondary inks sit from the primary one: `high` pulls them in,
    /// `soft` lets them recede. `standard` is Carbon's spacing.
    var hierarchyScale: Double {
        switch contrast {
        case .soft: return 1.15
        case .standard: return 1
        case .high: return 0.8
        }
    }
}

/// How one token is made.
enum TokenTransform: Sendable {
    /// From a job's colour: lightness offset from the job, chroma scaled (growth
    /// capped at `maxChromaGain` over the job, so a vivid job does not turn its
    /// highlights garish), hue shifted, alpha set. `hierarchy` marks the secondary
    /// inks, whose offset follows the contrast level.
    case derived(ThemeJob, dL: Double, chroma: Double, hue: Double = 0, alpha: Double = 1, hierarchy: Bool = false)
    /// A meaning colour (alert red, amber, teal, info blue): Carbon's own hue and
    /// chroma, never the palette's. Its lightness starts at Carbon's and moves by
    /// `follow` times however far the background job sits from Carbon's.
    case meaning(l: Double, c: Double, h: Double, on: ThemeJob, follow: Double)
    /// The same value whatever the palette.
    case constant(String)

    static let maxChromaGain = 0.012

    func hex(in context: Context) -> String {
        switch self {
        case let .derived(job, dL, chroma, hue, alpha, hierarchy):
            let base = context.bases[job]!
            if dL == 0, chroma == 1, hue == 0, alpha == 1, let exact = base.exact {
                return exact.hex
            }
            let offset = hierarchy ? dL * context.hierarchyScale : dL
            var c = base.lch.c * chroma
            if chroma > 1 { c = min(c, base.lch.c + Self.maxChromaGain) }
            let lch = OKLCH(l: SimplePaletteRecipe.clamp(base.lch.l + offset), c: c,
                            h: PaletteColor.normalizedHue(base.lch.h + hue))
            return PaletteColor(oklch: lch, alpha: alpha).hex

        case let .meaning(l, c, h, job, follow):
            let background = context.bases[job]!.lch.l
            let reference = context.ranges[job]!.reference
            let lightness = min(max(l + follow * (background - reference), 0.05), 0.97)
            return PaletteColor(oklch: OKLCH(l: lightness, c: c, h: h)).hex

        case let .constant(hex):
            return hex
        }
    }
}

private extension PaletteColor {
    var opaque: PaletteColor { PaletteColor(r: r, g: g, b: b) }
}
