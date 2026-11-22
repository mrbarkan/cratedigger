import Foundation

/// Everything the Simple editor edits about colour, as one value: the palette, the
/// pins, the current assignment and the contrast level. One history step is one of these.
///
/// Mutators keep it valid: no pin or assignment ever points outside the palette, and the
/// assignment always honours the pins.
public struct SimpleThemeState: Equatable, Sendable {
    public private(set) var palette: [String]
    public private(set) var pins: [ThemeJob: Int]
    public private(set) var assignment: JobAssignment
    public var contrast: SimpleContrast
    /// How many times Shuffle has moved the assignment; written to the file as `recipe`.
    public private(set) var variant: Int

    public init(recipe: SimpleThemeRecipe) {
        let source = recipe.sanitized() ?? SimpleThemeRecipe(palette: ["#1E2430", "#E8E4DA"])
        palette = source.palette
        contrast = source.contrast
        variant = source.recipe
        let clean = SimplePaletteAssigner.sanitize(pins: source.pins, assignment: source.assignment,
                                                   paletteCount: source.palette.count)
        pins = clean.pins
        assignment = clean.assignment
        // Keep a stored assignment that names a swatch (or none) for every job and
        // honours the pins; anything else starts over.
        let complete = ThemeJob.allCases.allSatisfy { clean.assignment[$0] != nil }
        let honoursPins = clean.pins.allSatisfy { (clean.assignment[$0.key] ?? nil) == $0.value }
        if !complete || !honoursPins { reassign() }
    }

    public var recipe: SimpleThemeRecipe {
        SimpleThemeRecipe(palette: palette, pins: pins, assignment: assignment,
                          contrast: contrast, recipe: variant)
    }

    public mutating func addColor(_ hex: String) {
        guard palette.count < SimpleThemeRecipe.maxPaletteCount, PaletteColor(hex: hex) != nil else { return }
        palette.append(hex)
        revalidate()
    }

    /// Removes a swatch. Pins and assignments on it drop; those on a later swatch
    /// move down with it. Never goes below two colours.
    public mutating func removeColor(at index: Int) {
        guard palette.indices.contains(index), palette.count > SimpleThemeRecipe.minPaletteCount else { return }
        func remap(_ i: Int) -> Int? { i == index ? nil : (i > index ? i - 1 : i) }
        palette.remove(at: index)
        pins = pins.compactMapValues(remap)
        var next: JobAssignment = [:]
        for (job, entry) in assignment {
            if let i = entry {
                if let mapped = remap(i) { next[job] = .some(mapped) }
            } else {
                next[job] = .some(nil)
            }
        }
        assignment = next
        revalidate()
    }

    public mutating func setColor(_ hex: String, at index: Int) {
        guard palette.indices.contains(index), PaletteColor(hex: hex) != nil else { return }
        palette[index] = hex
    }

    public mutating func pin(_ job: ThemeJob, to index: Int) {
        guard palette.indices.contains(index) else { return }
        pins[job] = index
        revalidate()
    }

    public mutating func unpin(_ job: ThemeJob) {
        pins[job] = nil
    }

    /// The next assignment in Shuffle's order. Contrast, pins and palette stay.
    public mutating func shuffle() {
        assignment = SimplePaletteAssigner.shuffled(after: assignment, palette: parsedPalette, pins: pins)
        variant += 1
    }

    // MARK: -

    private var parsedPalette: [PaletteColor] { palette.compactMap(PaletteColor.init(hex:)) }

    private func key(_ a: JobAssignment) -> [Int] {
        ThemeJob.allCases.map { (a[$0] ?? nil) ?? -1 }
    }

    private mutating func reassign() {
        assignment = SimplePaletteAssigner.initial(palette: parsedPalette, pins: pins)
    }

    /// Start over only when the assignment is structurally broken (a removed swatch, a pin it
    /// does not honour); a well-formed one stays even if Shuffle would not offer it.
    private mutating func revalidate() {
        if !SimplePaletteAssigner.isStructurallyValid(assignment, paletteCount: palette.count, pins: pins) {
            reassign()
        }
    }
}

/// Undo and redo for the Simple editor: whole states, twenty of them.
public struct SimpleThemeHistory: Sendable {
    public static let capacity = 20

    private var states: [SimpleThemeState]
    private var position: Int

    public init(_ first: SimpleThemeState) {
        states = [first]
        position = 0
    }

    public private(set) var current: SimpleThemeState {
        get { states[position] }
        set { states[position] = newValue }
    }

    public var canGoBack: Bool { position > 0 }
    public var canGoForward: Bool { position < states.count - 1 }

    /// Pushing a state equal to the current one changes nothing. Pushing after going
    /// back drops the states that were ahead.
    public mutating func push(_ state: SimpleThemeState) {
        guard state != current else { return }
        states.removeSubrange((position + 1)...)
        states.append(state)
        if states.count > Self.capacity { states.removeFirst(states.count - Self.capacity) }
        position = states.count - 1
    }

    public mutating func back() { if canGoBack { position -= 1 } }
    public mutating func forward() { if canGoForward { position += 1 } }
}
