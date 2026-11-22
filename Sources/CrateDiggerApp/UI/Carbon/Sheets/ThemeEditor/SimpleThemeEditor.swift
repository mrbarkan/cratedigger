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
    /// Appearance, material, cover look and fonts. Changing these never touches
    /// colours that were already generated (see `candidate`).
    /// Changing `appearance` regenerates a reopened theme's colours: ask (`needsWarning(for: .appearance)`)
    /// before setting it. Fonts, material and cover look apply without regenerating colours.
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

    /// A new theme started from `manifest`'s theme.
    convenience init(newFrom manifest: ThemeManifest, registry: ThemeRegistry) {
        self.init(base: registry.newSimpleSeed(from: manifest), registry: registry, reopened: false)
    }

    /// An existing Simple theme. The candidate shows its saved tokens until the
    /// palette or Shuffle changes something.
    convenience init(reopening manifest: ThemeManifest, registry: ThemeRegistry) {
        self.init(base: manifest.definition, registry: registry, reopened: true)
    }

    /// An editable copy of `definition` under a new name and id. Colours are generated afresh.
    convenience init(copyOf definition: ThemeDefinition, registry: ThemeRegistry) {
        if definition.simple != nil {
            // A sibling: same parent, same recipe and choices, a fresh id and name.
            var copy = definition
            let copyName = "\(definition.name) Copy"
            copy.name = copyName
            copy.id = ThemeAuthoringService.slug(from: copyName, taken: Set(registry.manifests.map(\.id)))
            copy.author = nil
            copy.version = nil
            self.init(base: copy, registry: registry, reopened: false)
        } else {
            self.init(base: registry.newSimpleSeed(copyOf: definition), registry: registry, reopened: false)
        }
    }

    private init(base: ThemeDefinition, registry: ThemeRegistry, reopened: Bool) {
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
        initialPreviewAppearance = base.baseAppearance
        history = SimpleThemeHistory(state)
        choices = derived
        name = base.name
        previewAppearance = base.baseAppearance
        candidate = base
        rebuild()
        baseline = candidate
    }

    // MARK: Candidate and preview

    private var regenerated: Bool { !needsRegenerateWarning }

    /// The theme as it would be saved. Before the first regenerating change on a
    /// reopened theme it is the saved definition with only the non-colour choices
    /// (fonts, material, cover look) and the name laid over it.
    private(set) var candidate: ThemeDefinition
    private var previewCache: [ThemeDefinition.BaseAppearance: (theme: CarbonTheme, geometry: CarbonGeometry)] = [:]
    private var fontsCache: [ThemeDefinition.BaseAppearance: [String: ThemeFont]?] = [:]

    /// Builds the candidate once per state, choices, name or warning change.
    private func rebuild() {
        var built = SimpleThemeBuilder.build(state: history.current, choices: choices, onto: base)
        built.name = name
        if isReopenedSaved, !regenerated {
            var saved = base
            saved.name = name
            saved.effects = built.effects
            saved.fonts = built.fonts ?? base.fonts
            built = saved
        }
        candidate = built
        previewCache = [:]
        fontsCache = [:]
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

    /// The fonts the preview draws with (resolved against the parent, as the app draws them).
    var previewFonts: [String: ThemeFont]? {
        if let hit = fontsCache[previewAppearance] { return hit }
        let fonts = registry.previewDefinition(for: candidate, appearance: previewAppearance).fonts
        fontsCache[previewAppearance] = .some(fonts)
        return fonts
    }

    /// What the owner is about to change, for `needsWarning(for:)`.
    enum Change { case palette, pin, contrast, shuffle, appearance, fonts, material, coverLook, name }

    /// Whether `change` would regenerate colours of a reopened saved theme that has not been
    /// regenerated yet. The view asks first when this is true, then calls `confirmRegenerate()`.
    func needsWarning(for change: Change) -> Bool {
        switch change {
        case .palette, .pin, .contrast, .shuffle, .appearance: return needsRegenerateWarning
        case .fonts, .material, .coverLook, .name: return false
        }
    }

    /// Every job the swatch at `index` is currently given, in the jobs' display order.
    func jobs(forSwatch index: Int) -> [ThemeJob] {
        ThemeJob.allCases.filter { (history.current.assignment[$0] ?? nil) == index }
    }

    // MARK: Editing

    /// The view must ask first when `needsWarning(for: .palette)` (or `.pin`, `.contrast`) is true;
    /// this clears the warning without asking. Applies a palette, pin or contrast change as one history step. A recoloured swatch can
    /// make the current assignment one the assigner would no longer offer; it starts over then.
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
        let palette = state.palette.compactMap(PaletteColor.init(hex:))
        let valid = SimplePaletteAssigner.validAssignments(palette: palette, pins: state.pins)
        func key(_ a: JobAssignment) -> [Int] { ThemeJob.allCases.map { (a[$0] ?? nil) ?? -1 } }
        if valid.contains(where: { key($0) == key(state.assignment) }) { return state }
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
            fonts: definition.fonts ?? [:]
        )
    }
}
