import CrateDiggerCore
import Foundation

/// The model behind the Simple theme editor: one palette-driven candidate theme,
/// its undo history, and what the preview and the Apply/Discard question need.
///
/// The app keeps showing the saved theme until `apply()`; nothing here touches
/// the registry's draft except `apply()`.
@MainActor
final class SimpleThemeEditor: ObservableObject {
    @Published private(set) var history: SimpleThemeHistory { didSet { rebuild() } }
    /// Appearance, style, material, cover look and fonts. Changing these never touches
    /// colours that were already generated (see `candidate`).
    /// Changing `appearance` regenerates a reopened theme's colours: ask (`needsWarning(for: .appearance)`)
    /// before setting it. Fonts, style, material and cover look apply without regenerating colours.
    @Published var choices: SimpleThemeChoices {
        didSet {
            if choices.appearance != oldValue.appearance { needsRegenerateWarning = false }
            rebuild()
        }
    }
    @Published var name: String { didSet { rebuild() } }
    /// The jobs whose preview shapes glow while the pointer is over a swatch or row.
    @Published var highlightedJobs: Set<ThemeJob> = []
    @Published private(set) var hasUnappliedChanges = false
    @Published var previewAppearance: ThemeDefinition.BaseAppearance

    /// The seed the candidate is built onto.
    private(set) var base: ThemeDefinition
    private let registry: ThemeRegistry
    private var initialState: SimpleThemeState
    private var initialChoices: SimpleThemeChoices
    private var initialName: String
    private var initialPreviewAppearance: ThemeDefinition.BaseAppearance
    /// What the file holds (or would hold) as of the last apply; `hasUnappliedChanges` compares to it.
    private var baseline: ThemeDefinition?

    let isReopenedSaved: Bool
    /// True until the first palette, pin, contrast or Shuffle change after reopening a
    /// saved Simple theme: that change regenerates every colour, so the view asks first.
    @Published private(set) var needsRegenerateWarning: Bool { didSet { rebuild() } }

    // MARK: Creating

    /// A new theme started from `manifest`'s theme. `appearance` is the look on
    /// screen, which an adaptive preview starts on (nil: the theme's own).
    convenience init(newFrom manifest: ThemeManifest, registry: ThemeRegistry,
                     appearance: ThemeDefinition.BaseAppearance? = nil) {
        self.init(base: registry.newSimpleSeed(from: manifest), registry: registry, reopened: false,
                  appearance: appearance)
    }

    /// An existing Simple theme. The candidate shows its saved tokens until the
    /// palette or Shuffle changes something. One saved before Simple themes were
    /// self-contained (it names a parent) opens regenerated on a self-contained seed
    /// instead, with APPLY ready to write it whole.
    convenience init(reopening manifest: ThemeManifest, registry: ThemeRegistry,
                     appearance: ThemeDefinition.BaseAppearance? = nil) {
        if let seed = registry.selfContainedSeed(reopening: manifest) {
            self.init(base: seed, registry: registry, reopened: false, appearance: appearance)
            baseline = manifest.definition
            hasUnappliedChanges = true
        } else {
            self.init(base: manifest.definition, registry: registry, reopened: true, appearance: appearance)
        }
    }

    /// An editable copy of `definition` under a new name and id. Colours are generated afresh.
    convenience init(copyOf definition: ThemeDefinition, registry: ThemeRegistry,
                     appearance: ThemeDefinition.BaseAppearance? = nil) {
        if definition.simple != nil {
            // A sibling: same recipe and choices, a fresh id and name. Self-contained
            // like any Simple theme, so there is no parent to keep.
            var copy = definition
            let copyName = "\(definition.name) Copy"
            copy.name = copyName
            copy.id = ThemeAuthoringService.slug(from: copyName, taken: Set(registry.manifests.map(\.id)))
            copy.author = nil
            copy.version = nil
            copy.inherits = nil
            copy.logo = nil
            self.init(base: copy, registry: registry, reopened: false, appearance: appearance)
        } else {
            self.init(base: registry.newSimpleSeed(copyOf: definition), registry: registry, reopened: false,
                      appearance: appearance)
        }
    }

    private init(base: ThemeDefinition, registry: ThemeRegistry, reopened: Bool,
                 appearance: ThemeDefinition.BaseAppearance?) {
        self.base = base
        self.registry = registry
        isReopenedSaved = reopened
        needsRegenerateWarning = reopened

        let recipe = base.simple ?? SimpleThemeRecipe(palette: ["#1E2430", "#E8E4DA"])
        let state = SimpleThemeState(recipe: recipe)
        let derived = Self.choices(from: base)
        initialState = state
        initialChoices = derived
        initialName = base.name
        // The look on screen, so the preview of an adaptive theme opens on the layer
        // the app is showing (a single-appearance one draws its own whatever this is).
        let opening = appearance ?? base.baseAppearance
        initialPreviewAppearance = opening
        history = SimpleThemeHistory(state)
        choices = derived
        name = base.name
        previewAppearance = opening
        candidate = base
        rebuild()
        baseline = candidate
    }

    // MARK: Candidate and preview

    private var regenerated: Bool { !needsRegenerateWarning }

