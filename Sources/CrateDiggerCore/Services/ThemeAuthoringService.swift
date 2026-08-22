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
        var result = definition

        // Appearance layers are pruned against this theme's *own* shared
        // tokens, not the inherited parent: a light/dark pair mostly agrees
        // with itself, so what belongs in a layer is only what that appearance
        // actually changes. Done before the parent pass so the shared set is
        // still complete while the layers are measured against it.
        result.light = pruneVariant(definition.light, against: definition)
        result.dark = pruneVariant(definition.dark, against: definition)

        guard let base else { return result }

        result.colors = prune(definition.colors, base.colors, equal: colorsMatch)
        result.shadows = prune(definition.shadows, base.shadows, equal: ==)
        result.fonts = prune(definition.fonts, base.fonts, equal: ==)
        result.geometry = prune(definition.geometry, base.geometry, equal: ==)
        result.effects = prune(definition.effects, base.effects, equal: ==)
        return result
    }

    /// Keeps a layer present-but-empty rather than dropping it to `nil` when it
    /// matches the shared set exactly: `light`/`dark` being non-nil is what
    /// marks a theme adaptive (`ThemeDefinition.isAdaptive`), so pruning an
    /// identical layer away would quietly turn a light/dark theme back into a
    /// single-appearance one.
    private static func pruneVariant(_ variant: ThemeVariant?, against definition: ThemeDefinition) -> ThemeVariant? {
        guard let variant else { return nil }
        return ThemeVariant(
            colors: prune(variant.colors, definition.colors, equal: colorsMatch),
            shadows: prune(variant.shadows, definition.shadows, equal: ==),
            effects: prune(variant.effects, definition.effects, equal: ==)
        )
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
    public static func colorsMatch(_ lhs: String, _ rhs: String) -> Bool {
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

    /// `<Themes>/<id>.cdtheme` — the folder form for a *new* theme, always,
    /// even when it carries no fonts. Authoring one shape rather than two means
    /// importing a font later never has to migrate a bare `.json` into a bundle.
    public func bundleURL(for themeID: String) -> URL {
        themesDirectory
            .appendingPathComponent("\(themeID).cdtheme", isDirectory: true)
    }

    /// Where a theme's `theme.json` belongs.
    ///
    /// Editing an existing theme must rewrite **the file it came from**, not a
    /// path derived from its id. A theme's folder name is free-form — a hand-
    /// authored `Apple Music.cdtheme` can perfectly well declare
    /// `"id": "apple-music"` — so deriving the destination from the id creates
    /// a *second* file with the same id. The loader then resolves that clash by
    /// keeping whichever sorts first and dropping the other, which is how an
    /// edit could be written to disk and still vanish.
    public func manifestURL(for definition: ThemeDefinition, replacing sourceURL: URL? = nil) -> URL {
        sourceURL ?? bundleURL(for: definition.id).appendingPathComponent("theme.json")
    }

    /// A theme's bundled-font folder, resolved against the same source.
    ///
    /// Returns `nil` for a bare `<slug>.json` theme: `Fonts/` is only ever read
    /// from inside a `.cdtheme` bundle (see `fontURLs(for:)`), so there is
    /// nowhere to put a font that the loader would find again.
    public func fontsDirectory(for themeID: String, replacing sourceURL: URL? = nil) -> URL? {
        guard let sourceURL else {
            return bundleURL(for: themeID).appendingPathComponent("Fonts", isDirectory: true)
        }
        let directory = sourceURL.deletingLastPathComponent()
        guard directory.pathExtension.lowercased() == "cdtheme" else { return nil }
        return directory.appendingPathComponent("Fonts", isDirectory: true)
    }

    // MARK: - I/O

    /// Writes the theme's `theme.json`, creating the bundle if needed, and
    /// returns the file written. Pass `replacing:` with the manifest URL the
    /// theme was loaded from when editing an existing theme — see
    /// `manifestURL(for:replacing:)` for why that matters.
    ///
    /// Keys are sorted and the JSON pretty-printed so an authored theme stays
    /// hand-editable and diffs cleanly — these files are meant to be shared and
    /// read, not just consumed.
    @discardableResult
    public func save(_ definition: ThemeDefinition, replacing sourceURL: URL? = nil) throws -> URL {
        let destination = manifestURL(for: definition, replacing: sourceURL)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(definition)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    public struct FontImportUnsupported: LocalizedError {
        public var errorDescription: String? {
            "This theme is a single .json file, which can't carry fonts. Use a system font, or re-save it as a .cdtheme bundle first."
        }
    }

    /// Copies a `.ttf`/`.otf` into the theme's `Fonts/` folder so the theme
    /// stays self-contained and portable — zip the `.cdtheme` and the font
    /// travels with it, which is the whole point of the bundle form.
    /// Returns the destination URL for the caller to register with CoreText.
    @discardableResult
    public func importFont(from source: URL, into themeID: String, replacing sourceURL: URL? = nil) throws -> URL {
        guard let fontsDirectory = fontsDirectory(for: themeID, replacing: sourceURL) else {
            throw FontImportUnsupported()
        }
        try fileManager.createDirectory(at: fontsDirectory, withIntermediateDirectories: true)

        let destination = fontsDirectory.appendingPathComponent(source.lastPathComponent)
        // Re-importing the same face is a normal thing to do while iterating.
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    // MARK: - Repair

    public struct ThemeRepairUnsupported: LocalizedError {
        public var errorDescription: String? {
            "This file can't be read as a theme, so there's no id to repair. Open it in a text editor to see what's wrong."
        }
    }

    /// Gives a skipped file an `id` of its own and writes it back, returning
    /// the new id.
    ///
    /// The one case the loader skips that a machine can actually fix: two files
    /// claiming one id, or a file claiming none. Both mean the theme is on disk
    /// and perfectly renderable — it just can't be told apart from something
    /// else, and the whole repair is a unique string. Everything else it skips
    /// is malformed JSON, which is the author's to fix.
    ///
    /// Deliberately *not* touching `name`: the duplicate is usually a copied
    /// bundle the author meant to keep, and renaming it as well would hide
    /// which one they were looking at.
    @discardableResult
    public func reassignID(at url: URL, taken: Set<String>) throws -> String {
        guard let data = try? Data(contentsOf: url),
              var definition = try? JSONDecoder().decode(ThemeDefinition.self, from: data)
        else { throw ThemeRepairUnsupported() }

        definition.id = Self.slug(from: definition.name, taken: taken)
        // Rewrites the file where it lies: a hand-authored bundle's folder name
        // is the author's, and moving it to an id-derived path would be a
        // second surprise on top of the one they came here to fix.
        try save(definition, replacing: url)
        return definition.id
    }

    // MARK: - Export

    /// Packs a theme into a single file to hand to someone else.
    ///
    /// Always a zipped `.cdtheme`, whether or not the theme carries fonts, so
    /// there is one thing to send and one instruction to give with it: unzip
    /// it into your Themes folder.
    ///
    /// Built fresh rather than copying the theme's own folder, because what's
    /// on disk is *minimized* — a file that says "inherits carbon, plus these
    /// nine tokens". That's the right thing to store and the wrong thing to
    /// send, since the parent may be a theme only the author has. Pass the
    /// resolved definition and the export is self-contained; bundled fonts are
    /// copied in beside it so the typography travels too.
    ///
    /// Zipping is `NSFileCoordinator`'s `.forUploading`, the system's own
    /// directory-to-archive path — what Finder's "Compress" uses, and no
    /// archiver dependency.
    public func export(_ definition: ThemeDefinition, fonts fontsDirectory: URL?, to destination: URL) throws {
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("CrateDiggerThemeExport-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }

        let bundle = staging.appendingPathComponent("\(Self.slug(from: definition.name)).cdtheme", isDirectory: true)
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(definition).write(to: bundle.appendingPathComponent("theme.json"), options: .atomic)

        if let fontsDirectory, fileManager.fileExists(atPath: fontsDirectory.path) {
            try fileManager.copyItem(at: fontsDirectory, to: bundle.appendingPathComponent("Fonts", isDirectory: true))
        }

        try Self.zip(bundle, to: destination, fileManager: fileManager)
    }

    /// The name to offer in the save panel: the theme's display name, so the
    /// recipient sees "Llama 97.cdtheme.zip" rather than a slug.
    public static func exportFilename(for definition: ThemeDefinition) -> String {
        let cleaned = definition.name
            .components(separatedBy: CharacterSet(charactersIn: "/:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(cleaned.isEmpty ? slug(from: definition.name) : cleaned).cdtheme.zip"
    }

    private static func zip(_ directory: URL, to destination: URL, fileManager: FileManager) throws {
        var coordinatorError: NSError?
        var copyError: Error?

        NSFileCoordinator().coordinate(
            readingItemAt: directory,
            options: [.forUploading],
            error: &coordinatorError
        ) { archive in
            // The archive only exists for the duration of this block, so the
            // copy has to happen inside it.
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: archive, to: destination)
            } catch {
                copyError = error
            }
        }

        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
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
