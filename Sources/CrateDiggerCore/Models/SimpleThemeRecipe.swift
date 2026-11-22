import Foundation

/// The six jobs a palette colour can be given in Simple mode, in display order.
public enum ThemeJob: String, Codable, CaseIterable, Sendable {
    case frame, panels, text, accent, glass, screenText

    public var label: String {
        switch self {
        case .frame:      return "Frame"
        case .panels:     return "Panels"
        case .text:       return "Text"
        case .accent:     return "Accent"
        case .glass:      return "Screen Glass"
        case .screenText: return "Screen Text"
        }
    }
}

public enum SimpleContrast: String, Codable, CaseIterable, Sendable {
    case soft, standard, high
}

/// What Simple mode remembers about a theme: the palette, which swatch is pinned
/// to which job, the current assignment, the contrast level and the recipe variant.
///
/// Third parties can author this block, so decoding never throws on a wrong shape
/// inside it: the owner's theme must always open. `ThemeDefinition` also decodes the
/// block with `try?` and keeps `sanitized()`.
public struct SimpleThemeRecipe: Codable, Equatable, Sendable {
    public static let maxPaletteCount = 6
    public static let minPaletteCount = 2

    /// `"#RRGGBB"` swatches, 2 to 6 after sanitising.
    public var palette: [String]
    /// Jobs the owner fixed to a swatch (index into `palette`).
    public var pins: [ThemeJob: Int]
    /// The current job to swatch assignment. A job whose value is `nil` has no swatch
    /// (it is derived), and encodes as JSON `null`.
    public var assignment: [ThemeJob: Int?]
    public var contrast: SimpleContrast
    /// Which recipe variant (shuffle position) produced the theme.
    public var recipe: Int

    public init(
        palette: [String],
        pins: [ThemeJob: Int] = [:],
        assignment: [ThemeJob: Int?] = [:],
        contrast: SimpleContrast = .standard,
        recipe: Int = 0
    ) {
        self.palette = palette
        self.pins = pins
        self.assignment = assignment
        self.contrast = contrast
        self.recipe = recipe
    }

    private enum CodingKeys: String, CodingKey {
        case palette, pins, assignment, contrast, recipe
    }

    /// Dictionaries keyed by an enum encode as arrays by default; the file wants objects.
    private struct JobKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        palette = (try? c.decode([String].self, forKey: .palette)) ?? []
        contrast = (try? c.decode(SimpleContrast.self, forKey: .contrast)) ?? .standard
        recipe = (try? c.decode(Int.self, forKey: .recipe)) ?? 0

        pins = [:]
        if let nested = try? c.nestedContainer(keyedBy: JobKey.self, forKey: .pins) {
            for key in nested.allKeys {
                guard let job = ThemeJob(rawValue: key.stringValue),
                      let index = try? nested.decode(Int.self, forKey: key) else { continue }
                pins[job] = index
            }
        }
        assignment = [:]
        if let nested = try? c.nestedContainer(keyedBy: JobKey.self, forKey: .assignment) {
            for key in nested.allKeys {
                guard let job = ThemeJob(rawValue: key.stringValue) else { continue }
                if (try? nested.decodeNil(forKey: key)) == true {
                    assignment[job] = .some(nil)
                } else if let index = try? nested.decode(Int.self, forKey: key) {
                    assignment[job] = .some(index)
                }
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(palette, forKey: .palette)
        var pinsContainer = c.nestedContainer(keyedBy: JobKey.self, forKey: .pins)
        for job in ThemeJob.allCases {
            if let index = pins[job] {
                try pinsContainer.encode(index, forKey: JobKey(stringValue: job.rawValue)!)
            }
        }
        var assignmentContainer = c.nestedContainer(keyedBy: JobKey.self, forKey: .assignment)
        for job in ThemeJob.allCases {
            guard let entry = assignment[job] else { continue }
            let key = JobKey(stringValue: job.rawValue)!
            if let index = entry {
                try assignmentContainer.encode(index, forKey: key)
            } else {
                try assignmentContainer.encodeNil(forKey: key)
            }
        }
        try c.encode(contrast, forKey: .contrast)
        try c.encode(recipe, forKey: .recipe)
    }

    /// A safe version of a block that may have come from a hand-edited or newer file:
    /// invalid hex dropped, at most 6 colours kept, pins and assignments that point
    /// outside the surviving palette dropped. `nil` when fewer than 2 colours survive.
    public func sanitized() -> SimpleThemeRecipe? {
        // Old index -> new index, built while dropping bad hex and truncating, so a
        // pin or assignment keeps pointing at the swatch it meant.
        var kept: [String] = []
        var remap: [Int: Int] = [:]
        for (oldIndex, hex) in palette.enumerated() where kept.count < Self.maxPaletteCount {
            guard PaletteColor(hex: hex) != nil else { continue }
            remap[oldIndex] = kept.count
            kept.append(hex)
        }
        guard kept.count >= Self.minPaletteCount else { return nil }
        var result = self
        result.palette = kept
        result.pins = pins.compactMapValues { remap[$0] }
        var newAssignment: [ThemeJob: Int?] = [:]
        for (job, entry) in assignment {
            if let index = entry {
                if let mapped = remap[index] { newAssignment[job] = .some(mapped) }
            } else {
                newAssignment[job] = .some(nil)
            }
        }
        result.assignment = newAssignment
        result.recipe = max(0, recipe)
        return result
    }
}
