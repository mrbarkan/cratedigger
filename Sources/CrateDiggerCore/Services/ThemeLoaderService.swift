import Foundation

public struct ThemeLoadResult: Sendable {
    public let themes: [ThemeManifest]
    public let warnings: [ThemeLoadWarning]

    public init(themes: [ThemeManifest], warnings: [ThemeLoadWarning]) {
        self.themes = themes
        self.warnings = warnings
    }
}

/// Discovers and parses theme definitions from the app bundle and the user's
/// themes folder, resolving `inherits` chains into fully-merged definitions.
///
/// Modeled on `ExternalToolLocator`'s candidate search: a missing or malformed
/// file is never fatal — it is skipped and reported as a warning so the rest
/// of the themes still load. There is deliberately no `resolveRequired`-style
/// throwing entry point here, because "no themes installed" (or "one theme is
/// broken") is always a normal, recoverable state, unlike a missing ffmpeg.
public struct ThemeLoaderService {
    private let fileManager: FileManager
    private let bundle: Bundle
    private let userThemesDirectoryOverride: URL?

    public init(
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        userThemesDirectoryOverride: URL? = nil
    ) {
        self.fileManager = fileManager
        self.bundle = bundle
        self.userThemesDirectoryOverride = userThemesDirectoryOverride
    }

    /// `~/Library/Application Support/CrateDigger/Themes` — where a user drops
    /// a `.cdtheme` folder or bare `.json` file to install a theme, no
    /// different from unzipping a Winamp skin into its Skins folder.
    public static func defaultUserThemesDirectory(fileManager: FileManager = .default) -> URL? {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("CrateDigger", isDirectory: true)
            .appendingPathComponent("Themes", isDirectory: true)
    }

    public func resolvedUserThemesDirectory() -> URL? {
        userThemesDirectoryOverride ?? Self.defaultUserThemesDirectory(fileManager: fileManager)
    }

    public func discoverThemes() -> ThemeLoadResult {
        var warnings: [ThemeLoadWarning] = []
        var candidates: [(definition: ThemeDefinition, origin: ThemeManifest.Origin, sourceURL: URL)] = []

        for url in bundledThemeFileURLs() {
            switch parseThemeFile(at: url) {
            case .success(let definition):
                candidates.append((definition, .builtIn, url))
            case .failure(let failure):
                warnings.append(ThemeLoadWarning(sourceURL: url, message: failure.message))
            }
        }

        if let userThemesDirectory = resolvedUserThemesDirectory() {
            ensureDirectoryExists(userThemesDirectory)
            for url in themeFileURLs(in: userThemesDirectory) {
                switch parseThemeFile(at: url) {
                case .success(let definition):
                    candidates.append((definition, .userInstalled(sourceURL: url), url))
                case .failure(let failure):
                    warnings.append(ThemeLoadWarning(sourceURL: url, message: failure.message))
                }
            }
        }

        var seenIDs: Set<String> = []
        var accepted: [(definition: ThemeDefinition, origin: ThemeManifest.Origin, sourceURL: URL)] = []
        for candidate in candidates {
            guard !candidate.definition.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                warnings.append(ThemeLoadWarning(sourceURL: candidate.sourceURL, message: "Theme is missing an \"id\" — ignoring."))
                continue
            }
            guard seenIDs.insert(candidate.definition.id).inserted else {
                warnings.append(ThemeLoadWarning(
                    sourceURL: candidate.sourceURL,
                    message: "Duplicate theme id \"\(candidate.definition.id)\" — ignoring this file."
                ))
                continue
            }
            accepted.append(candidate)
        }

        let byID = Dictionary(uniqueKeysWithValues: accepted.map { ($0.definition.id, $0.definition) })

        let manifests = accepted.map { candidate in
            ThemeManifest(
                definition: Self.resolveInheritance(candidate.definition, in: byID, warnings: &warnings, sourceURL: candidate.sourceURL),
                origin: candidate.origin
            )
        }