    /// The theme as it would be saved. Before the first regenerating change on a
    /// reopened theme it is the saved definition with only the non-colour choices
    /// (fonts, style, material, cover look) and the name laid over it.
    private(set) var candidate: ThemeDefinition
    private var previewCache: [ThemeDefinition.BaseAppearance: (theme: CarbonTheme, geometry: CarbonGeometry)] = [:]

    /// Builds the candidate once per state, choices, name or warning change.
    private func rebuild() {
        var built = SimpleThemeBuilder.build(state: history.current, choices: choices, onto: base)
        built.name = name
        if isReopenedSaved, !regenerated {
            var saved = base
            saved.name = name
            saved.effects = built.effects
            saved.fonts = built.fonts ?? base.fonts
            saved.style = built.style
            built = saved
        }
        candidate = built
        previewCache = [:]
        hasUnappliedChanges = baseline.map { built != $0 } ?? false
    }

    /// The candidate drawn for `previewAppearance`, without touching the app's draft.
    /// Cached per appearance until the candidate changes.
    var previewTheme: (theme: CarbonTheme, geometry: CarbonGeometry) {
        if let hit = previewCache[previewAppearance] { return hit }
        let made = registry.previewTheme(for: candidate, appearance: previewAppearance)
        previewCache[previewAppearance] = made
        return made
    }

    /// The fonts the preview draws with: the candidate's own, exactly as the app will
    /// draw them, since a Simple theme has no parent and fonts have no layers.
    var previewFonts: [String: ThemeFont]? { candidate.fonts }

    /// What the owner is about to change, for `needsWarning(for:)`.
    enum Change { case palette, pin, contrast, shuffle, appearance, fonts, style, material, coverLook, name }

    /// Whether `change` would regenerate colours of a reopened saved theme that has not been
    /// regenerated yet. The view asks first when this is true, then calls `confirmRegenerate()`.
    func needsWarning(for change: Change) -> Bool {
        switch change {
        case .palette, .pin, .contrast, .shuffle, .appearance: return needsRegenerateWarning
        case .fonts, .style, .material, .coverLook, .name: return false
        }
    }

    /// Every job the swatch at `index` is currently given, in the jobs' display order.
    func jobs(forSwatch index: Int) -> [ThemeJob] {
        ThemeJob.allCases.filter { (history.current.assignment[$0] ?? nil) == index }
    }

    // MARK: Editing

    /// The view must ask first when `needsWarning(for: .palette)` (or `.pin`, `.contrast`) is true;
    /// this clears the warning without asking. Applies a palette, pin or contrast change as one history step. The assignment is kept while it is
    /// structurally valid (see `SimplePaletteAssigner.isStructurallyValid`) and re-picked only when broken.
    func edit(_ change: (inout SimpleThemeState) -> Void) {
        var next = history.current
        change(&next)
        next = Self.revalidated(next)
        guard next != history.current else { return }
        needsRegenerateWarning = false
        history.push(next)
    }

    /// As `edit`: the view asks first when `needsWarning(for: .shuffle)` is true.
    func shuffle() { edit { $0.shuffle() } }

    func back() {
        history.back()
    }

    func forward() {
        history.forward()
    }

    /// The view calls this once the owner agreed to regenerate a reopened theme's colours.
    func confirmRegenerate() {
        needsRegenerateWarning = false
    }

    /// Saves and selects the candidate. Throws what the registry throws; nothing changes then.
    func apply() throws {
        let theme = candidate
        try registry.applySimple(theme)
        baseline = theme
        // Discard now returns to what was applied, not to how the editor opened.
        initialState = history.current
        initialChoices = choices
        initialName = name
        initialPreviewAppearance = previewAppearance
        isRegeneratedAtApply = regenerated
        hasUnappliedChanges = false
    }

    /// Puts everything back as it was when the editor opened, or as last applied.
    func discard() {
        history = SimpleThemeHistory(initialState)
        choices = initialChoices
        name = initialName
        previewAppearance = initialPreviewAppearance
        needsRegenerateWarning = isReopenedSaved && !isRegeneratedAtApply
        highlightedJobs = []
        rebuild()
    }

    // MARK: -

    private var isRegeneratedAtApply = false

    private static func revalidated(_ state: SimpleThemeState) -> SimpleThemeState {
        if SimplePaletteAssigner.isStructurallyValid(state.assignment, paletteCount: state.palette.count,
                                                     pins: state.pins) { return state }
        var recipe = state.recipe
        recipe.assignment = [:]
        return SimpleThemeState(recipe: recipe)
    }

    private static func choices(from definition: ThemeDefinition) -> SimpleThemeChoices {
        let appearance: SimpleAppearanceMode = definition.isAdaptive ? .both
            : (definition.baseAppearance == .light ? .light : .dark)
        let effects = definition.effects ?? [:]
        return SimpleThemeChoices(
            appearance: appearance,
            material: ShellMaterial.resolve(effects: effects)?.material,
            coverLook: CoverScreenLook.resolve(effects: effects)?.look,
            fonts: definition.fonts ?? [:],
            style: definition.resolvedStyle
        )
    }
}
