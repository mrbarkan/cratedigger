import Combine
import CrateDiggerCore
import Foundation

/// Owns theme discovery + resolution for the whole app: a thin, observable
/// wrapper around `ThemeLoaderService` that `CarbonThemed` reads to resolve
/// the active `CarbonTheme`/`CarbonGeometry`, and that the theme picker UI
/// reads to list what's installed.
///
/// A singleton (like `PreferencesStore.shared`) rather than something passed
/// down the view tree, because `CarbonThemed` is applied at several
/// independent subtree roots (`CarbonRootView`, `ThemedSheetWrapper`,
/// `CarbonAboutView`, `CarbonGuideView`, `MiniPlayerView`) that don't
/// otherwise share an environment.
@MainActor
public final class ThemeRegistry: ObservableObject {
    public static let shared = ThemeRegistry()

    @Published public private(set) var manifests: [ThemeManifest] = []
    @Published public private(set) var loadWarnings: [ThemeLoadWarning] = []

    /// The theme currently open in the editor. While this is non-nil it wins
    /// over `selectedThemeID` everywhere — every `carbonThemed(mode:)` subtree
    /// observes this object, so assigning a mutated draft repaints the whole
    /// app on the next frame. That *is* the editor's live preview: there's no
    /// separate preview surface to keep in sync, you're looking at the real app.
    ///
    /// Deliberately not cached (unlike installed themes): a draft changes on
    /// every keystroke and dial tick, so a cache would only ever miss.
    @Published public var draft: ThemeDefinition?

    /// The draft exactly as it was seeded, so "has the author touched this
    /// token?" is answerable. Only `setDraftBaseAppearance` needs it, but it
    /// can't be derived after the fact — once a token is edited there's nothing
    /// left to compare against.
    private var draftSeed: ThemeDefinition?

    private let loader: ThemeLoaderService
    private var resolvedCache: [String: (theme: CarbonTheme, geometry: CarbonGeometry)] = [:]
    private var selectionObserver: NSObjectProtocol?