        return ThemeLoadResult(themes: manifests, warnings: warnings)
    }

    // MARK: - Inheritance resolution

    static func resolveInheritance(
        _ definition: ThemeDefinition,
        in byID: [String: ThemeDefinition],
        warnings: inout [ThemeLoadWarning],
        sourceURL: URL
    ) -> ThemeDefinition {
        var chain: [ThemeDefinition] = [definition]
        var visited: Set<String> = [definition.id]
        var current = definition

        while let parentID = current.inherits {
            if visited.contains(parentID) {
                warnings.append(ThemeLoadWarning(
                    sourceURL: sourceURL,
                    message: "Theme \"\(definition.id)\" has a circular \"inherits\" chain at \"\(parentID)\" — stopping inheritance there."
                ))
                break
            }
            guard let parent = byID[parentID] else {
                // Unresolvable reference (typo, or the referenced theme isn't
                // installed in this context). Not fatal: any token still
                // missing after this is filled from the built-in matching
                // `baseAppearance` when the App layer converts this into a
                // renderable `CarbonTheme`.
                break
            }
            visited.insert(parentID)
            chain.append(parent)
            current = parent
        }

        guard chain.count > 1 else {
            return definition
        }

        var merged = chain.removeLast()
        for ancestor in chain.reversed() {
            merged = merge(base: merged, override: ancestor)
        }
        return merged
    }

    private static func merge(base: ThemeDefinition, override: ThemeDefinition) -> ThemeDefinition {
        ThemeDefinition(
            id: override.id,
            name: override.name,
            author: override.author,
            version: override.version,
            baseAppearance: override.baseAppearance,
            inherits: override.inherits,
            colors: mergeDictionaries(base.colors, override.colors),
            shadows: mergeDictionaries(base.shadows, override.shadows),
            fonts: mergeDictionaries(base.fonts, override.fonts),
            geometry: mergeDictionaries(base.geometry, override.geometry)
        )
    }

    private static func mergeDictionaries<Value>(_ base: [String: Value]?, _ override: [String: Value]?) -> [String: Value]? {
        guard let override else { return base }
        guard let base else { return override }
        return base.merging(override) { _, new in new }
    }

    // MARK: - Discovery

    private func bundledThemeFileURLs() -> [URL] {
        var found: [URL] = []
        for directory in bundledThemesDirectoryCandidates() {
            found.append(contentsOf: themeFileURLs(in: directory))
        }
        return found
    }

    /// SPM resource bundles for an executable target (`.copy("Resources/Themes")`)
    /// are packaged as a nested `<Package>_<Target>.bundle` alongside the binary —
    /// `Bundle.main.resourceURL` doesn't point inside it directly. Mirrors the
    /// same sibling-`*.bundle` scan `LibraryViewModel+Onboarding` uses to find
    /// the bundled starter album, so this works both in a packaged `.app` and
    /// a raw `swift build`/`swift run` layout.
    private func bundledThemesDirectoryCandidates() -> [URL] {
        var candidates: [URL] = []

        if let resourceURL = bundle.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("Themes", isDirectory: true))
            candidates.append(contentsOf: siblingResourceBundleThemeDirectories(in: resourceURL))
        }
        candidates.append(contentsOf: siblingResourceBundleThemeDirectories(in: bundle.bundleURL))

        return candidates
    }

    private func siblingResourceBundleThemeDirectories(in directory: URL) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .filter { $0.pathExtension == "bundle" }
            .map { $0.appendingPathComponent("Themes", isDirectory: true) }
    }

    /// A theme file is either a bare `<slug>.json`, or a `<slug>.cdtheme`
    /// folder containing `theme.json` (and optionally `Fonts/*.ttf|otf`).
    private func themeFileURLs(in directory: URL) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { entry -> URL? in
                switch entry.pathExtension.lowercased() {
                case "json":
                    return entry
                case "cdtheme":
                    let manifestURL = entry.appendingPathComponent("theme.json")
                    return fileManager.fileExists(atPath: manifestURL.path) ? manifestURL : nil
                default:
                    return nil
                }
            }
    }

    private struct ThemeParseFailure: Error {
        let message: String
    }

    private func parseThemeFile(at url: URL) -> Result<ThemeDefinition, ThemeParseFailure> {
        do {
            let data = try Data(contentsOf: url)
            let definition = try JSONDecoder().decode(ThemeDefinition.self, from: data)
            return .success(definition)
        } catch {
            return .failure(ThemeParseFailure(message: "Could not parse theme: \(error.localizedDescription)"))
        }
    }

    @discardableResult
    private func ensureDirectoryExists(_ url: URL) -> Bool {
        if fileManager.fileExists(atPath: url.path) {
            return true
        }
        return (try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)) != nil
    }

    /// Fonts bundled inside an installed theme's `Fonts/` subfolder, for the
    /// App layer to register with `FontRegistrar`. Returns an empty array for
    /// bare `.json` themes (no `Fonts/` sibling) and for built-in themes
    /// (bundled fonts are registered separately at launch).
    public func fontURLs(for manifest: ThemeManifest) -> [URL] {
        guard case .userInstalled(let sourceURL) = manifest.origin else { return [] }
        // sourceURL is either `<slug>.cdtheme/theme.json` or a bare `<slug>.json`.
        guard sourceURL.lastPathComponent == "theme.json", sourceURL.pathExtension == "json" else { return [] }
        let themeBundleDirectory = sourceURL.deletingLastPathComponent()
        guard themeBundleDirectory.pathExtension.lowercased() == "cdtheme" else { return [] }

        let fontsDirectory = themeBundleDirectory.appendingPathComponent("Fonts", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: fontsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
    }
}
