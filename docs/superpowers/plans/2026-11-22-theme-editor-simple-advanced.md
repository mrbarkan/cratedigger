# Theme Editor: Simple and Advanced — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Simple mode to the theme editor that builds a whole theme from a 2–6 colour palette, with Shuffle, pins, font presets and an illustrated preview, while Advanced keeps today's live token editor plus a PREVIEW panel.

**Architecture:** All decidable logic (colour math, the recipe table, assignments and Shuffle, palette extraction, history, theme assembly, mode-crossing rules) lives in `CrateDiggerCore` under `Services/ThemePalette/`, with XCTest. The app holds one `SimpleThemeEditor` `ObservableObject` whose candidate theme is *not* `ThemeRegistry.draft`, so the app keeps rendering the saved theme while Simple is open. The preview is a SwiftUI illustration drawn from a resolved `CarbonTheme`.

**Tech Stack:** Swift 6 / SwiftPM, SwiftUI + AppKit, XCTest via `scripts/test.sh`.

**Spec:** `docs/superpowers/specs/2026-11-22-theme-editor-simple-advanced-design.md` (read it before any task; this plan argues from it).

## Global Constraints

- Branch: `v2.4` (worktree `.claude/worktrees/v2-4`). Release line 2.4 beta.
- Build: `swift build`. Tests: `scripts/test.sh` (never bare `swift test`); one class: `scripts/test.sh --filter <Class>`.
- Core has no AppKit/SwiftUI. Colours in Core are `"#RRGGBB"` / `"#RRGGBBAA"` strings.
- The six jobs, in this order: `frame, panels, text, accent, glass, screenText`.
- Contrast levels: `soft, standard, high`; default `standard`. Shuffle never changes contrast.
- Contrast floors (WCAG 2 ratio): ink on paper and on well 7.0 (soft 4.5, high 10); ink2 on paper 4.5; ink3 and columnHeaderInk on paper 3.0; chassisInk on metal and on chassis 4.5; oledForeground on oledSurface 7.0; oledForegroundMuted on oledSurface 3.0; selectionInk on the selection fill 4.5.
- Tokens whose `CarbonTheme` property is an optional `…Override` (lamp overrides, `transportLamp`, `meterHot` if optional, etc.) are never written by Simple; they keep following the accent.
- Meaning colours keep their hue family: `red`, `sun`/`sunHi`/`sunLo`, `cyan`/`cyanGlow`, `indigo`.
- Shell material strengths written by Simple: weave 0.09, brushed 0.06, plastic 0.05; grain 0.10 and blasted 0.06 (tune from captures). Album-art look strength 0.55, pixel size 1.5 for every look (tune from captures).
- History: 20 steps, whole Simple state per step.
- Every token Simple writes must be a key in `ThemeTokenCatalog.allColorTokens`.
- Nothing about interface styles is stored or shown.
- Window captures for checks: `screencapture -l <windowID>`, debug build launched with a scratch `CRATEDIGGER_CRATES_DIR` (never the owner's library).
- Commit after each task with a conventional message ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A palette of near-identical colours (all one hue, or two greys 2% apart): the theme must still separate frame from panels and keep every floor — `SimplePaletteRecipeTests.testHostileNearIdenticalPalette`.
2. Pure black + pure white only, and neon-only palettes: floors still hold, accent still reads as accent — `testHostileBlackWhite`, `testHostileNeon` (Task 3).
3. Removing a swatch that a pin or the current assignment points at: pins drop, assignment re-validates, history steps stay intact — `SimpleThemeHistoryTests.testRemovingPinnedSwatch` and `SimplePaletteAssignerTests.testPinToRemovedIndexIsDropped` (Tasks 4, 5).
4. Opening a user theme that has a `simple` block written by a newer recipe version, or with a malformed block (indices out of range, 1 or 7 colours): it opens, falls back safely, never crashes — `SimpleThemeDefinitionTests.testMalformedBlockIsSanitized` (Task 2).
5. Closing the panel (red button, Esc, NEW pressed again) with an unapplied Simple draft: Apply/Discard is always asked; the app keeps showing the saved theme until Apply — covered by `SimpleThemeEditorTests.testCloseWithUnappliedAsks` (Task 7).

---

### Task 1: Colour math in Core

**Files:**
- Create: `Sources/CrateDiggerCore/Services/ThemePalette/PaletteColor.swift`
- Test: `Tests/CrateDiggerCoreTests/PaletteColorTests.swift`

**Interfaces:**
- Produces:
  - `public struct PaletteColor: Equatable, Hashable, Sendable` with `r, g, b, a: Double` (0…1, sRGB).
  - `init?(hex: String)`, `var hex: String` (`"#RRGGBB"`, or `"#RRGGBBAA"` when `a < 1`).
  - `var oklch: OKLCH`, `init(oklch: OKLCH, alpha: Double = 1)` (gamut-clipped by reducing chroma, never hue).
  - `public struct OKLCH: Equatable, Sendable { var l: Double; var c: Double; var h: Double }` (l 0…1, h degrees).
  - `var relativeLuminance: Double`; `static func contrast(_ a: PaletteColor, _ b: PaletteColor) -> Double` (WCAG 2; alpha composited over `b` first).
  - `func distance(to: PaletteColor) -> Double` (Euclidean in OKLab).

- [ ] **Step 1: Write failing tests** — `testHexRoundTrip` (`#1B1D22`, `#FF6A13`, `#FFFFFF80` survive), `testOKLCHRoundTripWithin1e3` for 200 seeded random colours, `testContrastBlackWhiteIs21`, `testContrastSameIs1`, `testOutOfGamutClipsChromaKeepsHue` (L 0.7 C 0.4 h 145 → hue within 1°), `testInvalidHexIsNil` (`"#12"`, `"zz0000"`).
- [ ] **Step 2: Run** `scripts/test.sh --filter PaletteColorTests` — expect FAIL (type missing).
- [ ] **Step 3: Implement** with the standard OKLab matrices (Björn Ottosson) and sRGB transfer function.
- [ ] **Step 4: Run** the same filter — expect PASS.
- [ ] **Step 5: Commit** `feat(theme): palette colour math in Core`.

### Task 2: The `simple` block on ThemeDefinition

**Files:**
- Create: `Sources/CrateDiggerCore/Models/SimpleThemeRecipe.swift`
- Modify: `Sources/CrateDiggerCore/Models/ThemeDefinition.swift` (add field + init param, default nil)
- Test: `Tests/CrateDiggerCoreTests/SimpleThemeDefinitionTests.swift`

**Interfaces:**
- Produces:
  - `public enum ThemeJob: String, Codable, CaseIterable, Sendable { case frame, panels, text, accent, glass, screenText }` with `var label: String` ("Frame", "Panels", "Text", "Accent", "Screen Glass", "Screen Text").
  - `public enum SimpleContrast: String, Codable, CaseIterable, Sendable { case soft, standard, high }`.
  - `public struct SimpleThemeRecipe: Codable, Equatable, Sendable { var palette: [String]; var pins: [ThemeJob: Int]; var assignment: [ThemeJob: Int?]; var contrast: SimpleContrast; var recipe: Int }`. Encodes `pins`/`assignment` as JSON objects keyed by job raw value; a `nil` assignment encodes as JSON `null`.
  - `func sanitized() -> SimpleThemeRecipe?` — nil when fewer than 2 valid hex colours; drops invalid hex, truncates to 6, drops pins/assignment indices out of range.
  - `ThemeDefinition.simple: SimpleThemeRecipe?` and `var isSimple: Bool { simple != nil }`.

- [ ] **Step 1: Failing tests** — `testRoundTripPreservesBlock`, `testOldFileWithoutBlockDecodes` (decode `Carbon.cdtheme/theme.json` from the source tree; `simple == nil`), `testMinimizedKeepsBlock` (`ThemeAuthoringService.minimized(def, against: parent).simple == def.simple`), `testMalformedBlockIsSanitized` (1 colour → nil; 7 colours → 6; pin index 9 dropped; `"#zz"` dropped), `testNullAssignmentRoundTrips`.
- [ ] **Step 2: Run** `scripts/test.sh --filter SimpleThemeDefinitionTests` — FAIL.
- [ ] **Step 3: Implement**; the decoder of `ThemeDefinition` must not fail on a malformed block — decode it with `try?` and store `sanitized()`.
- [ ] **Step 4: Run** the filter plus `ThemeDefinitionTests ThemeLoaderServiceTests ThemeAuthoringServiceTests` — PASS.
- [ ] **Step 5: Commit** `feat(theme): Simple recipe block on theme definitions`.

### Task 3: The recipe table and contrast enforcement

**Files:**
- Create: `Sources/CrateDiggerCore/Services/ThemePalette/SimplePaletteRecipe.swift` (the transform types and `tokens(...)`)
- Create: `Sources/CrateDiggerCore/Services/ThemePalette/SimplePaletteRecipeTable.swift` (the data: one table per appearance)
- Create: `Sources/CrateDiggerCore/Services/ThemePalette/ContrastFloors.swift`
- Test: `Tests/CrateDiggerCoreTests/SimplePaletteRecipeTests.swift`

**Interfaces:**
- Consumes: `PaletteColor`, `OKLCH`, `ThemeJob`, `SimpleContrast` (Tasks 1–2).
- Produces:
  - `public enum SimplePaletteRecipe { static let currentVersion = 1; static func tokens(jobColors: [ThemeJob: PaletteColor], contrast: SimpleContrast, appearance: ThemeDefinition.BaseAppearance) -> [String: String] }` — `jobColors` has all six jobs filled (the assigner derives missing ones, Task 4).
  - `public enum ContrastFloors { static func pairs(contrast: SimpleContrast) -> [(foreground: String, background: String, minimum: Double)]; static func enforce(_ tokens: [String: String], contrast: SimpleContrast) -> [String: String] }` — moves the foreground's OKLCH lightness away from the background until the floor holds; if L hits 0 or 1, moves the background's lightness the other way.
  - `public static let simpleWrittenTokens: Set<String>` (on `SimplePaletteRecipe`) — exactly the keys `tokens` returns.

**How to build the table (the implementer decides the numbers, within these rules):** For each colour token in `ThemeTokenCatalog.colorGroups` that is not an optional override, pick the job it derives from and record `ΔL`, chroma scale and alpha by measuring Carbon's own dark tokens (from `Sources/CrateDiggerApp/Resources/Themes/Carbon.cdtheme/theme.json` dark layer plus `CarbonTheme.carbon`) against Carbon's own job colours, and likewise for light (`light` layer plus `CarbonTheme.linen`). Write lightness as a target relative to the job colour's lightness in the matching appearance. A job colour whose lightness fits the appearance's range for that job is used exactly (ΔL 0 for the job's anchor token: `chassis`, `paper`, `ink`, `orange`, `oledSurface`, `oledForeground`); otherwise its hue and chroma are kept at the table's lightness. Meaning colours (`red`, `sun*`, `cyan*`, `indigo`) keep Carbon's hue ±20° and take lightness from the background. `selectionInk`'s background is whatever `CarbonTheme` actually fills a selected row with — read `CarbonViewHelpers.swift` to find it.

- [ ] **Step 1: Failing tests** —
  - `testCarbonJobsReproduceCarbonAnchors`: feeding Carbon's own six dark job colours gives `chassis`, `paper`, `ink`, `orange`, `oledSurface`, `oledForeground` equal to Carbon's (exact hex); same for light.
  - `testCarbonJobsCloseToCarbonEverywhere`: every written token within OKLab distance 0.06 of Carbon's.
  - `testFloorsHoldForSeededPalettes`: 500 seeded random job sets × both appearances × 3 contrasts → every `ContrastFloors.pairs` ratio ≥ minimum.
  - `testHostileNearIdenticalPalette`, `testHostileBlackWhite`, `testHostileNeon`: floors hold; `chassis` and `paper` OKLab distance ≥ 0.04.
  - `testMeaningColoursKeepHue`: `red` hue within ±20° of Carbon's `red` for any input.
  - `testNoOverrideTokensWritten`: no key ending in a lamp name, `transportLamp`, or listed as optional override.
  - `testDeterministic`: same inputs → identical dictionary.
- [ ] **Step 2: Run** `scripts/test.sh --filter SimplePaletteRecipeTests` — FAIL.
- [ ] **Step 3: Implement** the transforms, the two tables and `enforce`.
- [ ] **Step 4: Run** — PASS. Also add to `Tests/CrateDiggerAppTests/` a `SimpleRecipeCatalogTests.testEveryWrittenTokenIsInCatalog` asserting `SimplePaletteRecipe.simpleWrittenTokens ⊆ Set(ThemeTokenCatalog.allColorTokens.map(\.key))`.
- [ ] **Step 5: Commit** `feat(theme): Simple recipe table with contrast floors`.

### Task 4: Assignments, Shuffle and extraction

**Files:**
- Create: `Sources/CrateDiggerCore/Services/ThemePalette/SimplePaletteAssigner.swift`
- Create: `Sources/CrateDiggerCore/Services/ThemePalette/SimplePaletteExtractor.swift`
- Test: `Tests/CrateDiggerCoreTests/SimplePaletteAssignerTests.swift`, `Tests/CrateDiggerCoreTests/SimplePaletteExtractorTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces:
  - `public typealias JobAssignment = [ThemeJob: Int?]` (nil = derived).
  - `public enum SimplePaletteAssigner`:
    - `static func validAssignments(palette: [PaletteColor], pins: [ThemeJob: Int]) -> [JobAssignment]` — deterministic order, best first; every result honours pins; Frame and Panels differ by ≥ 0.08 OKLCH L (or one is derived); Accent is the highest-chroma assigned colour unless pinned; with 2 colours `text` and `screenText` may be nil.
    - `static func initial(palette:pins:) -> JobAssignment` = first valid.
    - `static func shuffled(after current: JobAssignment, palette:, pins:) -> JobAssignment` — the next valid assignment after `current` in the list, wrapping; returns `current` when it is the only one.
    - `static func jobColors(palette: [PaletteColor], assignment: JobAssignment, appearance:) -> [ThemeJob: PaletteColor]` — fills nil jobs: `text`/`screenText` as tinted neutrals of `frame`/`glass` hue, any other nil job from the nearest assigned job.
    - `static func sanitize(pins:assignment:paletteCount:) -> (pins, assignment)` drops indices ≥ count.
  - `public enum SimplePaletteExtractor { static func recipe(from definition: ThemeDefinition, resolvedBase: [String: String]) -> SimpleThemeRecipe }` — reads the six anchor tokens from the definition's dark and light layers (or shared colours), falling back to `resolvedBase`; merges colours closer than OKLab 0.03; keeps ≤ 6 (drop the least-used); pins every job to its colour; `contrast = .standard`; `recipe = SimplePaletteRecipe.currentVersion`.

- [ ] **Step 1: Failing tests** — `testPinsHonoured` (every valid assignment keeps pins), `testShuffleCyclesAndWraps`, `testShuffleNeverChangesPinnedJob`, `testTwoColoursDeriveText`, `testSixColoursCanFillEveryJob`, `testPinToRemovedIndexIsDropped`, `testExtractCarbonPinsSixJobs` (Carbon JSON → recipe with every job pinned, ≤ 6 colours), `testExtractMergesNearDuplicates`, `testExtractedCarbonRebuildsAnchors` (extract → jobColors → `SimplePaletteRecipe.tokens` reproduces Carbon's six dark anchors within OKLab 0.02).
- [ ] **Step 2: Run** `scripts/test.sh --filter SimplePaletteAssignerTests` and `SimplePaletteExtractorTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(theme): Simple assignments, Shuffle and palette extraction`.

### Task 5: Simple state, history, fonts, mode rules and theme assembly

**Files:**
- Create: `Sources/CrateDiggerCore/Services/ThemePalette/SimpleThemeState.swift` (state + history)
- Create: `Sources/CrateDiggerCore/Services/ThemePalette/SimpleThemeBuilder.swift`
- Create: `Sources/CrateDiggerCore/Services/ThemePalette/SimpleFontPresets.swift`
- Create: `Sources/CrateDiggerCore/Services/ThemePalette/ThemeEditorModeRules.swift`
- Test: `Tests/CrateDiggerCoreTests/SimpleThemeHistoryTests.swift`, `SimpleThemeBuilderTests.swift`, `ThemeEditorModeRulesTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4, `ShellMaterial`, `CoverScreenLook`.
- Produces:
  - `public struct SimpleThemeState: Equatable, Sendable { var palette: [String]; var pins: [ThemeJob: Int]; var assignment: JobAssignment; var contrast: SimpleContrast }`, `init(recipe:)`, `var recipe: SimpleThemeRecipe`, mutators that keep it valid: `addColor(_:)`, `removeColor(at:)` (sanitizes pins/assignment and re-validates the assignment), `setColor(_:at:)`, `pin(_:to:)`, `unpin(_:)`, `shuffle()`.
  - `public struct SimpleThemeHistory: Sendable { init(_ first: SimpleThemeState); private(set) var current: SimpleThemeState; var canGoBack: Bool; var canGoForward: Bool; mutating func push(_:); mutating func back(); mutating func forward() }` — capacity 20; push after back truncates the forward branch; pushing an equal state is a no-op.
  - `public enum SimpleAppearanceMode: String, CaseIterable { case light, dark, both }`.
  - `public struct SimpleThemeChoices: Equatable, Sendable { var appearance: SimpleAppearanceMode; var material: ShellMaterial?; var coverLook: CoverScreenLook?; var fonts: [String: ThemeFont] }` (`fonts` keyed `display`/`mono`/`sans`).
  - `public enum SimpleThemeBuilder { static func build(state: SimpleThemeState, choices: SimpleThemeChoices, onto base: ThemeDefinition) -> ThemeDefinition }` — returns `base` with: `simple` = state's recipe; colours written via recipe for the chosen appearance(s) (`both` → `light` and `dark` variants hold the tokens, shared `colors` untouched except removing keys Simple owns; single → shared `colors`, both variants nil, `baseAppearance` set); `fonts` merged; all five shell keys set (chosen = its Simple strength, others 0) or all 0 for nil; all three cover keys likewise (chosen 0.55, `coverPixelSize` 1.5). Everything else on `base` untouched.
  - `public enum SimpleFontPresets { static let screenTitles, labels, interface: [SimpleFontPreset] }` with `public struct SimpleFontPreset: Identifiable { let id: String; let label: String; let font: ThemeFont }` — the 15 presets of the spec table (bundled faces with every bundled weight named; macOS faces by PostScript name, e.g. `Futura-Medium`, `DINCondensed-Bold`, `AvenirNext-UltraLight`, `SFMono-Regular`, `Menlo-Regular`, `AndaleMono`, `AvenirNext-Regular`, `HelveticaNeue`, `GillSans`; SF Pro as `.AppleSystemUIFont`).
  - `public enum ThemeEditorModeRules { enum Mode { case simple, advanced }; enum Crossing { case copy, convert, cancel }; static func crossings(from: Mode, isBuiltIn: Bool) -> [Crossing] }` — simple→advanced: `[.copy, .convert, .cancel]`; advanced→simple: `[.copy, .cancel]`; `static func mode(of: ThemeDefinition) -> Mode`.

- [ ] **Step 1: Failing tests** — history: `testCapacity20`, `testBackForwardReturnExactStates`, `testPushAfterBackDropsForward`, `testRemovingPinnedSwatch` (state after `removeColor` has no stale index and `back()` restores the swatch and pin); builder: `testBothWritesBothLayersAndKeepsBaseEffects` (build onto Pocket JSON → `oledMonochrome` still 1, `light`/`dark` non-nil), `testSingleAppearanceClearsLayers`, `testMaterialIsExclusive` (only chosen key non-zero), `testCoverLookIsExclusive`, `testBuildIsDeterministic`, `testContrastFloorsHoldOnBuiltTheme` (flatten each appearance and check pairs); mode rules: the two crossing lists.
- [ ] **Step 2: Run** the three filters — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS, and the whole Core suite once.
- [ ] **Step 5: Commit** `feat(theme): Simple state, history, presets and theme assembly`.

### Task 6: Registry support (app)

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Theme/ThemeRegistry.swift`
- Test: `Tests/CrateDiggerAppTests/SimpleThemeRegistryTests.swift` (follow `ThemeDraftSaveTests` for a temp themes folder)

**Interfaces:**
- Consumes: Tasks 2, 5.
- Produces on `ThemeRegistry`:
  - `func previewTheme(for definition: ThemeDefinition, appearance: ThemeDefinition.BaseAppearance) -> (theme: CarbonTheme, geometry: CarbonGeometry)` — resolves `inherits` the way installed themes are resolved (use the loader's inheritance resolution against `manifests`), then `flatten` + `rendered` (no logo needed).
  - `func newSimpleSeed(from manifest: ThemeManifest) -> ThemeDefinition` — a fresh unsaved definition: new unique id/name ("New Theme", "New Theme 2"…), `inherits = manifest.id`, author/version nil, `simple` = `SimplePaletteExtractor.recipe(...)`, fonts/effects/appearance copied (adaptive original → both layers).
  - `func applySimple(_ definition: ThemeDefinition) throws -> String?` — sets `draft`/`draftSeed` to it and calls `saveDraft()` (so it is minimized against its parent, saved and selected).
  - `func convertDraftToAdvanced()` — removes `draft.simple` (one undo step).
  - `func beginAdvancedCopy(of definition: ThemeDefinition)` — like `duplicateDraft` but from a given definition with `simple = nil`.
- [ ] **Step 1: Failing tests** — `testApplySimpleSavesAndSelects`, `testApplySimpleKeepsBlockOnDisk`, `testNewSeedInheritsFromOriginal`, `testNewSeedFromAdaptiveIsBoth`, `testConvertDropsBlockKeepsTokens`, `testPreviewThemeUsesDraftColours` (accent hex in → `theme.orange` matches).
- [ ] **Step 2: Run** `scripts/test.sh --filter SimpleThemeRegistryTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** plus all `Theme*` App tests — PASS.
- [ ] **Step 5: Commit** `feat(theme): registry support for Simple themes`.

### Task 7: `SimpleThemeEditor` model (app)

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/Sheets/ThemeEditor/SimpleThemeEditor.swift`
- Test: `Tests/CrateDiggerAppTests/SimpleThemeEditorTests.swift`

**Interfaces:**
- Consumes: Tasks 5, 6.
- Produces: `@MainActor final class SimpleThemeEditor: ObservableObject` with
  - `@Published private(set) var history: SimpleThemeHistory`, `@Published var choices: SimpleThemeChoices`, `@Published var name: String`, `@Published var highlightedJobs: Set<ThemeJob>` (hover), `@Published private(set) var hasUnappliedChanges: Bool`, `@Published var previewAppearance: ThemeDefinition.BaseAppearance`.
  - `private(set) var base: ThemeDefinition` (the seed the candidate is built onto), `var candidate: ThemeDefinition` (= `SimpleThemeBuilder.build`), `var isReopenedSaved: Bool`, `var needsRegenerateWarning: Bool` (true until the first palette change or Shuffle after reopening a saved Simple theme).
  - `init(newFrom manifest: ThemeManifest, registry: ThemeRegistry)`, `init(reopening manifest: ThemeManifest, registry:)`, `init(copyOf definition: ThemeDefinition, registry:)`.
  - `func edit(_ change: (inout SimpleThemeState) -> Void)` (pushes history), `back()`, `forward()`, `shuffle()`, `apply() throws`, `discard()`, `func jobs(forSwatch index: Int) -> [ThemeJob]`.
  - Reopened saved theme: the candidate shows the saved tokens until the first palette change/Shuffle; `needsRegenerateWarning` gates that first change (the view asks, then calls `confirmRegenerate()`).
- [ ] **Step 1: Failing tests** — `testShuffleKeepsContrastFontsMaterial`, `testBackUndoesColourEdit`, `testApplyWritesAndClearsUnapplied`, `testCloseWithUnappliedAsks` (`hasUnappliedChanges` true after an edit, false after apply/discard), `testReopenNeedsWarningOnce`, `testJobsForSwatch`.
- [ ] **Step 2–4:** run FAIL, implement, run PASS (`--filter SimpleThemeEditorTests`).
- [ ] **Step 5: Commit** `feat(theme): Simple editor model`.

### Task 8: The illustrated preview (Real Hardware drawing)

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/Sheets/ThemeEditor/ThemePreviewIllustration.swift` (three screens)
- Create: `Sources/CrateDiggerApp/UI/Carbon/Sheets/ThemeEditor/ThemePreviewCover.swift` (renders the sample cover through Core)
- Modify: `Package.swift` only if `StarterCrate/cover.png` is not already a processed resource.

**Interfaces:**
- Consumes: `ThemeRegistry.previewTheme` (Task 6), `ThemeJob`, `CoverScreenLayout.plan`, `CoverScreenRenderer.render`, `CoverScreenLook.resolve`.
- Produces: `struct ThemePreviewIllustration: View { init(theme: CarbonTheme, effects: [String: Double], highlighted: Set<ThemeJob>, screens: Set<PreviewScreen>) }` with `enum PreviewScreen { case fullWindow, mini, compact }`; modifier `.previewJob(_ job: ThemeJob, highlighted: Set<ThemeJob>)` dims a shape to 0.16 opacity when `highlighted` is non-empty and lacks `job`.

**Drawing:** Follow `.superpowers/brainstorm/78030-1795357950/content/preview-styles-v3.html` (in the main checkout, `/Volumes/EX_3/Code/CrateDigger/.superpowers/...`) for composition and proportions: full window 600×400, mini 200×350, compact 470×150, footer order as today (do *not* adopt the mockup's volume-left order). Style: "Real Hardware" — today's console simplified: chassis with a top highlight and bottom shadow line (`chassisHi`/`chassisLo`), recessed wells (`well`, `wellDeep` inner edge), paper list panels with text as rounded bars in `ink`/`ink3`, keys as `metal` faces with `metalHi`/`metalLo` edges and `chassisInk` print, silicone transport caps lit by the accent, the display as `oledSurface` glass with cells and text drawn in the theme's display/mono fonts in `oledForeground`. Shell material: a flat tint hint only. Album art (mini and compact only, never the full window's inspector): render `StarterCrate/cover.png` with the theme's resolved cover look at the screen's real point size and backing scale off the main thread, cached by (look, strength, pixel size, side, scale); plain cover when no look. Every shape carries its job.

- [ ] **Step 1:** Implement; add a SwiftUI `#Preview` with Carbon, Llama '97 and Pocket.
- [ ] **Step 2:** `swift build` — succeeds.
- [ ] **Step 3: Commit** `feat(theme): illustrated theme preview`.

(Visual sign-off happens in Task 10 from real captures.)

### Task 9: Panel UI — modes, Simple controls, NEW, crossings, Advanced PREVIEW

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/Sheets/ThemeEditor/SimpleThemePanel.swift`
- Create: `Sources/CrateDiggerApp/UI/Carbon/Sheets/ThemeEditor/PaletteSwatchRow.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Sheets/ThemeEditorView.swift` (mode switch in `identityBar`, NEW key, PREVIEW key in `actionBar`; doc comment updated: Advanced still previews live, Simple uses the illustration)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Inspector/ThemePickerPane.swift` (NEW key beside EDITOR)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/CarbonRootView.swift` (panel sizes: allow up to 1000 wide; Simple asks for ~860×640 when it opens)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` (`themeEditorStartsNew: Bool` flag beside `showingThemeEditor`)
- Modify: `Sources/CrateDiggerApp/AppDelegate.swift` (DEBUG hook: `CRATEDIGGER_THEME_EDITOR=simple` opens NEW; `=simple-preview` also opens with Pocket-like palette; `=advanced-preview` opens Advanced with PREVIEW shown)

**Behaviour (from the spec, nothing new):**
- SIMPLE / ADVANCED switch at the top. Pressing the other mode runs `ThemeEditorModeRules.crossings` and shows an in-panel confirm (not an NSAlert) with those buttons and the copy "A converted theme can't go back to Simple."
- Simple column order: palette row (2–6 swatches, hex field, colour picker, +, ×, job labels under each, hover → `highlightedJobs`), pins (pin icon → job menu), SHUFFLE with ← →, CONTRAST (Soft/Standard/High), APPEARANCE (Light/Dark/Both), MATERIAL (None/Grain/Plastic/Brushed/Blasted/Weave), ALBUM ART (Off/LCD Grid/Pixel LCD/Handheld LCD), three font preset rows (+ Custom chip when current font isn't a preset; the Labels row notes it also sets the small headings), name field, APPLY. Preview on the right with a Light/Dark toggle for Both.
- UNDO is hidden in Simple; Advanced keeps UNDO.
- Closing the panel with `hasUnappliedChanges` → in-panel Apply / Discard.
- Reopened saved Simple theme: first palette change or Shuffle → in-panel "Regenerate this theme? Its colours may change slightly." Regenerate / Cancel.
- NEW (picker and identity bar) → `SimpleThemeEditor(newFrom: current manifest)`; if an Advanced draft has unsaved changes, ask first (Save / Discard / Cancel).
- Advanced PREVIEW key toggles a side area showing `ThemePreviewIllustration(screens: [.mini, .compact])` of the live draft.
- Keyboard: ← / → step history when no text field is focused.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** `swift build` and the full App test suite — pass.
- [ ] **Step 3: Commit** `feat(theme): Simple and Advanced editor modes`.

### Task 10: Real-app verification and docs

**Files:**
- Modify: `CLAUDE.md` (UI section: a "Theme editor: Simple and Advanced" paragraph — where the logic lives, the `simple` block, preview rule, debug hooks)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Sheets/WhatsNewView.swift` only if it describes the editor flow (keep it accurate)

- [ ] **Step 1:** Launch the debug build isolated (`CRATEDIGGER_CRATES_DIR=<scratch>`, `CRATEDIGGER_THEME_EDITOR=simple`), capture the window with `screencapture -l`, and check: preview colours match Apply's real result; hover dims; Shuffle changes only assignment; ← undoes; Contrast High visibly raises text contrast; Both shows both layers; material/cover look rows work; album art is pixel-true; font presets render.
- [ ] **Step 2:** Apply, then capture the real app in the new theme (full, compact via `CRATEDIGGER_COMPACT=1`, mini via `CRATEDIGGER_MINI=1` with `CRATEDIGGER_COVER`), compare against the preview.
- [ ] **Step 3:** Advanced: PREVIEW panel, crossings both ways, NEW from a built-in.
- [ ] **Step 4:** Fix what the captures show; full `scripts/test.sh` green.
- [ ] **Step 5: Commit** `docs(theme): Simple and Advanced editor in CLAUDE.md` (plus any fixes as their own commits).