    public init(loader: ThemeLoaderService = ThemeLoaderService()) {
        self.loader = loader
        refresh()

        // `selectedThemeID` changing is the common case (picking a theme in
        // the UI); re-publish so `CarbonThemed` re-resolves without a full
        // re-scan of disk.
        selectionObserver = NotificationCenter.default.addObserver(
            forName: PreferencesStore.themesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    deinit {
        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }
    }

    public var userThemesDirectory: URL? {
        loader.resolvedUserThemesDirectory()
    }

    /// Re-runs discovery (bundled + the user Themes folder) and clears the
    /// resolved-theme cache. Call after installing/editing a theme file
    /// while the app is running ("Refresh" in the picker).
    public func refresh() {
        let result = loader.discoverThemes()
        manifests = result.themes
        loadWarnings = result.warnings
        resolvedCache.removeAll()

        for manifest in result.themes {
            FontRegistrar.registerFonts(at: loader.fontURLs(for: manifest))
        }
    }

    /// The installed manifest matching `id`, or `nil` if unset/not installed.
    public func manifest(for id: String?) -> ThemeManifest? {
        guard let id else { return nil }
        return manifests.first { $0.id == id }
    }

    /// The definition driving the app right now — the open draft if there is
    /// one, otherwise the installed selection. Callers that need the raw
    /// definition rather than the rendered theme (font-role overrides, the
    /// editor's own "what am I editing" check) go through this so the draft
    /// wins for them too, not just for colors.
    public func activeDefinition(for selectedThemeID: String?) -> ThemeDefinition? {
        draft ?? manifest(for: selectedThemeID)?.definition
    }

    /// The active `(CarbonTheme, CarbonGeometry)` pair for `selectedThemeID`,
    /// or `nil` if no id is given or it doesn't match an installed theme —
    /// callers fall back to the built-in light/dark pairing in that case.
    /// An open draft takes precedence over the selection entirely.
    public func resolvedTheme(for selectedThemeID: String?) -> (theme: CarbonTheme, geometry: CarbonGeometry)? {
        if let draft {
            return (theme: rendered(draft), geometry: CarbonGeometry(definition: draft))
        }

        guard let manifest = manifest(for: selectedThemeID) else { return nil }
        if let cached = resolvedCache[manifest.id] {
            return cached
        }

        let resolved = (
            theme: rendered(manifest.definition),
            geometry: CarbonGeometry(definition: manifest.definition)
        )
        resolvedCache[manifest.id] = resolved
        return resolved
    }

    private func rendered(_ definition: ThemeDefinition) -> CarbonTheme {
        let base: CarbonTheme = definition.baseAppearance == .dark ? .carbon : .linen
        return CarbonTheme(definition: definition, resolvedBase: base)
    }

    // MARK: - Authoring

    /// `nil` only if the user's Application Support folder is unreachable, in
    /// which case there's nowhere to author to and the editor stays read-only.
    public var authoring: ThemeAuthoringService? {
        userThemesDirectory.map { ThemeAuthoringService(themesDirectory: $0) }
    }

    /// True when the draft is an editable, user-installed theme (so Save
    /// overwrites it in place) rather than a fork not yet written to disk.
    public func isUserInstalled(_ themeID: String) -> Bool {
        sourceURL(for: themeID) != nil
    }

    /// The file an installed theme was loaded from, so saving rewrites *it*
    /// rather than a path guessed from the theme's id. A theme's folder is
    /// named freely — `Apple Music.cdtheme` can declare `"id": "apple-music"` —
    /// and writing to the id-derived path instead produces a second file with a
    /// duplicate id, which the loader resolves by silently dropping one of them.
    public func sourceURL(for themeID: String) -> URL? {
        guard let manifest = manifest(for: themeID),
              case .userInstalled(let url) = manifest.origin
        else { return nil }
        return url
    }

    /// Opens `manifest` for editing. A built-in is **forked** — it lives in
    /// the app bundle where we can't write, and reusing its id would collide
    /// with the bundled copy on next launch (the loader drops duplicate ids).
    /// A user theme opens in place, keeping its id so the selection and any
    /// `inherits` chains pointing at it survive the edit.
    public func beginEditing(_ manifest: ThemeManifest) {
        switch manifest.origin {
        case .userInstalled:
            draft = seeded(manifest.definition)
            draftSeed = draft
        case .builtIn:
            var fork = manifest.definition
            fork.id = ThemeAuthoringService.slug(
                from: "\(manifest.definition.name) Copy",
                taken: Set(manifests.map(\.id))
            )
            fork.name = "\(manifest.definition.name) Copy"
            fork.author = nil
            fork.version = nil
            // The fork keeps the built-in as its parent, so saving records
            // only the tokens actually changed (see `minimized(_:against:)`).
            fork.inherits = manifest.definition.id
            draft = seeded(fork)
            draftSeed = draft
        }
    }

    /// Applies a LIGHT/DARK change so it actually shows.
    ///
    /// `baseAppearance` is only a *declaration* in the file format — it decides
    /// window chrome and which built-in supplies omitted tokens. But a draft is
    /// seeded with every token filled in, so nothing is omitted, and flipping
    /// the flag on its own repainted precisely nothing. The key looked dead.
    ///
    /// So the flip repaints the tokens the author hasn't touched, and leaves
    /// the ones they have. Returning to the appearance the theme was opened at
    /// restores that theme's own palette rather than the generic built-in, so
    /// the switch is reversible instead of quietly destroying the design.
    public func setDraftBaseAppearance(_ newValue: ThemeDefinition.BaseAppearance) {
        guard var draft, draft.baseAppearance != newValue else { return }
        let seed = draftSeed

        let previousBuiltIn: CarbonTheme = draft.baseAppearance == .dark ? .carbon : .linen
        let nextBuiltIn: CarbonTheme = newValue == .dark ? .carbon : .linen

        var colors = draft.colors ?? [:]
        for token in ThemeTokenCatalog.allColorTokens {
            let seedValue = seed?.colors?[token.key]
            let untouched = colors[token.key].map { current in
                seedValue.map { ThemeAuthoringService.colorsMatch(current, $0) } == true
                    || ThemeAuthoringService.colorsMatch(current, previousBuiltIn[keyPath: token.read].themeHexString)
            } ?? true
            guard untouched else { continue }

            let restored = (newValue == seed?.baseAppearance) ? seedValue : nil
            colors[token.key] = restored ?? nextBuiltIn[keyPath: token.read].themeHexString
        }

        draft.colors = colors
        draft.baseAppearance = newValue
        self.draft = draft
    }

    /// Fills in every token the editor can show, reading each one from the
    /// *rendered* theme so a control always opens on the value currently on
    /// screen — including tokens the file never mentions, which would
    /// otherwise appear as an empty swatch or a dial parked at zero.
    ///
    /// Seeding makes the draft a complete definition rather than a sparse one;
    /// `ThemeAuthoringService.minimized(_:against:)` strips it back down at
    /// save time, so the file on disk still records only real changes.
    private func seeded(_ definition: ThemeDefinition) -> ThemeDefinition {
        let base: CarbonTheme = definition.baseAppearance == .dark ? .carbon : .linen
        let renderedTheme = CarbonTheme(definition: definition, resolvedBase: base)
        let renderedGeometry = CarbonGeometry(definition: definition)

        var result = definition
        var colors = definition.colors ?? [:]
        for token in ThemeTokenCatalog.allColorTokens where colors[token.key] == nil {
            colors[token.key] = renderedTheme[keyPath: token.read].themeHexString
        }
        result.colors = colors

        var geometry = definition.geometry ?? [:]
        for token in ThemeTokenCatalog.allGeometryTokens where geometry[token.key] == nil {
            geometry[token.key] = Double(renderedGeometry[keyPath: token.read])
        }
        result.geometry = geometry

        // Non-nil so the font rows can assign into it; an empty dictionary
        // encodes as absent after minimization.
        result.fonts = definition.fonts ?? [:]
        return result
    }

    /// Writes the draft to the Themes folder, re-scans, and selects it — the
    /// theme you just authored becomes the theme you're using. Returns the
    /// saved id.
    @discardableResult
    public func saveDraft() throws -> String? {
        guard let draft, let authoring else { return nil }

        // Only record what differs from the parent, so the file reads as the
        // author's intent rather than a dump of every token.
        let parent = manifest(for: draft.inherits)?.definition
        try authoring.save(
            ThemeAuthoringService.minimized(draft, against: parent),
            replacing: sourceURL(for: draft.id)
        )

        let id = draft.id
        self.draft = nil
        draftSeed = nil
        refresh()
        PreferencesStore.shared.selectedThemeID = id
        return id
    }

    /// Drops the draft without saving; the app snaps back to the selected
    /// theme on the next frame.
    public func discardDraft() {
        draft = nil
        draftSeed = nil
    }
}
