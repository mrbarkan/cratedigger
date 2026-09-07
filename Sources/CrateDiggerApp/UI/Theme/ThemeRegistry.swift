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
    @Published public var draft: ThemeDefinition? {
        willSet { recordUndoStep(replacing: newValue) }
    }

    /// How many steps UNDO can still take back. Published so the key can grey
    /// itself out; the snapshots themselves are nobody else's business.
    @Published public private(set) var undoDepth = 0

    /// Previous drafts, oldest first. A `ThemeDefinition` is a value type and
    /// a small one, so "undo" is just keeping the last few copies rather than
    /// recording an inverse for every kind of edit the panel can make.
    private var undoStack: [ThemeDefinition] = []
    private var lastUndoStepAt = Date.distantPast
    /// Set while `undoDraftStep` writes, so restoring a snapshot doesn't push
    /// one of its own and make UNDO toggle between two states forever.
    private var isUndoing = false

    /// The draft exactly as it was seeded, so "has the author touched this
    /// token?" is answerable. Only `setDraftBaseAppearance` needs it, but it
    /// can't be derived after the fact — once a token is edited there's nothing
    /// left to compare against.
    private var draftSeed: ThemeDefinition?

    /// Where a forked or duplicated draft's logo files still live: the
    /// original's bundle. The draft keeps the file *names*, previews from
    /// here until it has files of its own, and Save copies them over
    /// (`materializeDraftLogos`). Nothing touches disk before Save, so a
    /// discarded fork leaves no half-made bundle behind.
    private var draftLogoFallback: [ThemeDefinition.BaseAppearance: URL] = [:]

    private let loader: ThemeLoaderService
    private var resolvedCache: [String: (theme: CarbonTheme, geometry: CarbonGeometry)] = [:]
    private var selectionObserver: NSObjectProtocol?

    /// Defaults to searching both the app bundle and this target's SPM resource
    /// bundle — which of the two holds the built-in themes depends entirely on
    /// how the app was launched.
    public init(loader: ThemeLoaderService? = nil) {
        // Not a default argument: `Bundle.crateDiggerResources` is internal to
        // this target and can't appear in a public signature.
        self.loader = loader ?? ThemeLoaderService(bundles: Bundle.crateDiggerSearchBundles)
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
        // Defaults first, then your own, each alphabetical. Discovery order put
        // them first by accident of scanning the app bundle before the user
        // folder; sorting says so on purpose, and keeps the list stable when a
        // theme is installed or removed.
        manifests = result.themes.sorted { lhs, rhs in
            let lhsBuiltIn = lhs.origin == .builtIn
            let rhsBuiltIn = rhs.origin == .builtIn
            if lhsBuiltIn != rhsBuiltIn { return lhsBuiltIn }
            return lhs.definition.name.localizedCaseInsensitiveCompare(rhs.definition.name) == .orderedAscending
        }
        loadWarnings = result.warnings
        resolvedCache.removeAll()

        for manifest in result.themes {
            FontRegistrar.registerFonts(at: loader.fontURLs(for: manifest))
        }

        migrateRetiredSelection()
    }

    /// Linen stopped being its own theme and became Carbon's light layer, so a
    /// preference still pointing at it would resolve to nothing and leave the
    /// picker showing no selection. Carbon renders that same light palette
    /// whenever the app is in Light (or a light System) appearance.
    private func migrateRetiredSelection() {
        let preferences = PreferencesStore.shared
        guard preferences.selectedThemeID == "linen",
              manifest(for: "linen") == nil,
              manifest(for: "carbon") != nil
        else { return }
        preferences.selectedThemeID = "carbon"
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
    /// `appearance` is the Light/Dark the *user* has asked for. An adaptive
    /// theme (one carrying both layers) honours it; a single-appearance theme
    /// ignores it and forces its own, exactly as before. Pass `nil` when you
    /// only want geometry or don't have an appearance to hand — geometry never
    /// varies between layers.
    public func resolvedTheme(
        for selectedThemeID: String?,
        appearance: ThemeDefinition.BaseAppearance? = nil
    ) -> (theme: CarbonTheme, geometry: CarbonGeometry)? {
        if let draft {
            // While editing, preview the layer being worked on rather than the
            // one the system happens to be in — otherwise editing an adaptive
            // theme's Light layer at night shows you the Dark one.
            let flattened = flatten(draft, for: draft.isAdaptive ? draftEditingAppearance : appearance)
            return (theme: rendered(flattened, logoURL: draftLogoURL(for: flattened)), geometry: CarbonGeometry(definition: flattened))
        }

        guard let manifest = manifest(for: selectedThemeID) else { return nil }

        let definition = flatten(manifest.definition, for: appearance)
        // Cached per (theme, appearance): an adaptive theme renders differently
        // in each, so keying on id alone would serve the wrong one back.
        let cacheKey = "\(manifest.id)#\(definition.baseAppearance.rawValue)"
        if let cached = resolvedCache[cacheKey] {
            return cached
        }

        let resolved = (
            theme: rendered(definition, logoURL: manifest.logoURL(for: definition.baseAppearance)),
            geometry: CarbonGeometry(definition: definition)
        )
        resolvedCache[cacheKey] = resolved
        return resolved
    }

    /// Picks the layer to render: the requested appearance when the theme
    /// supports both, otherwise the theme's own declared one.
    private func flatten(
        _ definition: ThemeDefinition,
        for appearance: ThemeDefinition.BaseAppearance?
    ) -> ThemeDefinition {
        let target = (definition.isAdaptive ? appearance : nil) ?? definition.baseAppearance
        return definition.resolved(for: target)
    }

    private func rendered(_ definition: ThemeDefinition, logoURL: URL?) -> CarbonTheme {
        let base: CarbonTheme = definition.baseAppearance == .dark ? .carbon : .linen
        var theme = CarbonTheme(definition: definition, resolvedBase: base)
        theme.name = definition.name
        theme.logoURL = logoURL
        theme.logoStamp = logoURL.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return theme
    }

    /// The draft's logo for the layer being rendered, looked up live: an
    /// import lands in the bundle before the draft is saved, and the preview
    /// has to show it from that moment.
    private func draftLogoURL(for flattened: ThemeDefinition) -> URL? {
        guard let draft, let authoring, let name = flattened.logo else { return nil }
        if let own = ThemeLoaderService.logoURL(
            declared: name,
            besides: authoring.manifestURL(for: draft, replacing: sourceURL(for: draft.id))
        ) {
            return own
        }
        // A fork's file is still the original's, under the same name.
        guard let fallback = draftLogoFallback[flattened.baseAppearance],
              fallback.lastPathComponent == name
        else { return nil }
        return fallback
    }

    /// Copies into the draft's bundle every logo file it names but doesn't
    /// yet own — a fork's, still sitting in the original's bundle. Run by
    /// `saveDraft` before the manifest is written, so the saved theme is
    /// self-contained and the original is never referenced.
    public func materializeDraftLogos() throws {
        guard let draft, let authoring, !draftLogoFallback.isEmpty,
              let bundle = authoring.bundleDirectory(for: draft.id, replacing: sourceURL(for: draft.id))
        else { return }
        for appearance in [ThemeDefinition.BaseAppearance.light, .dark] {
            let flattened = draft.resolved(for: appearance)
            guard let name = flattened.logo,
                  let source = draftLogoFallback[appearance], source.lastPathComponent == name
            else { continue }
            let destination = bundle.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        }
        draftLogoFallback = [:]
    }

    // MARK: - Logo

    /// The logo file the layer being edited shows: its own, else the shared
    /// one. Same rule as `draftColor(_:)`.
    public var draftLogo: String? {
        guard let draft else { return nil }
        if draft.isAdaptive {
            return draft.variant(for: draftEditingAppearance)?.logo ?? draft.logo
        }
        return draft.logo
    }

    /// The slot an imported logo belongs in: the layer being edited when the
    /// draft is adaptive, otherwise the shared one (`nil`).
    public var draftLogoLayer: ThemeDefinition.BaseAppearance? {
        draft?.isAdaptive == true ? draftEditingAppearance : nil
    }

    /// Records `fileName` in the slot `draftLogoLayer` names.
    public func setDraftLogo(_ fileName: String) {
        guard var draft else { return }
        if let layer = draftLogoLayer {
            var variant = draft.variant(for: layer) ?? ThemeVariant()
            variant.logo = fileName
            draft.setVariant(variant, for: layer)
        } else {
            draft.logo = fileName
        }
        self.draft = draft
    }

    /// Takes the logo off the layer being edited, and only that layer. When
    /// the layer was showing the *shared* file, the other layer keeps it as
    /// its own — clearing one side of an adaptive theme must not blank the
    /// side you aren't looking at.
    public func clearDraftLogo() {
        guard var draft else { return }
        if let layer = draftLogoLayer {
            let other: ThemeDefinition.BaseAppearance = layer == .light ? .dark : .light
            if draft.variant(for: layer)?.logo == nil, let shared = draft.logo {
                var otherVariant = draft.variant(for: other) ?? ThemeVariant()
                if otherVariant.logo == nil { otherVariant.logo = shared }
                draft.setVariant(otherVariant, for: other)
                draft.logo = nil
            }
            var variant = draft.variant(for: layer) ?? ThemeVariant()
            variant.logo = nil
            draft.setVariant(variant, for: layer)
        } else {
            draft.logo = nil
        }
        self.draft = draft
    }

    /// Every logo file the draft still names, in any slot — what CLEAR checks
    /// before deleting a file from the bundle.
    public var draftLogoFilesInUse: Set<String> {
        guard let draft else { return [] }
        return Set([draft.logo, draft.light?.logo, draft.dark?.logo].compactMap { $0 })
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
    ///
    /// `appearance` is the look on screen when the editor opens. An adaptive
    /// theme starts on that layer, so opening the editor never flips the app
    /// to the other one; a single-appearance theme has only its own, and the
    /// window follows it as it always has.
    public func beginEditing(_ manifest: ThemeManifest, appearance: ThemeDefinition.BaseAppearance? = nil) {
        // A different theme is a different edit history.
        clearUndo()
        let definition = manifest.definition
        let layer = definition.isAdaptive ? (appearance ?? definition.baseAppearance) : definition.baseAppearance
        switch manifest.origin {
        case .userInstalled:
            draftLogoFallback = [:]
            draft = seeded(definition)
            draftSeed = draft
            draftEditingAppearance = layer
        case .builtIn where BuiltInThemeEditing.isEditable(manifest):
            // Beta-only: the shipped themes are still being tuned, so the
            // editor writes them back to the checkout rather than forking.
            // See `BuiltInThemeEditing` — and close it for the RC.
            draftLogoFallback = [:]
            draft = seeded(definition)
            draftSeed = draft
            draftEditingAppearance = layer
        case .builtIn:
            // The logo files stay in the app bundle; the fork previews them
            // from there and gets its own copies when it's saved.
            draftLogoFallback = manifest.logoURLs
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
            draftEditingAppearance = layer
        }
    }

    /// Which layer of an adaptive draft the editor is currently writing to.
    /// Meaningless for a single-appearance theme, where every edit goes to the
    /// shared token set.
    @Published public var draftEditingAppearance: ThemeDefinition.BaseAppearance = .dark

    /// The value a swatch should show: the active layer's override if it has
    /// one, otherwise the shared token. Centralised here so no view has to know
    /// whether the draft is adaptive.
    public func draftColor(_ key: String) -> String? {
        guard let draft else { return nil }
        if draft.isAdaptive {
            return draft.variant(for: draftEditingAppearance)?.colors?[key] ?? draft.colors?[key]
        }
        return draft.colors?[key]
    }

    /// Writes into the layer being edited when the draft is adaptive, so
    /// changing a color in Light mode doesn't also change it in Dark.
    public func setDraftColor(_ key: String, _ hex: String) {
        setDraftColors([key: hex], appearance: draft?.isAdaptive == true ? draftEditingAppearance : nil)
    }

    /// Writes a whole set of colors in one publish, into `appearance`'s layer —
    /// or into the shared tokens when `appearance` is `nil` or the draft isn't
    /// adaptive.
    ///
    /// Naming the layer (rather than always using `draftEditingAppearance`) is
    /// what lets one action set both looks at once: a screen preset that's a
    /// different piece of hardware in Light than in Dark has to write the pair,
    /// not whichever half you happen to have open.
    public func setDraftColors(_ colors: [String: String], appearance: ThemeDefinition.BaseAppearance?) {
        guard var draft, !colors.isEmpty else { return }

        if let appearance, draft.isAdaptive {
            var variant = draft.variant(for: appearance) ?? ThemeVariant()
            variant.colors = (variant.colors ?? [:]).merging(colors) { _, new in new }
            if appearance == .light { draft.light = variant } else { draft.dark = variant }
        } else {
            draft.colors = (draft.colors ?? [:]).merging(colors) { _, new in new }
        }
        self.draft = draft
    }

    /// Turns a single-appearance draft into one carrying both looks, or
    /// collapses it back to whichever layer is being edited.
    ///
    /// Going adaptive, the appearance the theme was already authored in needs
    /// no overrides — the shared tokens *are* it — while the opposite layer
    /// starts from that side's built-in wherever the author hasn't chosen a
    /// color, so the theme is usable in both from the moment it's switched on.
    public func setDraftAdaptive(_ adaptive: Bool) {
        guard var draft else { return }

        if adaptive {
            guard !draft.isAdaptive else { return }
            let current = draft.baseAppearance
            let other: ThemeDefinition.BaseAppearance = current == .light ? .dark : .light
            let otherLayer = ThemeVariant(colors: repaintedColors(of: draft, from: current, to: other))

            if current == .light {
                draft.light = ThemeVariant()
                draft.dark = otherLayer
            } else {
                draft.dark = ThemeVariant()
                draft.light = otherLayer
            }
            draftEditingAppearance = current
        } else {
            guard draft.isAdaptive else { return }
            // Keep what's on screen: flatten the layer being edited into the
            // shared set and drop both layers.
            let keep = draftEditingAppearance
            draft = draft.resolved(for: keep)
            draft.light = nil
            draft.dark = nil
        }

        self.draft = draft
    }

    /// Copies the layer being edited onto the other one, so the second
    /// appearance starts from the first instead of from a stock built-in.
    ///
    /// Most light/dark pairs are not opposites — they share an accent, a
    /// phosphor color, a set of shadows, and differ in a handful of surfaces.
    /// Building the second look by tweaking a copy of the first is far less
    /// work than rebuilding it from Linen or Carbon.
    ///
    /// The *resolved* colors are written, not the layer's sparse overrides:
    /// what gets copied is what you can see, including everything inherited
    /// from the shared token set.
    public func copyDraftLayer(to destination: ThemeDefinition.BaseAppearance) {
        guard var draft, draft.isAdaptive, destination != draftEditingAppearance else { return }

        let source = draft.resolved(for: draftEditingAppearance)
        var target = draft.variant(for: destination) ?? ThemeVariant()
        target.colors = source.colors
        target.shadows = source.shadows
        target.effects = source.effects
        // The logo comes along as its own file in the destination's slot, so
        // a later re-import on either side changes only that side.
        target.logo = nil
        if let file = draftLogoURL(for: source), let authoring,
           let copied = try? authoring.importLogo(
               from: file, into: draft.id,
               replacing: sourceURL(for: draft.id), layer: destination
           ) {
            target.logo = copied.lastPathComponent
        }

        draft.setVariant(target, for: destination)
        self.draft = draft
    }

    /// Forks the open draft into a new theme, in place, so "start from this
    /// one" doesn't mean saving, closing, and re-opening a copy.
    public func duplicateDraft() {
        guard var draft else { return }
        // The logo files stay where they are (the original's bundle, or
        // wherever this draft was already previewing them from); the copy
        // keeps their names and gets its own files on Save.
        var fallback: [ThemeDefinition.BaseAppearance: URL] = [:]
        for appearance in [ThemeDefinition.BaseAppearance.light, .dark] {
            fallback[appearance] = draftLogoURL(for: draft.resolved(for: appearance))
        }
        draftLogoFallback = fallback

        let name = "\(draft.name) Copy"
        draft.id = ThemeAuthoringService.slug(from: name, taken: Set(manifests.map(\.id)))
        draft.name = name
        // The copy is the current author's, not the original's.
        draft.author = nil
        draft.version = nil
        self.draft = draft
        draftSeed = draft
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
        guard var draft else { return }

        // On an adaptive draft the keys mean "show me this layer" — both looks
        // are being kept, so there's nothing to repaint.
        guard !draft.isAdaptive else {
            draftEditingAppearance = newValue
            return
        }
        guard draft.baseAppearance != newValue else { return }

        var colors = draft.colors ?? [:]
        for (key, value) in repaintedColors(of: draft, from: draft.baseAppearance, to: newValue) {
            colors[key] = value
        }

        draft.colors = colors
        draft.baseAppearance = newValue
        self.draft = draft
    }

    /// The tokens that should change when a draft moves between appearances:
    /// the ones the author hasn't touched, mapped onto the destination's
    /// built-in. Returning to the appearance the draft was opened at restores
    /// that theme's own palette instead of the generic built-in, which is what
    /// makes the switch reversible rather than quietly destructive.
    private func repaintedColors(
        of draft: ThemeDefinition,
        from previous: ThemeDefinition.BaseAppearance,
        to next: ThemeDefinition.BaseAppearance
    ) -> [String: String] {
        let previousBuiltIn: CarbonTheme = previous == .dark ? .carbon : .linen
        let nextBuiltIn: CarbonTheme = next == .dark ? .carbon : .linen

        var repainted: [String: String] = [:]
        for token in ThemeTokenCatalog.allColorTokens {
            let seedValue = draftSeed?.colors?[token.key]
            let untouched = draft.colors?[token.key].map { current in
                seedValue.map { ThemeAuthoringService.colorsMatch(current, $0) } == true
                    || ThemeAuthoringService.colorsMatch(current, previousBuiltIn[keyPath: token.read].themeHexString)
            } ?? true
            guard untouched else { continue }

            let restored = (next == draftSeed?.baseAppearance) ? seedValue : nil
            repainted[token.key] = restored ?? nextBuiltIn[keyPath: token.read].themeHexString
        }
        return repainted
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

    /// True while the draft is a shipped theme opened in place rather than a
    /// fork of one. Beta-only; see `BuiltInThemeEditing`.
    public var editingBuiltIn: Bool {
        guard let draft, let manifest = manifest(for: draft.id) else { return false }
        return manifest.origin == .builtIn && BuiltInThemeEditing.isEditable(manifest)
    }

    /// Writes the draft to the Themes folder, re-scans, and selects it — the
    /// theme you just authored becomes the theme you're using. Returns the
    /// saved id.
    @discardableResult
    public func saveDraft() throws -> String? {
        guard let draft, let authoring else { return nil }

        // Only record what differs from the parent, so the file reads as the
        // author's intent rather than a dump of every token. A root theme has
        // no parent, and this still prunes each appearance layer against the
        // shared tokens — which is all a built-in needs.
        let parent = manifest(for: draft.inherits)?.definition
        let normalized = ThemeAuthoringService.minimized(draft, against: parent)

        let builtInDestinations = editingBuiltIn ? BuiltInThemeEditing.destinations(forThemeID: draft.id) : []
        if builtInDestinations.isEmpty {
            // A built-in's logos already sit beside it; only a fork needs its
            // own copies, and `bundleDirectory` would put them in the user's
            // Themes folder, which is not where this theme lives.
            try materializeDraftLogos()
            try authoring.save(normalized, replacing: sourceURL(for: draft.id))
        } else {
            // Patch the shipped file rather than rewrite it: the draft has
            // every token filled in, so saving it whole would freeze the ones
            // the theme deliberately leaves unset — the screen lamps follow
            // the accent until something pins them. Against the seed the
            // editor started from, the diff is exactly what was touched.
            let shipped = manifest(for: draft.id)?.definition ?? draft
            let patched = shipped.merging(draft.tokensChanged(from: draftSeed ?? draft))
            for destination in builtInDestinations {
                try BuiltInThemeEditing.write(patched, to: destination)
            }
        }

        let id = draft.id
        self.draft = nil
        draftSeed = nil
        clearUndo()
        refresh()
        PreferencesStore.shared.selectedThemeID = id
        return id
    }

    /// Deletes an installed theme's files. Built-ins are refused: they live in
    /// the app bundle, aren't ours to remove, and would reappear on the next
    /// scan anyway.
    ///
    /// Deleting the theme in use falls back to the plain appearance rather than
    /// leaving `selectedThemeID` pointing at something that no longer exists.
    @discardableResult
    public func deleteTheme(_ manifest: ThemeManifest) -> Bool {
        guard manifest.origin != .builtIn, let authoring else { return false }
        try? authoring.delete(themeID: manifest.id)

        if PreferencesStore.shared.selectedThemeID == manifest.id {
            PreferencesStore.shared.selectedThemeID = nil
        }
        if draft?.id == manifest.id { discardDraft() }
        refresh()
        return true
    }

    /// Drops the draft without saving; the app snaps back to the selected
    /// theme on the next frame.
    public func discardDraft() {
        draft = nil
        draftSeed = nil
        draftLogoFallback = [:]
        clearUndo()
    }

    // MARK: - Undo

    /// Steps back to the draft as it was before the last change — any change,
    /// since every control in the editor writes through `draft`.
    public func undoDraftStep() {
        guard let previous = undoStack.popLast() else { return }
        isUndoing = true
        draft = previous
        isUndoing = false
        // A restore ends the current burst, so the next edit always starts a
        // step of its own rather than coalescing into the one just undone.
        lastUndoStepAt = .distantPast
        undoDepth = undoStack.count
    }

    /// Snapshots the outgoing draft, unless it belongs to the burst already
    /// recorded. A slider drag or a name typed into the field arrives as
    /// dozens of writes; without coalescing they'd fill all ten slots with
    /// pixels of the same gesture and UNDO would never reach the edit before
    /// it.
    private func recordUndoStep(replacing newValue: ThemeDefinition?) {
        guard !isUndoing, let current = draft, newValue != nil else { return }
        let now = Date()
        defer { lastUndoStepAt = now }
        guard now.timeIntervalSince(lastUndoStepAt) > Self.undoCoalesceWindow else { return }

        undoStack.append(current)
        if undoStack.count > Self.undoDepthLimit { undoStack.removeFirst() }
        undoDepth = undoStack.count
    }

    private func clearUndo() {
        undoStack.removeAll()
        undoDepth = 0
        lastUndoStepAt = .distantPast
    }

    static let undoDepthLimit = 10
    /// Seconds of quiet that separate one undoable change from the next. A
    /// `var` only so tests can widen or close it instead of sleeping through it.
    static var undoCoalesceWindow: TimeInterval = 0.5
}
