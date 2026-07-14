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

    /// The active `(CarbonTheme, CarbonGeometry)` pair for `selectedThemeID`,
    /// or `nil` if no id is given or it doesn't match an installed theme —
    /// callers fall back to the built-in light/dark pairing in that case.
    public func resolvedTheme(for selectedThemeID: String?) -> (theme: CarbonTheme, geometry: CarbonGeometry)? {
        guard let manifest = manifest(for: selectedThemeID) else { return nil }
        if let cached = resolvedCache[manifest.id] {
            return cached
        }

        let base: CarbonTheme = manifest.definition.baseAppearance == .dark ? .carbon : .linen
        let resolved = (
            theme: CarbonTheme(definition: manifest.definition, resolvedBase: base),
            geometry: CarbonGeometry(definition: manifest.definition)
        )
        resolvedCache[manifest.id] = resolved
        return resolved
    }
}
