import Foundation

/// Editing a theme *in place* rather than forking it: what changed, and how to
/// lay it back over the file it came from.
///
/// `ThemeAuthoringService.minimized(_:against:)` answers a different question —
/// what a fork need not repeat from its parent — and it prunes appearance
/// layers against the theme's own shared tokens on the way, which is right for
/// a new file and wrong for patching an existing one. These two are the
/// in-place pair: a strict key-by-key diff, and a strict key-by-key overlay.
public extension ThemeDefinition {

    /// The tokens that differ from `original`, compared where they sit —
    /// shared against shared, light against light, dark against dark.
    ///
    /// The editor seeds its draft with every token filled in, so a draft
    /// compared against the *file* looks like a rewrite of the whole theme.
    /// Compared against the seed it started from, it is exactly what the
    /// author touched, which is the only thing that should reach the file.
    /// That is what keeps a token the theme deliberately leaves unset — the
    /// screen lamps, which follow the accent until something pins them —
    /// unset after somebody opens the editor and changes a different colour.
    ///
    /// Identity is carried through unchanged: this describes an edit to a
    /// theme, not a new one.
    func tokensChanged(from original: ThemeDefinition) -> ThemeDefinition {
        var changes = self
        changes.colors = Self.changed(colors, from: original.colors, equal: Self.colorsMatch)
        changes.shadows = Self.changed(shadows, from: original.shadows, equal: ==)
        changes.fonts = Self.changed(fonts, from: original.fonts, equal: ==)
        changes.geometry = Self.changed(geometry, from: original.geometry, equal: ==)
        changes.effects = Self.changed(effects, from: original.effects, equal: ==)
        changes.logo = logo == original.logo ? nil : logo
        changes.light = Self.changed(light, from: original.light)
        changes.dark = Self.changed(dark, from: original.dark)
        return changes
    }

    /// `self` with `changes` laid over it, key by key.
    ///
    /// Only the tokens `changes` actually carries are replaced, so every line
    /// of the original file that the author did not touch survives the write
    /// untouched — including the ones it deliberately omits. Identity stays
    /// this definition's own: a patch never renames the theme it patches.
    func merging(_ changes: ThemeDefinition) -> ThemeDefinition {
        var result = self
        result.baseAppearance = changes.baseAppearance
        result.colors = Self.merge(colors, changes.colors)
        result.shadows = Self.merge(shadows, changes.shadows)
        result.fonts = Self.merge(fonts, changes.fonts)
        result.geometry = Self.merge(geometry, changes.geometry)
        result.effects = Self.merge(effects, changes.effects)
        result.logo = changes.logo ?? logo
        result.light = Self.merge(light, changes.light)
        result.dark = Self.merge(dark, changes.dark)
        return result
    }

    // MARK: - Dictionaries

    private static func changed<Value>(
        _ updated: [String: Value]?,
        from original: [String: Value]?,
        equal: (Value, Value) -> Bool
    ) -> [String: Value]? {
        guard let updated else { return nil }
        let kept = updated.filter { key, value in
            guard let before = original?[key] else { return true }
            return !equal(value, before)
        }
        return kept.isEmpty ? nil : kept
    }

    private static func merge<Value>(
        _ base: [String: Value]?,
        _ changes: [String: Value]?
    ) -> [String: Value]? {
        guard let changes else { return base }
        guard var merged = base else { return changes }
        for (key, value) in changes { merged[key] = value }
        return merged
    }

    // MARK: - Appearance layers

    /// A layer that changed nothing still comes back present-but-empty, the
    /// same rule `pruneVariant` follows: `light`/`dark` being non-nil is what
    /// makes a theme adaptive, so dropping an unchanged layer to `nil` would
    /// quietly turn a light/dark theme into a single-appearance one.
    private static func changed(_ updated: ThemeVariant?, from original: ThemeVariant?) -> ThemeVariant? {
        guard let updated else { return nil }
        return ThemeVariant(
            colors: changed(updated.colors, from: original?.colors, equal: colorsMatch),
            shadows: changed(updated.shadows, from: original?.shadows, equal: ==),
            effects: changed(updated.effects, from: original?.effects, equal: ==),
            logo: updated.logo == original?.logo ? nil : updated.logo
        )
    }

    private static func merge(_ base: ThemeVariant?, _ changes: ThemeVariant?) -> ThemeVariant? {
        guard let changes else { return base }
        guard let base else { return changes }
        return ThemeVariant(
            colors: merge(base.colors, changes.colors),
            shadows: merge(base.shadows, changes.shadows),
            effects: merge(base.effects, changes.effects),
            logo: changes.logo ?? base.logo
        )
    }

    /// `"#ff0000"` and `"FF0000"` are the same colour to the parser, so they
    /// are the same token here — otherwise merely reformatting a value would
    /// count as an edit. Same rule `ThemeAuthoringService` applies.
    private static func colorsMatch(_ lhs: String, _ rhs: String) -> Bool {
        ThemeAuthoringService.colorsMatch(lhs, rhs)
    }
}
