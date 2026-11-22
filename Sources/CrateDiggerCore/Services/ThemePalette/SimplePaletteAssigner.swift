import Foundation

/// Which palette swatch does which job. `nil` means the job has no swatch of its own
/// and is derived (see `SimplePaletteAssigner.jobColors`).
public typealias JobAssignment = [ThemeJob: Int?]

/// Enumerates the sensible ways to hand a palette's colours to the six jobs, best
/// first, so the first one is the starting point and Shuffle walks the rest.
///
/// A valid assignment: honours every pin; uses as many distinct swatches as it can
/// (all of them once there are at least as many jobs as swatches); keeps Frame and
/// Panels at least `minimumFramePanelsLightness` apart in OKLCH lightness; and gives
/// Accent the most chromatic swatch, unless Accent is pinned. Only Text and Screen
/// Text may go without a swatch, and only in a two-colour palette.
///
/// Order: candidates are ranked by how far Text sits from Panels and Screen Text from
/// Glass in lightness (more readable first); ties keep the lexicographic order of the
/// index tuple (frame, panels, text, accent, glass, screenText, nil last), so the
/// list is the same on every run. When no assignment meets every rule (a palette of
/// near-identical colours, a contradictory set of pins) the rules are relaxed in turn:
/// distinctness, then the Frame/Panels gap, then the Accent rule. Pins are never
/// relaxed.
public enum SimplePaletteAssigner {
    public static let minimumFramePanelsLightness = 0.08

    public static func validAssignments(palette: [PaletteColor], pins: [ThemeJob: Int]) -> [JobAssignment] {
        let n = palette.count
        guard n > 0 else { return [] }
        let pins = pins.filter { $0.value >= 0 && $0.value < n }
        let lightness = palette.map { $0.oklch.l }
        let chroma = palette.map { $0.oklch.c }

        // Accent's swatch: the most chromatic one not pinned to another job.
        func mostChromatic(_ candidates: [Int]) -> Int? {
            candidates.max { chroma[$0] < chroma[$1] || (chroma[$0] == chroma[$1] && $0 > $1) }
        }
        let pinnedElsewhere = Set(pins.filter { $0.key != .accent }.values)
        let accentTarget = mostChromatic((0..<n).filter { !pinnedElsewhere.contains($0) })
            ?? mostChromatic(Array(0..<n))

        let jobs = ThemeJob.allCases
        let mayBeNil: Set<ThemeJob> = n == 2 ? [.text, .screenText] : []

        func choices(for job: ThemeJob) -> [Int?] {
            if let pin = pins[job] { return [pin] }
            var all: [Int?] = (0..<n).map { Optional($0) }
            if mayBeNil.contains(job) { all.append(nil) }
            return all
        }
        let perJob = jobs.map(choices(for:))

        var all: [[Int?]] = []
        var current: [Int?] = []
        func walk(_ position: Int) {
            if position == jobs.count { all.append(current); return }
            for choice in perJob[position] {
                current.append(choice)
                walk(position + 1)
                current.removeLast()
            }
        }
        walk(0)

        func filtered(distinct: Bool, separated: Bool, accent: Bool) -> [[Int?]] {
            all.filter { tuple in
                let assigned = tuple.compactMap { $0 }
                if distinct && Set(assigned).count != min(n, assigned.count) { return false }
                if separated, let f = tuple[0], let p = tuple[1],
                   abs(lightness[f] - lightness[p]) < minimumFramePanelsLightness { return false }
                if accent, pins[.accent] == nil, let a = tuple[3], let target = accentTarget,
                   a != target, chroma[a] != chroma[target] { return false }
                return true
            }
        }
        var pool: [[Int?]] = []
        for (d, s, a) in [(true, true, true), (false, true, true), (false, false, true), (false, false, false)] {
            pool = filtered(distinct: d, separated: s, accent: a)
            if !pool.isEmpty { break }
        }

        func score(_ tuple: [Int?]) -> Double {
            func gap(_ x: Int?, _ y: Int?) -> Double {
                guard let x, let y else { return 0.5 }
                return abs(lightness[x] - lightness[y])
            }
            return gap(tuple[2], tuple[1]) + gap(tuple[5], tuple[4])
        }
        // `all` is already in lexicographic order, so equal scores keep it.
        let ranked = pool.enumerated().sorted { a, b in
            let sa = score(a.element), sb = score(b.element)
            return sa != sb ? sa > sb : a.offset < b.offset
        }
        return ranked.map { entry in
            var assignment: JobAssignment = [:]
            for (job, value) in zip(jobs, entry.element) { assignment[job] = .some(value) }
            return assignment
        }
    }

