# Theme Editor: Simple and Advanced

Date: 2026-11-22
Status: approved by the owner 2026-11-22
Release line: **2.4 beta**, the next major release (owner's call). Not the
v2.3 line.

## Why

Starting a new theme, or just trying an idea on an existing one, is too much
work today. The editor is one long list of about 70 colour tokens, effect
dials, geometry, fonts and logos. That is the right tool for finishing a
theme and the wrong one for beginning one.

The owner's words: "Simple could either be a way for non-power users to make
themes, or power users to quickly kickoff new theme ideas."

So the editor gets two modes:

- **Simple:** enter a palette of 2 to 6 colours. The editor decides which
  colour does which job and derives every token, keeping the app legible and
  good-looking. A Shuffle key offers other arrangements of the same colours.
- **Advanced:** roughly today's full token editor.

Both modes get a preview, because the user has to be able to see what each
colour is doing.

## Goals

- A complete, good-looking theme from 2 to 6 colours in under a minute.
- Every Simple result is legible: no text, key print or screen text can fall
  below the contrast floors below, whatever the palette.
- Each swatch shows which parts of the app it paints.
- One palette builds both the light and the dark version of a theme.
- Power users can start in Simple and finish in Advanced.

## Non-goals

- **Interface styles** (Soft Blocks, Sticker, Toy Hardware, Real Hardware).
  The owner wants these and has decided a style travels with its theme, but
  they are a separate project designed after this one. This editor ships with
  every theme in today's look, Real Hardware. See "Leaving room for styles".
- An LCD look for the browser, sources and inspector panels. That belongs to
  the styles project too.
- Moving the footer controls. The owner liked the mockup's footer order
  (volume left, transport centre, keys right) but does not want it changed
  now.
- Generating themes from an image or album cover.
- Any change to the display's layout or screen cycling.

## Anti-goals (a failure even if it works)

- A Shuffle result with unreadable text.
- A Simple theme that looks generated, where everything is one hue at five
  lightnesses. It must look as considered as Carbon.
- Shuffle quietly changing fonts, material or album-art look.
- Advanced losing anything it can do today.
- Previews that lie: the Simple preview must use the same tokens and the real
  album-art renderer, never a picture that approximates them.

## Constraints

- Colour derivation, contrast checks, shuffle history and mode-crossing rules
  are decidable values, so they live in `CrateDiggerCore` with XCTest
  coverage (CLAUDE.md: SwiftUI views are untested and that is where bugs
  concentrate).
- The theme file stays readable by older builds. `JSONDecoder` ignores unknown
  keys, so a new optional field is safe. A Simple theme also stores every
  derived token, so an older build renders it correctly with no recipe code.
- `ThemeTokenCatalog`'s `read` key paths must keep matching what
  `CarbonTheme` renders. A token Simple writes must be one the catalog
  lists.
- Shell materials and cover looks stay exclusive groups, written through
  `ThemeTokenCatalog.settingExclusive` and resolved by
  `ShellMaterial.resolve` and `CoverScreenLook.resolve`.
- Font presets use only bundled fonts (Inter, JetBrains Mono, Major Mono
  Display, Silkscreen, Pixel Operator Mono 8) or fonts that ship with macOS,
  so a shared theme never falls back to the system font on another Mac.
- Captures for review are real window captures (`screencapture -l`), not the
  snapshot hook, because the hook flattens blend modes. Launch against a
  scratch `CRATEDIGGER_CRATES_DIR`.

## Approaches considered

How a palette of 2 to 6 colours becomes the theme's ~70 colour tokens:

- **A · Recipe table (chosen).** Core holds one table: for each token, which
  job it comes from and how to shift it ("Top Highlight is Frame, a bit
  lighter"). The table is written by reading Carbon's own dark and light
  tokens, so a fresh theme inherits Carbon's considered relationships.
  Contrast is enforced per pair by moving lightness only. Shuffle reassigns
  palette colours to jobs and varies contrast strength. Predictable,
  testable, tunable. Its cost: variety comes only from the assignment.
- **B · Built-in themes as templates.** The palette is poured into Carbon's,
  Cobalt's, Llama '97's or Pocket's structure, and Shuffle cycles templates
  too. Rejected: results read as "Carbon in other colours", each template
  carries its quirks (Llama's monochrome glass), and it is four tables'
  work.
- **C · Generate and score.** Make hundreds of candidates, score contrast and
  harmony, show the best. Rejected: "beautiful" is hard to score or test,
  results feel random, and pins become hard to reason about.

The owner picked A. If it later feels samey, B's best idea can be added on top
as alternative recipe tables ("flavours") for one Simple palette.

## The design

### One panel, two modes

Simple and Advanced share the existing floating editor panel
(`ThemeEditorView`, a `carbonPanel`), with a SIMPLE / ADVANCED switch at the
top.

- **NEW starts a theme in Simple (owner's call).** A new NEW key sits in two
  places: beside EDITOR in the theme picker (`ThemePickerPane`), and in the
  editor's identity bar. It opens Simple on an unsaved new theme whose
  starting palette is taken from the theme currently on screen (as in
  "Starting from an existing theme"). Today the app has no new-theme action
  at all; every entry point goes through `beginEditing`.
- **EDITOR opens the current theme in its own mode**, as today: Simple if the
  file has a `simple` block, otherwise Advanced. Opening a built-in still
  forks it into an Advanced "Carbon Copy". The beta-only in-place path
  (`BuiltInThemeEditing`) is unchanged and is Advanced too.

### What decides the mode

A theme is a **Simple theme** when its definition carries a `simple` block
(below). Everything else is an Advanced theme, including all four built-ins.

### Crossing between modes (owner's rule)

- **Simple to Advanced** stays the same theme, but first asks: *Copy*,
  *Convert* or *Cancel*. The prompt says that a converted theme cannot go back
  to Simple. Both take the draft on screen, unapplied changes included;
  nothing is written to disk until Save, as in Advanced today. (My call.)
  - *Copy* makes a new Advanced theme from the current tokens and leaves the
    Simple original untouched.
  - *Convert* drops the `simple` block from this theme, keeping every token.
- **Advanced to Simple**, built-ins included, offers only *Copy* or *Cancel*.
  The copy is a new Simple theme whose starting palette is taken from the
  original's main colours (see "Starting from an existing theme").

### Simple: the controls, top to bottom

1. **Palette:** 2 to 6 swatches, each with a hex field and the system colour
   picker, plus add and remove.
   - Under each swatch are the names of the jobs it currently does.
   - Hovering a swatch, or a job name, highlights those parts in the preview
     and dims the rest.
2. **Pins:** a swatch can be pinned to a job (pin icon, then pick the job).
   Pinned jobs never move on Shuffle.
3. **Shuffle key**, with ← and → to step back and forward through the last 20
   steps. The history lives only in the editor session. (My call:) each step
   is the whole Simple state, meaning palette, pins, assignment and contrast.
   A Shuffle adds a step, and so does every finished edit: a hex committed, a
   swatch added or removed, a pin set or cleared. So ← also undoes a colour
   change. In Simple this replaces the UNDO key; Advanced keeps UNDO.
   Because each step carries its own palette, removing a swatch never leaves
   a step pointing at a colour that is gone.
4. **Contrast:** Soft, Standard or High, chosen by the user (owner's call).
   Default Standard.
5. **Appearance:** Light, Dark or Both. Both writes the light and dark layers,
   making the theme adaptive.
6. **Shell material:** None, Grain, Plastic, Brushed, Blasted or Weave.
   - Each choice writes the strength the built-ins use (weave 0.09, brushed
     0.06, plastic 0.05) through `settingExclusive`.
   - Strengths for grain and blasted are tuned from captures.
   - Advanced keeps the dials.
7. **Album-art look:** Off, LCD Grid, Pixel LCD or Handheld LCD.
   - The strength and pixel size are set automatically for each look; the
     builder tunes them from captures, starting from Pocket's 0.55 / 1.5.
   - Advanced keeps the fine controls.
8. **Fonts:** three rows of five presets each. A row whose current font is not
   one of its presets shows a sixth chip, "Custom", which is that font.
   - *Screen Titles* writes the `display` role.
   - *Labels & Readouts* writes `mono`. This role also sets the small
     uppercase headings app-wide; the row says so.
   - *Interface* writes `sans`.

   Starting presets (my call, to confirm from captures):

   | Screen Titles | Labels & Readouts | Interface |
   |---|---|---|
   | Major Mono Display | JetBrains Mono | Inter |
   | Silkscreen | Pixel Operator Mono 8 | SF Pro (system) |
   | Futura | SF Mono | Avenir Next |
   | DIN Condensed | Menlo | Helvetica Neue |
   | Avenir Next (light) | Andale Mono | Gill Sans |

9. **Apply**, and the name field. Duplicate and Load stay as today.

Shuffle never changes fonts, appearance, contrast, material or album-art
look. It changes only the job assignment. (This reverses an earlier proposal
in which Shuffle also varied contrast: a user who needs high contrast must
not have it shuffled away.)

### Simple: the preview (option B)

- **The app stays on the saved theme.** While Simple is open, the app keeps
  drawing the saved version. The draft shows only in the editor's preview.
  Apply pushes it to the app (writes `ThemeRegistry.draft` and saves).
- **Closing with unapplied changes** asks Apply or Discard.
- **What the preview draws:** an illustrated mockup of three screens, the full
  window, the mini player and the compact player, drawn in SwiftUI from the
  draft's resolved `CarbonTheme`. It does not use the real views: they need
  `LibraryViewModel` (OLEDDisplay alone reads 18 environment objects), and a
  snapshot flattens the shell materials.
- **What it is built from:**
  - The draft's colours and fonts.
  - A flat rendering of the shell material.
  - Real album art: the cover-screen pictures are produced by Core's
    `CoverScreenLayout.plan` and `CoverScreenRenderer.render` from a bundled
    sample cover, at true pixel size.
  - Its shapes are tagged by job, which is what makes hover-highlighting
    work.
- **Appearance toggle:** for an adaptive draft, a small Light/Dark toggle on
  the preview shows each layer.
- **Its drawing style is Real Hardware**, the look the app has today:
  - simplified chassis, wells and keys;
  - silicone transport caps;
  - the display drawn as glass with its cells.

  The three illustration styles in the brainstorm page (Soft Blocks, Sticker,
  Toy Hardware) are not used yet; they belong to the styles project. **The
  Real Hardware drawing must be sketched in the companion page and approved
  by the owner before it is built.** The owner judges visual work by eye.

### Advanced

- **Live editing (option A):** Advanced keeps today's behaviour. It edits
  `ThemeRegistry.draft`, and the whole app repaints live.
- **Preview button:** a new PREVIEW key opens the same illustrated preview in
  a side panel, showing the album art, the mini player and the compact player.
  These are the screens not visible while editing the full window.
- **Everything else is unchanged:** every token row, the dials, geometry,
  logo, display presets, glass effects and the full font picker.

### Data model

`ThemeDefinition` gains one optional field:

```json
"simple": {
  "palette": ["#1B1D22", "#E8E2D4", "#FF6A13", "#2FD6C4"],
  "pins": { "accent": 2 },
  "assignment": { "frame": 0, "panels": 1, "text": null, "accent": 2,
                  "glass": 0, "screenText": 3 },
  "contrast": "standard",
  "recipe": 1
}
```

- **`palette`:** the user's colours, in order.
- **`pins`:** job to palette index.
- **`assignment`:** the variant on screen. `null` means a job derived by the
  recipe rather than taken from the palette (for example, Text from a
  2-colour palette).
- **`contrast`:** `soft`, `standard` or `high`, as the user set it.
- **`recipe`:** the version of the recipe table that produced the tokens.

The six jobs are **Frame, Panels, Text, Accent, Screen Glass and Screen Text**.

Appearance, material, cover look and fonts are not in the block. They are
already ordinary theme fields, and Simple writes them there.

A Simple theme also stores every token the recipe derived, in its `colors`
(or in its `light` and `dark` layers when it is adaptive). For everything the
recipe does not set (shadows, geometry, display effects, logo) it inherits
from the theme it was started from: the theme on screen when NEW was pressed,
or the original of a Copy. (My call: a Pocket copy keeps its monochrome glass,
Llama's keeps its glare settings.) Simple only ever rewrites colours, fonts,
contrast, material and album-art look. The saved tokens are the truth. The block is only how to regenerate
them.

### The recipe (Core)

`SimplePalette` (name is the builder's) is a pure function:

`(palette, assignment, contrast, appearance, recipeVersion) -> [token: hex]`

- **Colour space:** colour math in OKLCH on hex strings, with no AppKit.
- **Each token** is a job plus a transform: lightness offset, chroma scale and
  alpha. There is one table for dark and one for light, each derived from
  Carbon's own tokens of that appearance.
- **Meaning colours keep their meaning.** Alert red, Amber, Teal, Info Blue
  and Meter High keep their hue family. Only their lightness and chroma adapt
  to the background, so red still means red.
- **Fallback tokens stay unset:** the lamp overrides, `selectionGlow`,
  `selectionSpread` and `transportLamp`. Left unset, they follow the accent
  exactly as they do in shipped themes, and that is less to get wrong.
- **One palette builds both appearances.** A job colour is used exactly in
  the appearance whose lightness range it fits. In the other appearance its
  hue and chroma carry over at the recipe's lightness. So a cream panel colour
  is the panel in Light and a deep cream-tinted panel in Dark.
- **Contrast floors** (WCAG 2 ratio), enforced by moving the foreground's
  lightness, then the background's if the foreground hits its limit:

  | Pair | Floor |
  |---|---|
  | ink on paper, ink on well | 7.0 (soft 4.5, high 10) |
  | ink2 on paper | 4.5 |
  | ink3, columnHeaderInk on paper | 3.0 |
  | chassisInk on metal and on chassis | 4.5 |
  | oledForeground on oledSurface | 7.0 |
  | oledForegroundMuted on oledSurface | 3.0 |
  | selectionInk on the selection fill | 4.5 |

- **Valid assignments:** an assignment is valid when Frame and Panels differ
  enough in lightness to read as separate surfaces, and Accent has the
  highest chroma of the assigned colours or is pinned.
- **Shuffle** walks the valid assignments that respect pins, in a
  deterministic order from a seed. It never changes `contrast`.
- **With 2 colours,** Text and Screen Text are derived as tinted neutrals.
  **With 6 colours,** every job can take its own colour.

### Starting from an existing theme

For NEW, and for Advanced to Simple, Core reads the original's job colours:

| Job | Token |
|---|---|
| Frame | `chassis` |
| Panels | `paper` |
| Text | `ink` |
| Accent | `orange` |
| Screen Glass | `oledSurface` |
| Screen Text | `oledForeground` |

(My call:) an adaptive original is read from both its light and dark layers.
Core merges colours closer than a small OKLCH distance, keeps at most six, and
pins each job to its colour so the first result resembles the original. An
adaptive original makes a copy set to Both; a single-appearance one keeps its
appearance. Fonts, material and cover look are copied as they are, and the
copy inherits from the original (see Data model).

### Reopening a saved Simple theme

The editor shows the saved tokens as they are. The first palette change or
Shuffle in that session warns that the theme will be regenerated (its tokens
may differ if the recipe has improved since it was saved), then regenerates.
After that, no more warnings in that session.

### Leaving room for styles

The styles project will add a theme-level style field and a Style row to
Simple and Advanced. It will also give the preview one drawing per style.
Nothing for styles is stored by this project. The preview's drawing code
should take the theme and the job tags as inputs, so a second drawing style
is a new view, not a rewrite.

## Testing

All of the following are Core XCTest:

- **Contrast floors** hold for every pair across a seeded set of random
  palettes (2 to 6 colours, both appearances, all three contrast levels),
  plus deliberately hostile ones: all one hue, near-white plus near-black,
  neon.
- **Determinism:** the same inputs and recipe version give the same tokens.
- **Pins** are never moved by Shuffle.
- **Shuffle history:** 20 steps; stepping back and forward returns the exact
  earlier states, palette included; removing a swatch never breaks a step.
- **Contrast** is never changed by Shuffle.
- **Extraction:** taking each built-in's palette and re-deriving it gives
  tokens close to the original for the six job tokens.
- **Every token Simple writes** is in `ThemeTokenCatalog` (an app test,
  since the catalog lives in the app).
- **Mode-crossing rules:** which choices are offered when.
- **Round trip:** a Simple theme encodes and decodes losslessly. An older
  shape without `simple` still decodes.

Visual check: real window captures of the preview and of applied Simple
themes, reviewed by the owner against the mockups.

## Left to the builder

- Type and file names.
- How the panel lays out the preview beside the controls, and the preview's
  scale.
- The exact token transforms in the recipe table, within the rules above.
- How "valid assignment" thresholds are tuned.
- The automatic strengths for each shell material and cover look in Simple.
- How the Custom font chip behaves when the font is not installed.
