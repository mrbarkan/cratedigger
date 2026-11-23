# Interface Styles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Four interface styles (Real Hardware, Flat Hardware, Soft Blocks, Sticker), one per theme and travelling with it, drawn by the shared Carbon primitives; Llama '97 and Pocket wear Flat Hardware, Llama '97 light is recoloured, and a new built-in theme, Funhouse, wears Sticker.

**Architecture:** Core gets an `InterfaceStyle` enum and an optional top-level `ThemeDefinition.style` (lenient, inherited, encoded only when set), plus the pure rules (Soft separation, which shadows a style casts). The app resolves the active theme's style once in `CarbonThemed` into `\.interfaceStyle`, and each shared primitive branches on it internally, keeping Real Hardware's existing code path untouched. Layout, sizes, the display and content (art, photos) never read the style.

**Tech Stack:** Swift, SwiftUI, AppKit, XCTest via `scripts/test.sh`.

**Spec:** `docs/superpowers/specs/2026-11-23-interface-styles-design.md` (approved 2026-11-23). Reference material beside it in `docs/superpowers/specs/2026-11-23-interface-styles-themes/`: `spike.patch` (the throwaway spike's drawing code, the starting numbers for Flat Hardware, Soft Blocks and Sticker), `funhouse.theme.json`, `llama-97.theme.json` (take values, not formatting), `winid.swift` (lists a process's windows for `screencapture -l`).

## Global Constraints

- Branch `feat/interface-styles` off `v2.4` (worktree `.claude/worktrees/interface-styles`). Commit per task; do not push.
- Style raw values, exactly: `hardware`, `flatHardware`, `softBlocks`, `sticker`. Absent or unknown → Real Hardware; an unknown value never fails a theme's decode.
- Corner multipliers: Real 1, Flat Hardware 1.4, Soft Blocks 2.0, Sticker 1.35, applied inside the primitives to `keyCornerRadius`, `wellCornerRadius`, `paperCornerRadius`, clamped to `CarbonGeometry.Bounds.cornerRadius`. Never written into the environment's `CarbonGeometry`; the editor shows the theme's own values.
- Press: Flat Hardware moves the cap down by its base depth (3 pt on chassis keys); Soft Blocks scales to 0.95 with `CarbonMotion.softPress` (`.spring(response: 0.18, dampingFraction: 0.55)`), a quick ease under Reduce Motion; Sticker moves by its shadow offset onto the shadow. Real keeps today's press.
- `stickerInk` fallback: light `ink` at 0.9; dark `chassisInk` at 0.85.
- Real Hardware must render pixel-identical to `v2.4` (Carbon and Cobalt in every layout). No style code path runs for it.
- No live blurs, no Materials, nothing per frame, nothing on the browser lists. Colour maths happens once per theme change, never in a primitive's `body`.
- The display (OLED glass, LED matrix, Busy Signals, cover screen LCD and `CoverScreenBezel`), album art, artist photos and the booklet/artwork viewers draw identically in every style, shadows and corners included.
- Launch the app only isolated: a renamed copy of the binary, scratch `CRATEDIGGER_CRATES_DIR` and `CFFIXED_USER_HOME`, its own defaults domain, `~/Library/Preferences/CrateDiggerApp.plist` checksummed before and after.

## Review Focus

1. A theme saved by a newer build with `"style": "neon"`: loads, renders as Real Hardware, keeps every other field (Task 1 test).
2. A user theme that `inherits` Llama '97 and sets no style: wears Flat Hardware; choosing Real Hardware for it in Advanced must write `"style": "hardware"` explicitly, or it silently stays Flat (Task 1 test of `settingStyle`).
3. A theme with FLAT on, switched to Sticker and back to Real: FLAT is still on and still works; in Sticker the art and display keep their shadows (Task 2 test of `castsContentShadows`, Task 5 call-site split).
4. Starting a Simple theme from Funhouse or Llama '97: the new theme keeps the original's style; an untouched Simple theme re-saved stays byte-identical (Task 3 tests).
5. Reduce Motion on, Soft Blocks key pressed: no spring, a quick ease; Flat and Sticker offsets still show (Task 7 manual check, recorded in the commit message).