    public static func initial(palette: [PaletteColor], pins: [ThemeJob: Int]) -> JobAssignment {
        validAssignments(palette: palette, pins: pins).first ?? fallback(palette: palette, pins: pins)
    }

    /// The next valid assignment after `current`, wrapping. `current` itself when it
    /// is the only one; the first when `current` is not in the list (a stale one).
    public static func shuffled(after current: JobAssignment, palette: [PaletteColor], pins: [ThemeJob: Int]) -> JobAssignment {
        let all = validAssignments(palette: palette, pins: pins)
        guard !all.isEmpty else { return current }
        let key = normalized(current)
        guard let position = all.firstIndex(where: { normalized($0) == key }) else { return all[0] }
        if all.count == 1 { return current }
        return all[(position + 1) % all.count]
    }

    /// A colour for every job. Jobs without a swatch are derived: Text and Screen Text
    /// as a tinted neutral of the Frame's / Glass's hue, lightness opposite their
    /// surface; any other job from the nearest job (in display order) that has one.
    public static func jobColors(
        palette: [PaletteColor],
        assignment: JobAssignment,
        appearance: ThemeDefinition.BaseAppearance
    ) -> [ThemeJob: PaletteColor] {
        var out: [ThemeJob: PaletteColor] = [:]
        for job in ThemeJob.allCases {
            if let entry = assignment[job], let index = entry, palette.indices.contains(index) {
                out[job] = palette[index]
            }
        }
        func neutral(hueFrom source: ThemeJob, onSurface surface: ThemeJob) -> PaletteColor? {
            guard let hueSource = out[source] ?? out[surface] ?? palette.first else { return nil }
            let surfaceL = out[surface]?.oklch.l
            let onDark = surfaceL.map { $0 < 0.5 } ?? (appearance == .dark)
            let o = hueSource.oklch
            return PaletteColor(oklch: OKLCH(l: onDark ? 0.93 : 0.2, c: min(o.c, 0.02), h: o.h))
        }
        if out[.text] == nil, let c = neutral(hueFrom: .frame, onSurface: .panels) { out[.text] = c }
        if out[.screenText] == nil, let c = neutral(hueFrom: .glass, onSurface: .glass) { out[.screenText] = c }

        let order = ThemeJob.allCases
        let assigned = order.filter { out[$0] != nil }
        if !assigned.isEmpty {
            for job in order where out[job] == nil {
                let at = order.firstIndex(of: job)!
                let nearest = assigned.min {
                    abs(order.firstIndex(of: $0)! - at) < abs(order.firstIndex(of: $1)! - at)
                }!
                out[job] = out[nearest]
            }
        }
        return out
    }

    /// Drops pins and assignments that point at a swatch that no longer exists. A
    /// dropped assignment entry reads as "derived".
    public static func sanitize(
        pins: [ThemeJob: Int],
        assignment: JobAssignment,
        paletteCount: Int
    ) -> (pins: [ThemeJob: Int], assignment: JobAssignment) {
        let keptPins = pins.filter { $0.value >= 0 && $0.value < paletteCount }
        var kept: JobAssignment = [:]
        for (job, entry) in assignment {
            if let index = entry {
                if index >= 0 && index < paletteCount { kept[job] = .some(index) }
            } else {
                kept[job] = .some(nil)
            }
        }
        return (keptPins, kept)
    }

    // MARK: -

    /// All six jobs, -1 for a missing or derived one, so two assignments compare by meaning.
    private static func normalized(_ assignment: JobAssignment) -> [Int] {
        ThemeJob.allCases.map { job in
            if let entry = assignment[job], let index = entry { return index }
            return -1
        }
    }

    private static func fallback(palette: [PaletteColor], pins: [ThemeJob: Int]) -> JobAssignment {
        var out: JobAssignment = [:]
        for job in ThemeJob.allCases {
            out[job] = .some(pins[job] ?? (palette.isEmpty ? nil : 0))
        }
        return out
    }
}
