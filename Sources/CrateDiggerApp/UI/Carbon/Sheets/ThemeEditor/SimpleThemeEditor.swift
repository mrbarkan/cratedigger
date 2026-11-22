import CrateDiggerCore
import Foundation

/// The model behind the Simple theme editor: one palette-driven candidate theme,
/// its undo history, and what the preview and the Apply/Discard question need.
///
/// The app keeps showing the saved theme until `apply()`; nothing here touches
/// the registry's draft except `apply()`.
@MainActor
final class SimpleThemeEditor: ObservableObject {
    @Published private(set) var history: SimpleThemeHistory
    /// Appearance, material, cover look and fonts. Changing these never touches
    /// colours that were already generated (see `candidate`).
    /// Changing `appearance` regenerates a reopened theme's colours: ask (`needsWarning(for: .appearance)`)
    /// before setting it. Fonts, material and cover look apply without regenerating colours.
    @Published var choices: SimpleThemeChoices {
        didSet {
            if choices.appearance != oldValue.appearance { needsRegenerateWarning = false }
            refresh()
        }
    }
    @Published var name: String { didSet { refresh() } }
    /// The jobs whose preview shapes glow while the pointer is over a swatch or row.
    @Published var highlightedJobs: Set<ThemeJob> = []
    @Published private(set) var hasUnappliedChanges = false
    @Published var previewAppearance: ThemeDefinition.BaseAppearance

    /// The seed the candidate is built onto.
    private(set) var base: ThemeDefinition
    private let registry: ThemeRegistry
    private let initialState: SimpleThemeState
    private let initialChoices: SimpleThemeChoices
    private let initialName: String
    private let initialPreviewAppearance: ThemeDefinition.BaseAppearance
    /// What the file holds (or would hold) as of the last apply; `hasUnappliedChanges` compares to it.
    private var baseline: ThemeDefinition?

    let isReopenedSaved: Bool
    /// True until the first palette, pin, contrast or Shuffle change after reopening a
    /// saved Simple theme: that change regenerates every colour, so the view asks first.
    private(set) var needsRegenerateWarning: Bool

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
        var copy = definition
        let copyName = "\(definition.name) Copy"
        copy.name = copyName
        copy.id = ThemeAuthoringService.slug(from: copyName, taken: Set(registry.manifests.map(\.id)))
        copy.author = nil
        copy.version = nil
        self.init(base: copy, registry: registry, reopened: false)
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
        baseline = candidate
    }

    // MARK: Candidate and preview

    private var regenerated: Bool { !needsRegenerateWarning }

    /// The theme as it would be saved. Before the first regenerating change on a
    /// reopened theme it is the saved definition with only the non-colour choices
    /// (fonts, material, cover look) and the name laid over it.
    var candidate: ThemeDefinition {
        var built = SimpleThemeBuilder.build(state: history.current, choices: choices, onto: base)
        built.name = name
        guard isReopenedSaved, !regenerated else { return built }
        var saved = base
        saved.name = name
        saved.effects = built.effects
        saved.fonts = built.fonts ?? base.fonts
        return saved
    }

    /// The candidate drawn for `previewAppearance`, without touching the app's draft.
    var previewTheme: (theme: CarbonTheme, geometry: CarbonGeometry) {
        registry.previewTheme(for: candidate, appearance: previewAppearance)
    }

    /// The fonts the preview draws with.
    var previewFonts: [String: ThemeFont]? {
        registry.previewDefinition(for: candidate, appearance: previewAppearance).fonts
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
        needsRegenerateWarning = false
        history.push(next)
        refresh()
    }

    /// As `edit`: the view asks first when `needsWarning(for: .shuffle)` is true.
    func shuffle() { edit { $0.shuffle() } }

    func back() {
        history.back()
        refresh()
    }

    func forward() {
        history.forward()
        refresh()
    }

    /// The view calls this once the owner agreed to regenerate a reopened theme's colours.
    func confirmRegenerate() {
        needsRegenerateWarning = false
        refresh()
    }

    /// Saves and selects the candidate. Throws what the registry throws; nothing changes then.
    func apply() throws {
        let theme = candidate
        try registry.applySimple(theme)
        baseline = theme
        refresh()
    }

    /// Puts everything back as it was when the editor opened.
    func discard() {
        history = SimpleThemeHistory(initialState)
        choices = initialChoices
        name = initialName
        previewAppearance = initialPreviewAppearance
        needsRegenerateWarning = isReopenedSaved
        highlightedJobs = []
        baseline = candidate
        refresh()
    }

    // MARK: -

    private func refresh() {
        hasUnappliedChanges = candidate != baseline
    }

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