---

### Task 0: Capture tool and Real Hardware baseline

**Files:**
- Create: `scripts/style-capture.sh`, `scripts/winid.swift` (copy of the reference `winid.swift`)

- [ ] **Step 1: Write `scripts/style-capture.sh <theme-id> <light|dark> <full|compact|mini> <out.png>`**

Behaviour (port of the spike's script, minus personal paths):
- Refuses unless `$SCRATCH` is set and outside `/Volumes`; builds nothing itself.
- Copies `.build/debug/CrateDiggerApp` to `$SCRATCH/CDStyleCapture`, fresh `$SCRATCH/crates` (from `$DEMO_LIBRARY` if set, else empty) and `$SCRATCH/home`.
- Writes only the `CDStyleCapture` defaults domain: `cratedigger.onboarding.completed` true, `cratedigger.onboarding.tourSeen` true, `cratedigger.onboarding.whatsNewVersion` `2.4.0`, `CrateDigger.appearanceMode`, `cratedigger.ui.selectedThemeID`.
- Passes `CRATEDIGGER_STYLE` through if set; compact adds `CRATEDIGGER_COMPACT=1`, mini `CRATEDIGGER_MINI=1`, both add `CRATEDIGGER_COVER=$COVER` when set and `CRATEDIGGER_SNAPSHOT_PATH=$SCRATCH/snap.png`.
- Waits 9 s, captures the largest layer-0 window (mini: the small one) via `swift scripts/winid.swift CDStyleCapture` and `screencapture -l <id> -o`, then kills the copy.
- Checksums `~/Library/Preferences/CrateDiggerApp.plist` before and after and exits non-zero with `PREFS CHANGED` if they differ.

- [ ] **Step 2: Build `v2.4` as it stands and capture the baseline**

Run: `swift build && for t in carbon cobalt; do for m in light dark; do for l in full compact mini; do scripts/style-capture.sh $t $m $l "$SCRATCH/baseline/$t-$m-$l.png"; done; done; done`
Expected: 12 PNGs, no `PREFS CHANGED`.

- [ ] **Step 3: Write `scripts/style-compare.sh <a.png> <b.png>`**

Masks the display (the OLED rectangle in full and compact; the art and display in mini, read from the window size) and the titlebar status LED, then prints the count of differing pixels (ffmpeg `blend=difference`, threshold 0). Exit 0 only at 0 differing pixels. Check it on two baseline captures of the same theme taken back to back: expect 0.

- [ ] **Step 4: Commit**

```bash
git add scripts/style-capture.sh scripts/style-compare.sh scripts/winid.swift
git commit -m "chore(scripts): isolated window capture and compare for interface styles"
```

### Task 1: `InterfaceStyle` and `ThemeDefinition.style` (Core)

**Files:**
- Create: `Sources/CrateDiggerCore/Models/InterfaceStyle.swift`
- Modify: `Sources/CrateDiggerCore/Models/ThemeDefinition.swift` (property, init parameter, lenient decode), `Sources/CrateDiggerCore/Services/ThemeLoaderService.swift` (`merge`)
- Test: `Tests/CrateDiggerCoreTests/InterfaceStyleTests.swift`

**Interfaces:**
- Produces:
  - `public enum InterfaceStyle: String, Codable, CaseIterable, Sendable { case hardware, flatHardware, softBlocks, sticker }`
  - `var displayName: String` → "Real Hardware", "Flat Hardware", "Soft Blocks", "Sticker"
  - `var radiusScale: Double` → 1, 1.4, 2.0, 1.35
  - `ThemeDefinition.style: InterfaceStyle?` (init parameter `style: InterfaceStyle? = nil`, last)
  - `ThemeDefinition.resolvedStyle: InterfaceStyle` (`style ?? .hardware`)
  - `func settingStyle(_ style: InterfaceStyle) -> ThemeDefinition`: writes `nil` for `.hardware` when `inherits == nil`, the value otherwise

- [ ] **Step 1: Write the failing tests**

```swift
func testAbsentStyleIsRealHardwareAndIsNotEncoded() throws {
    let json = #"{"id":"t","name":"T","baseAppearance":"dark"}"#
    let def = try JSONDecoder().decode(ThemeDefinition.self, from: Data(json.utf8))
    XCTAssertNil(def.style); XCTAssertEqual(def.resolvedStyle, .hardware)
    let out = String(decoding: try JSONEncoder().encode(def), as: UTF8.self)
    XCTAssertFalse(out.contains("style"))
}
func testUnknownStyleReadsAsRealHardwareAndKeepsTheTheme() throws {
    let json = #"{"id":"t","name":"T","baseAppearance":"dark","style":"neon","colors":{"ink":"#FFFFFF"}}"#
    let def = try JSONDecoder().decode(ThemeDefinition.self, from: Data(json.utf8))
    XCTAssertEqual(def.resolvedStyle, .hardware); XCTAssertEqual(def.colors?["ink"], "#FFFFFF")
}
func testStyleRoundTrips() // each case encodes as its raw value and decodes back
func testChildInheritsParentStyleUnlessItSetsOne() // via ThemeLoaderService with a temp themes folder: parent flatHardware; child without style → flatHardware; child with sticker → sticker
func testSettingRealOnAnInheritingThemeIsExplicit() {
    let child = ThemeDefinition(id: "c", name: "C", baseAppearance: .dark, inherits: "llama-97")
    XCTAssertEqual(child.settingStyle(.hardware).style, .hardware)
    let root = ThemeDefinition(id: "r", name: "R", baseAppearance: .dark, style: .sticker)
    XCTAssertNil(root.settingStyle(.hardware).style)
}
func testRadiusScales() { XCTAssertEqual(InterfaceStyle.allCases.map(\.radiusScale), [1, 1.4, 2.0, 1.35]) }
```

- [ ] **Step 2: Run** `scripts/test.sh --filter InterfaceStyleTests` — Expected: FAIL (no `InterfaceStyle`).

- [ ] **Step 3: Implement.** Decode with `style = try? c.decodeIfPresent(InterfaceStyle.self, forKey: .style) ?? nil` (lenient like `simple`); encoding stays synthesised. In `merge`, `style: override.style ?? base.style`.

- [ ] **Step 4: Run** `scripts/test.sh --filter "InterfaceStyleTests|ThemeDefinitionTests|ThemeLoaderServiceTests"` — Expected: PASS.

- [ ] **Step 5: Commit** `feat(themes): interface style in the theme definition`

### Task 2: Style rules in Core (shadows, Soft separation)

**Files:**
- Modify: `Sources/CrateDiggerCore/Models/InterfaceStyle.swift`
- Create: `Sources/CrateDiggerCore/Services/ThemePalette/SoftSeparation.swift`
- Test: `Tests/CrateDiggerCoreTests/InterfaceStyleRulesTests.swift`

**Interfaces:**
- Produces:
  - `InterfaceStyle.honoursFlatSwitch: Bool` (true for `.hardware` only)
  - `InterfaceStyle.castsContentShadows(flatSwitchOn: Bool) -> Bool` (`.hardware`: `!flatSwitchOn`; others: true)
  - `enum SoftSeparation { static let minimumContrast: Double = 1.12; static func separated(_ fill: PaletteColor, on surface: PaletteColor) -> PaletteColor }`

- [ ] **Step 1: Write the failing tests**

```swift
func testFlatSwitchOnlyReachesRealHardware() {
    XCTAssertFalse(InterfaceStyle.hardware.castsContentShadows(flatSwitchOn: true))
    for s in [InterfaceStyle.flatHardware, .softBlocks, .sticker] {
        XCTAssertTrue(s.castsContentShadows(flatSwitchOn: true)); XCTAssertFalse(s.honoursFlatSwitch)
    }
}
func testNearIdenticalPairIsPushedApartAwayFromTheSurface() {
    let key = PaletteColor(hex: "#C4C4C4")!, caseColor = PaletteColor(hex: "#C0C0C0")!
    let out = SoftSeparation.separated(key, on: caseColor)
    XCTAssertGreaterThanOrEqual(PaletteColor.contrast(out, caseColor), SoftSeparation.minimumContrast)
    XCTAssertGreaterThan(out.relativeLuminance, key.relativeLuminance) // key was lighter, moves lighter
}
func testDistinctPairIsUntouched() {
    let metal = PaletteColor(hex: "#33415A")!, chassis = PaletteColor(hex: "#18212F")! // Cobalt dark
    XCTAssertEqual(SoftSeparation.separated(metal, on: chassis), metal)
}
func testDarkerFillOnPaleSurfaceMovesDarker() // Pocket light: #CFCBC4 on #C9C6BE → lighter; #B8B5AD on #C9C6BE → darker
```

- [ ] **Step 2: Run** `scripts/test.sh --filter InterfaceStyleRulesTests` — Expected: FAIL.

- [ ] **Step 3: Implement `separated`.** If `contrast(fill, surface) >= minimumContrast`, return `fill`. Otherwise move `fill` toward white if its luminance ≥ the surface's, else toward black, mixing in steps of 0.02 up to 0.30 until the contrast reaches the minimum; return the last step. Use `PaletteColor`'s existing `contrast`; add `relativeLuminance` as public if it is not already (it is what `contrast` computes).

- [ ] **Step 4: Run** the filter again — Expected: PASS.

- [ ] **Step 5: Commit** `feat(themes): which shadows a style casts, Soft Blocks separation`

### Task 3: Simple editor carries the style (Core)

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/ThemePalette/SimpleThemeBuilder.swift` (`SimpleThemeChoices`, `seed`, `build`)
- Test: `Tests/CrateDiggerCoreTests/SimpleThemeBuilderTests.swift`

**Interfaces:**
- Produces: `SimpleThemeChoices.style: InterfaceStyle` (init parameter `style: InterfaceStyle = .hardware`, last).

- [ ] **Step 1: Write the failing tests** `testSeedKeepsTheOriginalsStyle` (seed from a `.sticker` definition → seed `.style == .sticker`), `testBuildWritesTheChosenStyle` (choices `.flatHardware` → `.flatHardware`; choices `.hardware` → `nil`, since a Simple theme has no parent), `testUntouchedSimpleThemeRebuildsByteIdentical` (a Simple theme with no `style`, rebuilt with the same choices and `style: .hardware`, encodes to the same bytes).

- [ ] **Step 2: Run** `scripts/test.sh --filter SimpleThemeBuilderTests` — Expected: FAIL.

- [ ] **Step 3: Implement.** `seed` copies `original.style`; `build` sets `theme = theme.settingStyle(choices.style)` after `theme.inherits = nil`.

- [ ] **Step 4: Run** the filter — Expected: PASS.

- [ ] **Step 5: Commit** `feat(themes): Simple themes keep and choose a style`

### Task 4: Delivery and tokens (App)

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Theme/Environment+Theme.swift`, `Sources/CrateDiggerApp/UI/Theme/CarbonTheme.swift`, `Sources/CrateDiggerApp/UI/Theme/CarbonGeometry.swift`, `Sources/CrateDiggerApp/UI/Theme/CarbonMotion.swift`, `Sources/CrateDiggerApp/UI/Theme/ThemeTokenCatalog.swift`, `Sources/CrateDiggerApp/UI/Carbon/Header/ViewSwitcherColumn.swift:120`, `Sources/CrateDiggerApp/UI/Carbon/Main/MainShell.swift` (the `ink3`/`ink2` prints on the small chassis keys: column count, search key colour, sort key off state, `chevronGlyph`)
- Create: `Sources/CrateDiggerApp/UI/Theme/InterfaceStyleEnvironment.swift`
- Test: `Tests/CrateDiggerAppTests/InterfaceStyleTokenTests.swift`

**Interfaces:**
- Consumes: Task 1 and 2.
- Produces:
  - `EnvironmentValues.interfaceStyle: InterfaceStyle` (default `.hardware`), set by `CarbonThemed` from `registry.activeDefinition(for:)?.resolvedStyle` (so an open draft shows live); DEBUG only, `CRATEDIGGER_STYLE=<raw value>` overrides it, read once.
  - `EnvironmentValues.softSurfaces: SoftSurfaces?` — `struct SoftSurfaces: Equatable { var metal: Color; var well: Color; var paper: Color }`, computed in `CarbonThemed` only when the style is `.softBlocks` (metal on chassis, well on chassis, paper on well, through `SoftSeparation`), nil otherwise.
  - `CarbonGeometry.styledRadius(_ radius: CGFloat, for style: InterfaceStyle) -> CGFloat` (multiplied, clamped to `Bounds.cornerRadius`).
  - `CarbonTheme.stickerInkOverride: Color?`, `CarbonTheme.stickerInk: Color` (fallback per Global Constraints), read from colour key `stickerInk`.
  - `CarbonTheme.keyPrint(_ fallback: Color) -> Color` = `chassisInkOverride ?? fallback`.
  - `CarbonMotion.softPress: Animation`.

- [ ] **Step 1: Write the failing tests**

```swift
func testStickerInkFallsBackPerAppearance() // dark: equals chassisInk.opacity(0.85); light: ink.opacity(0.9)
func testNamedStickerInkWins()               // colors ["stickerInk": "#6E8EF5"] → Color(hexString: "#6E8EF5")
func testStickerInkHasASwatch()              // ThemeTokenCatalog.allColorTokens contains "stickerInk"
func testKeyPrintFollowsChassisInkOnlyWhenSet() // unset → fallback exactly; set → chassisInk
func testStyledRadiusStaysInBounds() {
    for style in InterfaceStyle.allCases { for r in stride(from: 0.0, through: 16.0, by: 1.0) {
        XCTAssertTrue(CarbonGeometry.Bounds.cornerRadius.contains(CarbonGeometry.styledRadius(r, for: style)))
    } }
    XCTAssertEqual(CarbonGeometry.styledRadius(6, for: .hardware), 6)
}
```

(Mirror the `theme(colors:)` helper of `DisplayLampTokenTests`.)

- [ ] **Step 2: Run** `scripts/test.sh --filter InterfaceStyleTokenTests` — Expected: FAIL.

- [ ] **Step 3: Implement** the Interfaces above. The swatch: `ColorToken(key: "stickerInk", label: "Sticker Ink", …, read: \.stickerInk)` beside "Key Print". Replace the five `ink3`/`ink2` key prints with `theme.keyPrint(<their current ink>)`.

- [ ] **Step 4: Run** `scripts/test.sh --filter "InterfaceStyleTokenTests|DisplayLampTokenTests|CarbonGeometryTokenTests"` — Expected: PASS.

- [ ] **Step 5: Commit** `feat(themes): deliver the interface style, Sticker ink and key print tokens`

### Task 5: Styled slab, press and the shadow split

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/Surfaces/StyledSlab.swift` (port of the spike's `StyledSlab`, `StyledPress`, `StyledKeyButtonStyle` reading `\.interfaceStyle`, `\.softSurfaces` and `stickerInk`; Flat Hardware's key top face is `fill` with `hi` at 0.5 over the top half, as in the spike's final version)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/CarbonViewHelpers.swift` (`depthShadow`, new `contentShadow`), every `depthShadow` call site listed below

**Interfaces:**
- Produces:
  - `struct StyledSlab<S: Shape>: View` — `init(shape: S, fill: Color, hi: Color? = nil, lo: Color? = nil, depth: CGFloat = 2.5, sunken: Bool = false, outline: CGFloat = 2)`. Never instantiated for `.hardware`.
  - `struct StyledPress: ViewModifier` — `init(pressed: Bool, depth: CGFloat = 2.5)`; Soft uses `CarbonMotion.movement(.softPress, reduceMotion:)`.
  - `struct StyledKeyButtonStyle: ButtonStyle` — `init(depth: CGFloat = 2.5)`.
  - `View.depthShadow(color:radius:x:y:)` — parts: `.hardware` as today (FLAT-gated); `.flatHardware` the spike's short contact shadow (`radius: min(radius, 6) * 0.45, x: x * 0.5, y: min(y, 4) * 0.6`); `.softBlocks` and `.sticker` none.
  - `View.contentShadow(color:radius:x:y:)` — draws iff `style.castsContentShadows(flatSwitchOn: !theme.castsShadows)`.

- [ ] **Step 1: Sort every call site.** Content/display → `contentShadow`: `OLEDDisplay`, `AlbumPoster`, `ArtworkGalleryView` (3), `AlbumArtworkViewer` (2), `AlbumBookletView` (5), `ArtistPageView`, `ArtworkSearchSheetView` (2), `RadioInfoView`, the art in `MiniPlayerView`. Parts stay `depthShadow`: `ChassisLayer`, `RecessedWell`, `PaperPanel`, `SiliconeCap`, `FaderTrack`, `DisplayModeButton`, `PatchBayControls` (2), `ConvertPatchBay`, `EqualizerEditorView`, the glass in `MiniPlayerView`. Read and decide by the same rule (is it the case or a control, or something held in it?): `RadioListView`, `PrepCrateDrop`, `WelcomeTourView`, `CarbonAboutView`, the five in `ThemePreviewIllustration`. List each decision in the commit message.

- [ ] **Step 2: Implement** the Interfaces. Real Hardware's branch of `depthShadow` is today's body, unchanged.

- [ ] **Step 3: Verify Real is untouched.** `swift build`, then `scripts/style-capture.sh carbon dark full "$SCRATCH/t5.png" && scripts/style-compare.sh "$SCRATCH/baseline/carbon-dark-full.png" "$SCRATCH/t5.png"` — Expected: 0 differing pixels.

- [ ] **Step 4: Commit** `feat(styles): styled slab and press; part and content shadows split`

### Task 6: Surfaces and the ad-hoc clips

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Surfaces/ChassisLayer.swift`, `RecessedWell.swift`, `PaperPanel.swift`; `Sources/CrateDiggerApp/UI/Carbon/Main/MainShell.swift`, `Sources/CrateDiggerApp/UI/Carbon/Footer/FooterShell.swift`, `Sources/CrateDiggerApp/UI/Carbon/Main/MiniPlayer/MiniPlayerView.swift` (their own clips of parts)

**Interfaces:**
- Consumes: Task 4 (`interfaceStyle`, `softSurfaces`, `styledRadius`, `stickerInk`), Task 5 (`StyledSlab`).

- [ ] **Step 1: Implement.** Each surface keeps its Real body verbatim inside `if style == .hardware { … } else { StyledSlab(…) }`, with corner radius `CarbonGeometry.styledRadius(<its radius>, for: style)` in the styled branch only. Chassis plate per style: Sticker fill plus a 3 pt `stickerInk` border; Flat Hardware the spike's chassis gradient and lips; Soft Blocks the plain fill. Wells and panels pass `sunken: true`; Soft reads `softSurfaces.well`/`.paper`. Shell materials and the grain-free masks stay exactly where they are. The three ad-hoc clips use `styledRadius` for the shape they clip a part to, never for art.

- [ ] **Step 2: Verify.** Build; capture Carbon and Cobalt light/dark full in `.hardware` and compare to the baseline (expect 0). Capture Carbon dark full with `CRATEDIGGER_STYLE` set to each of the other three and look: the cases, wells and lists follow; the display and the inspector's art keep their shadow and corners.

- [ ] **Step 3: Commit** `feat(styles): case, wells and panels follow the style`

### Task 7: Keys

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Controls/KeyButton.swift` (`KeyButton`, `KeyChrome`, lit/selected state), `Sources/CrateDiggerApp/UI/Carbon/Controls/ChassisKeyButtonStyle.swift` (`ChassisKeyButtonStyle`, `KeySocket`), `Sources/CrateDiggerApp/UI/Carbon/Header/DisplayModeButton.swift` (`ChromeChassis`)

**Interfaces:**
- Consumes: Tasks 4 and 5.

- [ ] **Step 1: Implement.** Styled branch: `StyledSlab(shape, fill: theme.metal, hi: theme.metalHi, lo: theme.metalLo, depth: 3)` (Soft: `softSurfaces.metal`) with `StyledPress(depth: 3)`, `.padding(ChassisKeyMetrics.seat)` so the key keeps its frame; no socket. A selected or lit key fills with the accent and prints `accentInk`, as in Real. Frames and hit targets unchanged.

- [ ] **Step 2: Verify.** Real compare against the baseline (expect 0). Capture each other style, plus one mid-press capture per style: add a DEBUG-only `CRATEDIGGER_STYLE_PRESSED=1`, read once, that makes `StyledPress` draw every key pressed. With Reduce Motion on (System Settings ▸ Accessibility ▸ Display), press a key in Soft Blocks: a quick ease, no spring; note it in the commit message.

- [ ] **Step 3: Commit** `feat(styles): keys follow the style`

### Task 8: Transport, sliders, dials and the mini player glass

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Controls/SiliconeCap.swift`, `PlayDomeButton.swift`, `FaderTrack.swift`, `VolumeKnob.swift`; `Sources/CrateDiggerApp/UI/Carbon/Footer/PositionDial.swift`; `MiniPlayerGlass` in `Sources/CrateDiggerApp/UI/Carbon/Main/MiniPlayer/MiniPlayerView.swift`

**Interfaces:**
- Consumes: Tasks 4 and 5. `CoverScreenBezel` is not touched.

- [ ] **Step 1: Implement**, within each style's rules: Flat Hardware a lit cap on a darker base (the spike's `SiliconeCap` branch is the model); Soft Blocks a flat fill, rounder; Sticker a flat fill, `stickerInk` outline and hard offset shadow. The transport lamp still lights the caps in every style (`transportLamp`). Fader and dial tracks are wells (`sunken`); thumbs and knob are keys. `MiniPlayerGlass` is the mini player's case: it follows like `ChassisLayer`, keeping its four-material clip and no grain.

- [ ] **Step 2: Verify.** Real compare (expect 0) in full, compact and mini. Captures of each other style in full, compact and mini, Carbon dark.

- [ ] **Step 3: Commit** `feat(styles): transport, faders, dials and mini player glass follow the style`

### Task 9: Theme editor and picker

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Sheets/ThemeEditor/SimpleThemePanel.swift` (a "Style" section before "Material"), `Sources/CrateDiggerApp/UI/Carbon/Sheets/ThemeEditor/SimpleThemeEditor.swift` (`choices(from:)` reads `definition.resolvedStyle`), `Sources/CrateDiggerApp/UI/Carbon/Sheets/ThemeEditorView.swift` (Interface section: picker above `flatSwitch`; `flatSwitch` disabled unless `honoursFlatSwitch`), `Sources/CrateDiggerApp/UI/Carbon/Sheets/ThemeEditor/ThemePreviewIllustration.swift` (draws in the draft's style), `Sources/CrateDiggerApp/UI/Carbon/Inspector/ThemePickerPane.swift` (label)
- Test: `Tests/CrateDiggerAppTests/ThemeEditorStyleTests.swift`

**Interfaces:**
- Consumes: `settingStyle` (Task 1), `SimpleThemeChoices.style` (Task 3), `\.interfaceStyle` (Task 4).
- Produces: `ThemeEditorView`'s `setStyle(_ style: InterfaceStyle)` = one assignment `registry.draft = registry.draft?.settingStyle(style)` (one undo step).

- [ ] **Step 1: Write the failing tests** `testSettingStyleOnTheDraftIsOneUndoStep` (through `ThemeEditorSession`'s undo, as `ThemeEditorSessionTests` does: set `.sticker`, undo once → previous style) and `testSimpleChoicesReadTheThemesStyle` (Funhouse-like definition with `.sticker` → `choices.style == .sticker`).

- [ ] **Step 2: Run** `scripts/test.sh --filter ThemeEditorStyleTests` — Expected: FAIL.

- [ ] **Step 3: Implement.**
  - Simple: `keyGrid(columns: 2, InterfaceStyle.allCases, selected: editor.choices.style, label: { $0.displayName.uppercased() })`, tip "How the console's keys, panels and case are drawn. Colours, fonts and layout stay."
  - Advanced: the same four keys; FLAT disabled for the other three with tip "Flat Hardware, Soft Blocks and Sticker draw their own shadows. FLAT applies to Real Hardware only."
  - Picker pane: after the DEFAULT/Installed label, when `resolvedStyle != .hardware`, `Text("· " + style.displayName.uppercased())` in the `· LIGHT + DARK` style.
  - Preview illustration: `.environment(\.interfaceStyle, <draft or sample>.resolvedStyle)` at its root.

- [ ] **Step 4: Run** the filter plus `ThemeEditorSessionTests|SimpleThemeEditorTests` — Expected: PASS. Then open the editor in an isolated launch (`CRATEDIGGER_THEME_EDITOR=simple-preview`, then `advanced-preview`), switch styles, Cancel: the console returns to the theme's saved style.

- [ ] **Step 5: Commit** `feat(themes): choose a style in the Simple and Advanced editors`

### Task 10: Built-in themes

**Files:**
- Modify: `Sources/CrateDiggerApp/Resources/Themes/Llama 97.cdtheme/theme.json`, `Sources/CrateDiggerApp/Resources/Themes/Pocket.cdtheme/theme.json`
- Create: `Sources/CrateDiggerApp/Resources/Themes/Funhouse.cdtheme/theme.json`
- Test: `Tests/CrateDiggerAppTests/BundledThemeTests.swift`, `Tests/CrateDiggerAppTests/SimpleThemeSelfContainedTests.swift` (`builtIns` gains `"funhouse"`, count 5)

- [ ] **Step 1: Write the failing tests** `testBuiltInStyles` (carbon, cobalt → `.hardware` with no `style` key in their files; llama-97, pocket → `.flatHardware`; funhouse → `.sticker`), `testLlamaLightIsTheClassicSkin` (light `chassis` #8E90AA, `metal` #C6C7D0, `paper` #000000, `columnHeaderInk` #E8CF45; dark layer equal to `v2.4`'s), `testFunhouseInks` (light `stickerInk` #1E2463E6, dark `stickerInk` #6E8EF5, dark `metal` #F7B32B).

- [ ] **Step 2: Run** `scripts/test.sh --filter "BundledThemeTests|SimpleThemeSelfContainedTests"` — Expected: FAIL.

- [ ] **Step 3: Edit the files.** Llama '97: add `"style": "flatHardware"` and the light colours from the reference `llama-97.theme.json` (only `light.colors` and the `//` comment change; keep the file's existing formatting and key order so the diff is just those lines). Pocket: add `"style": "flatHardware"`. Funhouse: the reference `funhouse.theme.json`, minus "SPIKE." in its comment, plus `"style": "sticker"`. No logo files: the header shows the theme's name, as for any theme without one.

- [ ] **Step 4: Run** the filter — Expected: PASS (if `SimpleThemeSelfContainedTests` needs a property Funhouse lacks, add it to the theme, not an exception to the test).

- [ ] **Step 5: Commit** `feat(themes): Llama '97 and Pocket wear Flat Hardware; Funhouse wears Sticker`

### Task 11: Full check and documentation

**Files:**
- Modify: `CLAUDE.md` (a short "Interface styles" paragraph under UI ("Carbon" design system): the four styles, where the style lives, that primitives branch internally and Real's path is untouched, `depthShadow` vs `contentShadow`, `styledRadius` never in the environment, `stickerInk`, `keyPrint`, `CRATEDIGGER_STYLE`, the capture and compare scripts, the spec path)

- [ ] **Step 1: Capture the matrix.** Every built-in (carbon, cobalt, llama-97, pocket, funhouse) × light/dark × the four styles (via `CRATEDIGGER_STYLE`) × full/compact/mini, into `$SCRATCH/final/`. Expected: no `PREFS CHANGED`. Look at each built-in in its own default style first, then every other combination; fix anything that looks broken in the style's code, never by retinting a theme.

- [ ] **Step 2: Compare Real.** `scripts/style-compare.sh` for all 12 Carbon/Cobalt baseline captures against their final captures — Expected: 0 differing pixels each.

- [ ] **Step 3: Performance.** With the 8k-track library (isolated), fold to compact and back and resize the window in Real Hardware and in each style. Expected: no visible difference in smoothness from Real; record what you saw in the commit message.

- [ ] **Step 4: Run** `scripts/test.sh` — Expected: all pass (only the environment-gated skips).

- [ ] **Step 5: Show the owner** the matrix as a page (full window, light and dark, each built-in in its default style first) and wait for their word before calling the branch done.

- [ ] **Step 6: Commit** `docs: interface styles in CLAUDE.md`
