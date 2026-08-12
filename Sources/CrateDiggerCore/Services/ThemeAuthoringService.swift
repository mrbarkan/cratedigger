import Foundation

/// Writes user-authored themes back into the folder `ThemeLoaderService` reads
/// — the inverse of the loader, and the only place that knows how to lay a
/// `.cdtheme` bundle out on disk.
///
/// Mirrors the loader's posture: nothing here is destructive to *other* themes,
/// and a save always produces a file the loader can read back. The one rule
/// worth stating up front is that a theme's `id` is immutable once assigned —
/// it's the key `inherits` chains and `PreferencesStore.selectedThemeID` point
/// at, so renaming a theme changes `name` only. Forking (built-in → editable
/// copy) is what mints a new id.
public struct ThemeAuthoringService {
    private let fileManager: FileManager
    private let themesDirectory: URL

    public init(fileManager: FileManager = .default, themesDirectory: URL) {
        self.fileManager = fileManager
        self.themesDirectory = themesDirectory
    }

    // MARK: - Naming

    /// Turns a display name into a filesystem- and reference-safe slug,
    /// uniquified against `taken` by appending `-2`, `-3`, … A name with no
    /// usable characters at all still yields a valid id rather than an empty
    /// one, because an empty id is the single thing the loader refuses to
    /// index (see `discoverThemes`).
    public static func slug(from name: String, taken: Set<String> = []) -> String {
        let allowed = CharacterSet.alphanumerics
        let base = name
            .lowercased()
            .unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { partial, character in
                // Collapse runs of separators rather than emitting "my---theme".
                if character == "-" && partial.last == "-" { return }
                partial.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        let candidate = base.isEmpty ? "theme" : base
        guard taken.contains(candidate) else { return candidate }

        var suffix = 2
        while taken.contains("\(candidate)-\(suffix)") { suffix += 1 }
        return "\(candidate)-\(suffix)"
    }

    // MARK: - Minimization

    /// Drops every token that already matches `base`, so a saved theme records
    /// only what it actually changes and `inherits` supplies the rest. This is
    /// what keeps an authored file readable (a dozen lines, like `Llama 97`)
    /// instead of a 40-token wall that hides the author's real intent.
    ///
    /// `base` is the *resolved* definition the theme inherits from; `nil`
    /// (nothing inherited) returns the definition untouched.
    public static func minimized(_ definition: ThemeDefinition, against base: ThemeDefinition?) -> ThemeDefinition {
        guard let base else { return definition }

        var result = definition
        result.colors = prune(definition.colors, base.colors, equal: colorsMatch)
        result.shadows = prune(definition.shadows, base.shadows, equal: ==)
        result.fonts = prune(definition.fonts, base.fonts, equal: ==)
        result.geometry = prune(definition.geometry, base.geometry, equal: ==)
        result.effects = prune(definition.effects, base.effects, equal: ==)
        return result
    }

    private static func prune<Value>(
        _ overrides: [String: Value]?,
        _ base: [String: Value]?,
        equal: (Value, Value) -> Bool
    ) -> [String: Value]? {
        guard let overrides else { return nil }
        let kept = overrides.filter { key, value in
            guard let baseValue = base?[key] else { return true }
            return !equal(value, baseValue)
        }
        return kept.isEmpty ? nil : kept
    }

    /// `"#ff0000"` and `"FF0000"` are the same color to the parser, so they're
    /// the same token here too — otherwise a round-trip through the editor
    /// would re-record every color it merely re-formatted.
    static func colorsMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizedHex(lhs) == normalizedHex(rhs)
    }

    private static func normalizedHex(_ value: String) -> String {
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        // "#RRGGBB" and "#RRGGBBFF" describe the same opaque color.
        if hex.count == 8 && hex.hasSuffix("FF") { hex.removeLast(2) }
        return hex
    }

    // MARK: - Layout

    /// `<Themes>/<id>.cdtheme` — the folder form, always, even when the theme
    /// carries no fonts. Authoring one shape rather than two means importing a
    /// font later never has to migrate a bare `.json` into a bundle.
    public func bundleURL(for themeID: String) -> URL {
        themesDirectory
            .appendingPathComponent("\(themeID).cdtheme", isDirectory: true)
    }

    public func fontsDirectory(for themeID: String) -> URL {
        bundleURL(for: themeID).appendingPathComponent("Fonts", isDirectory: true)
    }

    // MARK: - I/O

    /// Writes `<id>.cdtheme/theme.json`, creating the bundle if needed, and
    /// returns the bundle folder. Keys are sorted and the JSON pretty-printed
    /// so an authored theme stays hand-editable and diffs cleanly — these
    /// files are meant to be shared and read, not just consumed.
    @discardableResult
    public func save(_ definition: ThemeDefinition) throws -> URL {
        let bundle = bundleURL(for: definition.id)
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(definition)
        try data.write(to: bundle.appendingPathComponent("theme.json"), options: .atomic)
        return bundle
    }

    /// Copies a `.ttf`/`.otf` into the theme's `Fonts/` folder so the theme
    /// stays self-contained and portable — zip the `.cdtheme` and the font
    /// travels with it, which is the whole point of the bundle form.
    /// Returns the destination URL for the caller to register with CoreText.
    @discardableResult
    public func importFont(from source: URL, into themeID: String) throws -> URL {
        let fontsDirectory = fontsDirectory(for: themeID)
        try fileManager.createDirectory(at: fontsDirectory, withIntermediateDirectories: true)

        let destination = fontsDirectory.appendingPathComponent(source.lastPathComponent)
        // Re-importing the same face is a normal thing to do while iterating.
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    /// Removes an authored theme's whole bundle. Only ever called for
    /// user-installed themes — a built-in lives in the app bundle and isn't
    /// ours to delete.
    public func delete(themeID: String) throws {
        let bundle = bundleURL(for: themeID)
        guard fileManager.fileExists(atPath: bundle.path) else { return }
        try fileManager.removeItem(at: bundle)
    }
}
