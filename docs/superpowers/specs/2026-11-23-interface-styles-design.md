# Interface styles

Status: approved by the owner, 2026-11-23.
Spike (throwaway, not to be merged): branch `spike/interface-styles` off `v2.4` 1b5382b1, worktree `.claude/worktrees/styles-spike`. It shows every style in the running app and its numbers are the starting point for tuning, not a reference implementation.

## Why

A theme today changes colours, fonts, geometry and the shell's material, but every theme is still drawn as the same physical object: chrome keys in sockets, silicone caps, soft cast shadows. The owner wants a second, larger lever over how the app feels: "The styles will change significantly the way users perceive the interface and will feel more personal."

An **interface style** is how the console's shared parts are drawn: their finish, corner shapes, outline weight, and how a key answers a press. Four of them, picked per theme.

## The four styles

Judged from real-window captures of the spike (Carbon, demo library, full window, compact, mini, dark and light).

| Style | Finish | A press |
|---|---|---|
| **Real Hardware** | Today's console, unchanged: sockets, chrome caps with a skirt, silicone caps, gradients, soft cast shadows. | Today's travel. |
| **Flat Hardware** | Keys and caps are a lit top face (the part's fill, its highlight at half strength over the top half, a thin light lip along the top) sitting on their own darker base, which shows as a band below the cap; one short contact shadow under the base. No sockets. Wells and panels are cut in: shaded under their top edge, lit along their bottom one. The case is a top-to-bottom gradient with a light top lip and a darker bottom one. | The cap moves down by the base's depth and covers it; the shadow tightens. |
| **Soft Blocks** | Flat fills only. No outlines, no gradients, no cast shadows. Rounder corners. | The key scales to 0.95 with a short spring. |
| **Sticker** | Every part is a flat fill with a thick inner outline and a hard shadow offset down and right, like a die-cut sticker. The case gets a 3 pt outline. No soft shadows. | The key moves by the shadow's offset and lands on it; the shadow disappears under it. |

"Flat Hardware" was "Toy Hardware" in the spike. The owner found it didn't read as a toy but liked it, and suggested it as a flat version of Real Hardware. A true toy look is mostly colour and proportion, which styles do not own (below); if one is wanted later it is a theme worn with Flat Hardware or Soft Blocks.

## Goals

- The four styles above, chosen per theme, in both the Simple and the Advanced theme editor.
- **A style travels with the theme.** It is part of the theme definition, so sharing or installing a theme carries its style, and switching theme switches style.
- Each style is one fixed, tuned look. The theme's colours, fonts, geometry and shell material still apply inside it.
- Every built-in theme × appearance × style combination looks deliberate, not broken. The owner: "Optimize current themes so they work with different styles."
- Built-in themes wear the styles: Llama '97 and Pocket become Flat Hardware, and a new colourful built-in theme is made for Sticker (below).

## Non-goals

- Key-click sounds and motion character per style (possibly a later project).
- Per-style dials (outline width, shadow offset, roundness) in the editor. The owner chose a single choice over a bundle of settings ("A"). Dials could later sit on top of this without undoing it.
- Retuning Real Hardware. It stays pixel-identical to today.
- Changing album art, artist photos or the display in any style.
- A toy theme, an LCD look for the browser, sources and inspector, the footer layout idea (volume left, transport centre, buttons right). All parked.

## Anti-goals (failures even if it works)

- **A style changes layout, sizes, or the display.** "The display stays the same in every style. It can be customized to look like different types of display… same as today, but its structure and display cycling cannot ever change." The OLED glass, the LED matrix, Busy Signals, the cover screen's LCD and album art are drawn identically in every style. Frames, paddings, the header grid, `CompactDeckMetrics` and every hit target are the same in every style.
- **A theme the owner made or installed changes look on update.** A theme with no style is Real Hardware, so every such theme renders exactly as before. The built-ins are the exception, on the owner's word: Llama '97 and Pocket change to Flat Hardware on purpose. Carbon and Cobalt render exactly as before. One knowing exception for installed themes: a theme whose Key Print (`chassisInk`) differs from its secondary ink (`ink2`) now gets it on the switcher labels and the small pane keys too (below), which is what the token always claimed to do. A theme that merely carries the editor's default pin (Key Print equal to `ink2`, which every theme saved from Advanced holds) does not change. Accepted knowingly: a theme saved from Advanced on an earlier version after its Secondary ink was edited carries a Key Print equal to its former `ink2`, which cannot be told from a deliberate Key Print, so after updating it prints its switcher labels and small pane keys in that former colour.
- **A style costs frames.** No live blurs, no Materials (see `ChassisLayer`'s note on CABackdropLayer), nothing per frame, nothing on the 14k-row lists. The fold travel and window resize must stay as smooth as with Real Hardware.

## Decisions

### What a style owns and what it doesn't

It owns, for the shared parts only: the fill treatment (flat, gradient, lips), outlines, cast shadows, how much rounder corners are than the theme's own radii, and the press response.

It does not own colour (every colour comes from the theme's tokens, except Sticker's ink below), fonts, sizes, layout, the shell material, motion outside the press, or anything listed in the first anti-goal.

### Data model (Core)

- `ThemeDefinition` gets an optional top-level `style`, a Core enum `InterfaceStyle` with string raw values `hardware`, `flatHardware`, `softBlocks`, `sticker`. One style per theme, not per light/dark variant: an adaptive theme is the same object in both appearances.
- Absent → Real Hardware. An unknown value (a theme made by a newer build) also reads as Real Hardware and must not fail the theme's decode. An older app ignores the key, so a shared theme degrades to Real Hardware there.
- It is not inherited: a theme with no `style` is Real Hardware whatever its parent wears, so a theme forked from Llama '97 or Pocket before styles existed stays as it was. A fork or copy made in the editor writes its source's style out explicitly.
- Encoded only when set, so saved themes without one stay byte-identical.

### How it reaches the views (App)

- `CarbonThemed` resolves the active theme's style and puts it in the environment (`\.interfaceStyle`) beside `\.carbon` and `\.carbonGeometry`. The spike's process-wide `InterfaceStyle.current` and its `CRATEDIGGER_STYLE` variable go away; a DEBUG override for captures is welcome but must be optional.
- A theme editor draft shows its style live, as it does for every other field.
- Corner roundness is a per-style multiplier on the theme's `keyCornerRadius`, `wellCornerRadius` and `paperCornerRadius` (spike: Soft 2.0, Sticker 1.35, Flat Hardware 1.4, Real 1). Results stay within `CarbonGeometry.Bounds`. The editor's geometry rows keep showing and editing the theme's own values, not the multiplied ones.

### Parts that follow the style

Every surface built from the shared primitives follows: `ChassisLayer`, `RecessedWell`, `PaperPanel`, `KeyButton`/`KeyChrome` (including the selected/lit state), `ChassisKeyButtonStyle` (header keys and the view switcher) and `KeySocket`, `ChromeChassis`, `SiliconeCap` and its button style (transport), `PlayDomeButton`, `VolumeKnob`, `FaderTrack`, `PositionDial`, and `depthShadow`. That covers the main window, compact player, the Patch Bay, the EQ editor, the inspector and browser chrome, the gallery, the welcome tour, the About window and the theme editor's own preview illustration, wherever they use those parts.

The mini player's glass (`MiniPlayerGlass`) follows too: it is the mini player's case. The cover screen's bezel (`CoverScreenBezel`) does **not**: it belongs to the display.

**Content and the display keep their shadow and corners in every style** (my call, from the owner's "the display stays the same" and the rule that a style owns the case, not what sits in it). The OLED glass, the cover screen bezel, album art (`AlbumPoster`, gallery tiles, the compact and mini players' art), artist photos and the floating booklet and artwork viewers draw exactly as in Real Hardware. So:
- `depthShadow` splits in two: one for parts (follows the style) and one for content and the display (never does). Every call site is sorted into one or the other; the spike's single modifier changed both and is wrong here.
- The radius multiplier is applied inside the primitives, not to the environment's `CarbonGeometry`, because art clips and the cover screen bezel read the same `wellCornerRadius`. Ad-hoc clips of parts (`MainShell`, `FooterShell`, `MiniPlayerView`) take the style's radius explicitly.
- The FLAT switch keeps its current reach (it already strips content shadows) in Real Hardware.

Ad-hoc shadows and bevels drawn inline rather than through the primitives are found and either moved onto the primitives or made to follow the style; the builder lists them during planning.

### Press

- Per style, as in the table. All curves come from `CarbonMotion` (add tokens for Soft's spring; don't pick curves inline).
- Under Reduce Motion, Soft's spring becomes a quick ease; the small offsets of Flat Hardware and Sticker stay, since they are feedback, not movement, as Real's one point of travel does today.

### Sticker's ink

Sticker's outline and hard shadow are one ink. On light themes it is the theme's `ink` at 0.9. On dark themes black at 0.92 nearly disappears into the case; the spike's alternative, the theme's light ink (`chassisInk`) at 0.85, reads strongly. It becomes a theme colour token, `stickerInk`, with a fallback that picks per appearance, a swatch in `ThemeTokenCatalog` and a fallback test, following the pattern of the lamp tokens (`DisplayLampTokenTests`). On dark the fallback is the light ink (my call: black all but vanished on dark cases). A theme can set its own, as Funhouse dark does with a lighter blue.

### The existing FLAT switch

Advanced ▸ the FLAT switch (`effects["flat"]`, `castsShadows`) still exists and still means "no cast shadows", but only in Real Hardware. The other three styles define their own shadows and ignore it; the editor shows the switch disabled for them, with a tip saying why. Llama '97's `"flat": 0` is unaffected.

### Built-in themes

The owner asked for Llama '97 and Pocket to wear Flat Hardware, and for a new colourful theme made for Sticker, from a retro hand-drawn sticker sheet they supplied (sky-blue ground, mustard and hot-pink stickers, navy outlines, a white die-cut rim).

| Theme | Style | Change |
|---|---|---|
| Carbon | Real Hardware | none |
| Cobalt | Real Hardware | none |
| Llama '97 | **Flat Hardware** | `"style": "flatHardware"`; light layer recoloured after the classic light skin (below); dark unchanged |
| Pocket | **Flat Hardware** | `"style": "flatHardware"`; colours unchanged |
| **Funhouse** (new; working name, the owner may rename it) | **Sticker** | a new adaptive theme, below |

**Funhouse**, as captured in the spike (it now ships as `Sources/CrateDiggerApp/Resources/Themes/Funhouse.cdtheme/theme.json`; its `stickerInk` keys use the token this design adds):
- Light: a sky-blue case (`chassis` #5BC2F2), mustard keys (`metal` #F7B32B) printed in navy (`chassisInk` #1E2463), white panels (`well` #FFFFFF) holding cream lists (`paper` #FFF7E8), navy ink.
- Dark (second round; the owner found the first, all navy with royal-blue keys, not right): the same stickers on a deep royal-blue sheet (`chassis` #1E2A86). The keys stay mustard printed in navy, the panels are navy (`well` #10154A) holding slightly lighter navy lists (`paper` #18205C) with cream type, mustard secondary lines (`ink2` #FFD36B) and sky-blue labels (`ink3`, `columnHeaderInk` #8FD9F5). Sticker's outlines are a lighter periwinkle blue (`stickerInk` #6E8EF5); the owner found cream outlines "a little off" and asked for "a lighter blue tone".
- The owner: light mode "looks perfect".
- Both: hot pink for what is on (`orange` #EE3D96, the selection, key and transport lamps, `meterHot`), mustard `sun`, mint `cyan` (#2FC99A), royal-blue `indigo`; a navy display glass with cream type. Avenir Next for sans (Medium, DemiBold, Bold, Heavy). Rounder geometry (chassis 14, key 8, well 10, paper 8).
- Still to do: nothing for a logo (it has none, so the header shows the theme's name, as for any theme without one); a `simple` recipe if `SimpleThemeSelfContainedTests` requires one for built-ins, and adding it to the built-in lists in the tests (`SimpleThemeSelfContainedTests.builtIns`, `BundledThemeTests`).

**Llama '97 light, recoloured** (the owner: "needs a revamp of colors used, needs to be based on light themed" classic skins; reference: the classic 1997 skin's lavender-grey windows). A lavender-grey case (`chassis` #8E90AA, `chassisHi` #B2B4CA, `chassisLo` #6A6C86) with darker grooves (`well` #6D6F89), pale grey bevelled keys (`metal` #C6C7D0, `metalHi` #E6E7EE, `metalLo` #94959F; the owner: "grey, not beige") printed near-black (`chassisInk` #1C1D26), black lists (`paper` #000000) in mint green (`ink` #B6F0B6, `ink2` #8ED88E) with yellow column headers (`columnHeaderInk` #E8CF45), a gold accent (`orange` #D99A2B) and yellow `sun` (#E8CF45), green LEDs (`keyLamp`, `transportLamp` #46E046), the navy selection bar kept. The display is unchanged. The theme as it ships is `Sources/CrateDiggerApp/Resources/Themes/Llama 97.cdtheme/theme.json`. Still to tune: the small CRATEDIGGER wordmark reads pale on the lavender case.

**Print on keys follows `chassisInk` when it differs from `ink2`** (my call, found in both themes): the VIEW / THEME / EQ switcher labels and the small keys in the pane headers (collapse, search, column count, sort) print in `ink3`/`ink2`, the panel inks, so on Funhouse's mustard keys and Llama's pale ones they vanished. They now read `chassisInk` when it differs from the theme's secondary ink (`ink2`), and their old ink otherwise. The editor seeds Key Print at `ink2` in every draft; that default pin is not a choice, and in the editor it follows Secondary ink while the two are equal, so editing `ink2` never turns it into one.

**How a built-in is made to work in every style** (my call, from "optimize current themes"): by tuning the style, not by retinting the theme, so a theme's Real Hardware look never moves when it is worn in another style. The spike's first example: Flat Hardware's key highlight was a full `metalHi` → `metal` ramp, which paled Llama '97's dark keys until the green glyphs washed out; it is now `metalHi` at half strength over the top half of the cap, which keeps every theme's keys close to their Real tone. Soft Blocks' separation (below) is the same idea. A built-in's colours change only where its own default style needs it, as Funhouse's were chosen for Sticker.

Choosing another style for a built-in in the editor works through `BuiltInThemeEditing` as any other edit does, so an owner who wants Llama '97 or Pocket back as they were picks Real Hardware.

### Soft Blocks on low-contrast themes

Some themes' parts nearly match their case (Llama '97 light keys #C4C4C4 on #C0C0C0, Pocket light #CFCBC4 on #C9C6BE, Carbon light lists #FAFCFD on #F5F8FA). With no outline, gradient or shadow, Soft Blocks would make them vanish. Soft adds separation only where it is needed (my call, from "optimize current themes so they work with different styles"): when a part's fill is too close in luminance to the surface it sits on, Soft lightens or darkens the fill a step, away from the surface, starting from the theme's own colours. Parts already distinct (all of Carbon dark) are untouched. The threshold and the step are tuning; a Core test pins the rule (a pair under the threshold is pushed apart, a pair over it is untouched).

### Shell materials

Allowed in every style (Sticker on carbon weave is fine). They keep their rules: one at a time, under the grain-free mask, off the lists.

### Theme editor

- **Simple:** a four-way style picker, alongside the palette.
- **Advanced:** the same picker in the interface section, beside the FLAT switch and shell materials.
- Choosing a style is one undo step and is written into the draft like any other field.
- The editor's preview illustration shows the style. The theme picker pane has no thumbnails (each row is an accent dot and a name); a theme whose style is not Real Hardware gets a small style label beside its name, like the existing DEFAULT / Installed labels (my call; real thumbnails are a feature of their own).

## Checking it

- Core: decode/encode round trip, absent and unknown values reading as Real Hardware, inheritance, encode-only-when-set.
- App: `stickerInk` fallback test; a test that the radius multiplier stays in bounds; Real Hardware renders the same view tree as before (no style code path runs for it).
- By eye from **real window captures at true size** (the owner reviews from real captures, not sketches): every built-in theme (Funhouse included) × light/dark × four styles, full window, compact and mini, with each built-in's default style checked first, plus a key mid-press. The snapshot hook is fine for layout but flattens blend modes, so materials must be checked in a window capture.
- Launch isolated for captures, as the spike did: a renamed copy of the binary, scratch `CRATEDIGGER_CRATES_DIR` and `CFFIXED_USER_HOME`, prefs backed up and compared afterwards.
- Performance: fold travel and window resize compared against Real Hardware on the 8k-track library.

## Approaches considered

- **A. A style is a single choice (chosen).** One word in the theme; each shared part draws itself per style with numbers we tuned. Four looks to test; nobody can make an in-between that looks broken. Can't do "Sticker with thinner outlines".
- **B. A style is a bundle of settings.** A style seeds roundness, outline, shadow kind and offset and press kind, each a dial in Advanced. More personal, but many combinations look broken, the editor and test surface grows a lot, and the line between a style and a theme blurs. The owner chose A.
- **C. A separate implementation of every view per style** (a style kit protocol making keys, wells, panels). Rejected: the parts already funnel through a handful of primitives, so switching inside them is far less code and keeps layout identical by construction.

## Left to the builder

- Final tuning of every number per style, judged from captures with the owner.
- The exact enum, environment key and file names; where the style switch lives inside each primitive.
- How a style draws on parts not yet seen in the spike (knob, dome, position dial, mini player glass), within the style's rules above.
- The list of ad-hoc shadows and bevels to move onto the primitives.
- Which branch: new work branches from `v2.4`, the beta line.
- Carrying `style` through the theme loader's merge and `SimpleThemeBuilder` seed/build; checking Real Hardware unchanged with the `ThemePreviewSnapshotTests` setup.
