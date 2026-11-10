# Shell materials, the cover screen, and the Pocket theme

Date: 2026-11-10. Branch: `feat/pocket-shell-materials` (cut from `v2.3` after
2.3.3 RC 1, build 116). Ships as a feature, so by the release rules it goes out
as 2.3.4 beta 1.

## Why

The app is drawn as a piece of hardware, but only partly: a chassis, wells, a
display behind glass. The owner wants themes to be able to push that further,
in the way a retro handheld's shaders and overlays change how a game looks
without changing the game:

- the **shell** can be made of something (today its only texture is grain), and
- the **cover** in the small players can be shown on a low-resolution LCD, like
  a handheld's screen, instead of as a photograph.

The principle, in the owner's words: the whole app should have the feel of
skeuomorphism, but not fully, and the compact player doubles down on it. So the
shell material is subtle and everywhere; the cover screen exists only in the
compact player and the mini player.

A new built-in theme, **Pocket**, is the showcase.

## Goals

1. A theme can give the chassis one **shell material**: grain (as today),
   moulded plastic, brushed metal, bead-blasted metal or carbon weave, each at
   its own strength.
2. A theme can give the cover a **screen look** in the compact player and the
   mini player: A "grid" (sharp cover under an LCD grid), B "pixel" (cover
   redrawn in LCD pixels, full colour) or C "handheld" (B with a non-backlit
   colour handheld's washed colours). With a look on, the cover sits behind a
   recessed **screen bezel**.
3. Both are edited in the theme editor, beside Texture Grain.
4. **Pocket** ships as a fourth built-in theme.
5. Carbon, Cobalt and Llama '97 render exactly as they do today when this lands
   (pixel-identical: no new effect is on in any of them). A separate, later
   tuning pass may change them; it is not part of the build below.

## Non-goals

- Anything animated. Every effect here is still: no flicker, no scan roll, no
  time input.
- The four-greens (original monochrome handheld) look. It was shown and dropped.
- Screen looks on covers anywhere else: the inspector, the gallery, the browser,
  the artwork viewer, the Now Playing widget.
- Stacking materials. One at a time.
- A pixel font or new corner geometry for Pocket.
- Metal shaders. The deployment target is macOS 13, which has no SwiftUI layer
  effects, and a `.metal` resource is one more thing that can go missing from a
  packaged build.

## Anti-goals (it has failed if)

- Idle cost goes up. The texture rule in `CarbonTextures.swift` stands: a
  texture is generated once into a tile (or one image) and then never redrawn.
  No live `Canvas`, no `Material`, no per-frame work, nothing that runs while a
  window resizes or a fold travels.
- The LCD grid shimmers or shows moire. LCD pixels always land on whole device
  pixels.
- An existing theme, or a user's own theme, looks different after the update.
- The cover's screen floats. It must read as set into the shell.
- A lit part and the light it throws are different colours (Pocket).

## Constraints from the codebase

- Effects are numbers: `ThemeDefinition.effects: [String: Double]`, each
  described by a `ThemeTokenCatalog.EffectDial` (key, label, note, max, on,
  surface, read key path), clamped in `CarbonTheme.init`, and pinned by
  `EffectDialTests`. A modifier is "a no-op at 0: the bare view, with no
  compositing group and no extra layer". Everything new follows that contract.
  Two consequences: a dial's `read` is a `KeyPath<CarbonTheme, Double>`, so
  every new dial needs its own stored `Double` on `CarbonTheme` (default 0,
  like `grainAmount`), and `effect(_:_:)` in `CarbonTheme.init` clamps any key
  without a dial to 0...1 (`ThemeTokenCatalog.effectMax`), so a non-dial key
  such as `coverPixelSize` must be read raw, not through it.
- Grain is drawn by `View.carbonGrain(_:)` on `ChassisLayer` (the main window
  in both layouts, plus the About and Guide windows, which also use
  `ChassisLayer`), masked around every view that called `grainFree(...)`: the
  display glass, silicone caps, the inspector's album poster and artwork, the
  gallery's art, the spinning record and the About box's art. The compact
  player's cover does **not** call it, so Carbon draws grain over that cover
  today. The mini player has no grain at all: it is its own borderless,
  transparent window and paints its own glass (`MiniPlayerGlass`), outside
  any `ChassisLayer`. Materials reuse the mask unchanged.
- Decidable values go in `CrateDiggerCore` with XCTest; views stay thin.
- Run tests with `scripts/test.sh`. The debug binary is
  `.build/debug/CrateDiggerApp`.

## Design

### 1. How a theme says it (the data)

No schema change. Everything is a number in `effects`, so inheritance, the
light/dark layers, clamping, the editor's draft and undo all work as they do
for grain. (Checked: `ThemeLoaderService.merge` merges `effects` per key down
an `inherits` chain, and `ThemeDefinition.resolved(for:)` overlays a layer's
`effects` per key on the shared set, so `CarbonTheme.init` receives one flat
dictionary. Its fallback for a missing key is the static `.carbon`/`.linen`,
where every effect is 0, not the parent theme.)

**Shell material: an exclusive group of dials.** The value is the strength.

| Key | Label | max | on (default strength) |
|---|---|---|---|
| `grain` (exists) | Texture Grain | 0.6 | 0.2 |
| `shellPlastic` | Moulded Plastic | 0.30 | 0.08 |
| `shellBrushed` | Brushed Metal | 0.50 | 0.18 |
| `shellBlasted` | Bead-Blasted Metal | 1.00 | 0.58 |
| `shellWeave` | Carbon Weave | 0.40 | 0.12 |

The owner's chosen ranges were plastic 5 to 10, brushed 15 to 20, blasted 55 to
60, weave 10 to 15 (percent on the mockup's slider); `on` is the midpoint and
`max` leaves room above. One unit of strength for the four new materials is the
mockup's: a field value of ±1 moves a pixel's lightness by
`strength × 22 / 255`.

Only one material shows. `ShellMaterial.resolve(effects:)` (Core) returns the
winner: the first non-zero of `shellPlastic`, `shellBrushed`, `shellBlasted`,
`shellWeave`, and `grain` last. Grain is last so a theme that inherits Carbon
(grain 0.1) and sets a material gets the material without having to zero grain.
The editor writes 0 to the others when one is switched on, so a saved theme
never carries two.

**Cover screen: a second exclusive group, plus a size.** The value is the grid
strength (how dark the gaps between LCD pixels are).

| Key | Label | max | on |
|---|---|---|---|
| `coverGrid` | A: sharp cover under an LCD grid | 1.0 | 0.55 |
| `coverPixel` | B: pixel LCD | 1.0 | 0.55 |
| `coverHandheld` | C: handheld colour | 1.0 | 0.55 |
| `coverPixelSize` | LCD pixel size, in points | 4.0 | n/a (default 1.5) |

`CoverScreenLook.resolve(effects:)` (Core) returns the first non-zero of
`coverHandheld`, `coverPixel`, `coverGrid`, with its strength, or `nil`.
`coverPixelSize` is not an on/off dial: it is read only when a look is on,
defaults to 1.5 when absent or 0, and is snapped to the nearest of
`[1.5, 2, 3, 4]` points. At 2x those are 3, 4, 6 and 8 device pixels per LCD
pixel; at 1x they are 3, 3, 3 and 4 (a cell is never smaller than 3 device
pixels: in a 2-pixel cell three of the four pixels would be gap and the
picture goes dark). 1.5 pt is the default because in the compact
player's art well it gives 145 LCD pixels at 2x, about a handheld's own screen
height.

A new `EffectDial.Surface` case, `.cover`, holds the three looks so the editor
can give them their own section. `coverPixelSize` is not an `EffectDial` (it
has no "on"); it is a stepped control in the same section.

### 2. Core (pure, tested)

New folder `Sources/CrateDiggerCore/Services/ThemeEffects/`:

- **`ShellMaterial`**: `enum ShellMaterial: String, CaseIterable { grain,
  plastic, brushed, blasted, weave }` with `effectKey`, and
  `static func resolve(effects: [String: Double]) -> (material: ShellMaterial,
  strength: Double)?` using the priority above. Values at or below 0 are off.
- **`CoverScreenLook`**: `enum CoverScreenLook: String, CaseIterable { grid,
  pixel, handheld }` with `effectKey`, `resolve(effects:)`, and
  `static func pixelSize(from raw: Double?) -> Double` (the snap).
- **`CoverScreenLayout`**: the geometry, so the grid can never land between
  device pixels.

  ```swift
  public struct CoverScreenLayout: Equatable, Sendable {
      public let cell: Int          // device pixels per LCD pixel, >= 3
      public let count: Int         // LCD pixels across (and down)
      public let lcdSide: Int       // cell * count, device pixels
      public let band: Int          // bezel band on each side, device pixels
      /// `side`: the well's side in points. `scale`: the screen's backing scale.
      /// `pixelSize`: points per LCD pixel (already snapped).
      /// `minimumBand`: the thinnest bezel band, in points.
      public static func plan(side: Double, scale: Double, pixelSize: Double,
                              minimumBand: Double = 6) -> CoverScreenLayout
  }
  ```

  Rules: `cell = max(3, round(pixelSize * scale))`. The well's side in device
  pixels is `round(side * scale)`. `count` is the largest whole number of cells
  that fits in the side minus two minimum bands; `band` is half of what is
  left, rounded down, and any odd leftover pixel goes to the bottom and right
  (the layout reports the top-left band). The compact art side at default
  geometry is 230 pt (`CompactDeckMetrics.artSide`: 170 + 12 + 92 - 18 - 20 -
  6, pinned by `CompactDeckMetricsTests`). At 2x and 1.5 pt: well 460, cell 3,
  count 145, lcdSide 435, band 12 (13 on the bottom and right). At 1x: cell 3,
  count 72, lcdSide 216, band 7. The mini player's 246 pt at 2x: cell 3,
  count 156, lcdSide 468, band 12; at 1x: cell 3, count 78, lcdSide 234,
  band 6. A side too small to hold 8 LCD pixels returns a layout with
  `count == 0`, and the view falls back to the plain cover.

  It also carries `static func pixelSnap(origin: Double, scale: Double) ->
  Double`: the offset in points, `(round(origin * scale) - origin * scale) /
  scale`, that moves an origin onto the device grid (see "Landing on device
  pixels" in section 4).
- **`CoverScreenRenderer`**: pixels in, pixels out, no AppKit.

  ```swift
  public enum CoverScreenRenderer {
      /// `source`: RGBA8 sRGB, opaque (alpha 255), `count * count` pixels (the
      /// cover already resampled to the LCD's resolution) for `pixel` and
      /// `handheld`; `lcdSide * lcdSide` pixels for `grid`. Returns RGBA8 sRGB,
      /// `lcdSide * lcdSide`, opaque.
      public static func render(source: [UInt8], look: CoverScreenLook,
                                layout: CoverScreenLayout, gridStrength: Double) -> [UInt8]
      public static func handheldTone(r: UInt8, g: UInt8, b: UInt8) -> (UInt8, UInt8, UInt8)
  }
  ```

  The maths is the approved mockup's, restated here as the reference:

  - **Gap**: within each cell, the last column and the last row are gap. For
    `cell >= 6` the gap is `round(cell / 6)` pixels wide and the lit pixel next
    to it on each side is a soft shoulder at 0.35 of the gap's coverage.
  - **Gap colour**: black `(0,0,0)` for grid and pixel; `(26,25,21)` for
    handheld.
  - **Mix**: `out = lit * gain * (1 - a) + gap * a`, where `a = gridStrength *
    coverage`, clamped to 0...255.
  - **Gain** keeps the picture's brightness under the grid: `gain = min(1.35,
    1 / mean(1 - a))` over one cell.
  - **Handheld tone**, per channel, on the LCD-resolution pixel: quantise to 5
    bits (`(v >> 3) * 255 / 31`); to linear light with gamma 2.2; mix
    `R' = 0.80R + 0.135G + 0.065B`, `G' = 0.03R + 0.72G + 0.25B`,
    `B' = 0.14R + 0.12G + 0.74B`; then `R' * 0.90 + 0.012`, `G' * 0.90 +
    0.012`, `B' * 0.86 + 0.009`; back to sRGB with gamma 1/2.2.

Tests (`Tests/CrateDiggerCoreTests`): the resolve priorities and the
inherited-grain case; the pixel-size snap; `CoverScreenLayout` for the compact
well (230 pt) and the mini player's art (246 pt) at 1x and 2x with the numbers
above (the compact one at 2x is the odd-leftover case), the too-small case,
`pixelSnap` at 1x and 2x, and the invariant `2 * band + lcdSide <= round(side * scale)` and
`lcdSide % cell == 0` across a sweep of sides; the renderer's output size, that
gap pixels of a white source at strength 1 are the gap colour, that strength 0
with look `pixel` reproduces the source pixel in every lit position, that
`handheldTone` maps black to a lifted near-black and never exceeds 255, and
that the function is deterministic.

### 3. Shell materials (app)

In `CarbonTextures.swift` (or a sibling `ShellMaterialTextures.swift` if the
file gets long), each material is generated once, lazily, as a **pair of
tiles**: the positive half of its signed field as white premultiplied alpha
(added with `.plusLighter`) and the negative half as black alpha (laid with
`.plusDarker`, as grain's veil is). That is the same "absolute, not
proportional" approach the grain comments explain, and it is why a material
shows on a near-black chassis and a pale one alike.

Fields (signed, about ±1; all seeded with a fixed seed so a material is the
same on every launch and in every snapshot; all tiles wrap seamlessly):

- **Plastic**: white noise, two 3 × 3 box blurs (wrapping at the tile edge),
  then lit from the top left: `f = (h[x-1, y-1] - h[x+1, y+1]) * 16`. Tile
  256 pt, generated at 2x.
- **Brushed**: per row, an AR(1) walk along x with coefficient 0.975 driven by
  unit noise, scaled 0.42, plus a per-row offset of 0.22 × noise. To wrap, run
  the walk around the row twice and keep the second lap. Tile 512 × 128 pt at
  2x.
- **Blasted**: per device pixel, 0.3 × noise, with 1 pixel in 400 lifted by
  1.4. Tile 256 pt at 2x.
- **Weave**: a 2 × 2 twill. Tow width 4 pt (8 px at 2x). For tow cell `(i, j)`
  the tow runs horizontally when `((i + j) & 3) < 2`. With `across` and `along`
  the 0...1 positions across and along the tow:
  `f = (sin(across·π) - 0.64) * 1.5 + (horizontal ? 0.55 : -0.25) +
  (sin(along·π) - 0.64) * 0.35 + 0.18 * (noise - 0.5)`. The tile is one twill
  repeat (4 tows, 16 pt), but generate 64 pt so the noise does not visibly
  repeat.

"Noise" for brushed and blasted is roughly unit-variance (the mockup summed
four uniforms: `(u1 + u2 + u3 + u4 - 2) * 1.73`).

Encoding: each material's `fieldMax` is the largest |f| in its generated tile,
measured as the tile is made (the fields run past ±1: unit noise reaches
about 3.5, a lifted blasted pixel about 2.4). A tile pixel's alpha is
`|f| / fieldMax * 255`, and the drawn layer's `.opacity` is
`strength * 22/255 * fieldMax`, so the unit rule above holds and the 8-bit
tile never clips. Grain's existing `image(from:)` helper only makes square
tiles at one size; the materials need a variant taking width and height
(brushed is 4:1) and a 2x pixel count. The seed is a small fixed-seed
generator written for this (the grain tile uses `SystemRandomNumberGenerator`,
which cannot be seeded, and stays as it is).

**Sheen.** The two metals also get one broad, soft diagonal band of light,
which is what makes them read as metal rather than as noise. It is a single
static `LinearGradient` overlay (clear, white at `0.5 × strength × 22/255` for
brushed and `0.4 ×` for blasted, clear), running top-left to bottom-right with
its peak just past the middle, added with `.plusLighter`, inside the same mask.
It is not tiled and not animated. If measuring shows it costs frames during a
window resize or a fold, drop it during live resize or drop it altogether and
say so; the tile rule outranks the sheen.

**Drawing.** `carbonGrain(_:)` becomes one entry point,
`carbonShellMaterial(_ material:strength:)` (keep `carbonGrain` as the grain
case's implementation, unchanged, so Carbon stays pixel-identical).
`ChassisLayer` asks the theme for its resolved material and applies it. The
mask is the existing `GrainFreeKey` mask; rename nothing unless it is free.
Nil material: the bare view.

`CarbonTheme` gains one stored `Double` per new dial (`shellPlasticAmount`,
`shellBrushedAmount`, `shellBlastedAmount`, `shellWeaveAmount`,
`coverGridAmount`, `coverPixelAmount`, `coverHandheldAmount`, each read through
`effect(_:_:)` and so clamped like grain, and each a dial's `read`), plus
`coverPixelSize: Double` read raw from `effects` and passed through
`CoverScreenLook.pixelSize(from:)`. The resolved `shellMaterial:
ShellMaterial?`, `shellMaterialStrength`, `coverScreenLook: CoverScreenLook?`
and `coverScreenStrength` are computed from those clamped values, never from
the raw dictionary. `grainAmount` stays, and stays what the grain dial reads.
`ChassisLayer` stops calling `carbonGrain(theme.grainAmount)` directly: a
theme with grain and a material must draw only the material.

**Where it shows.** Everywhere grain shows today (the main window in both
layouts, the About and Guide windows), and nowhere grain is masked out. The
compact player's cover screen is a hole while a look is on; the 1 pt lip
outside it is shell and takes the material. With no look, the compact cover
keeps today's grain over it, because adding a hole there would change Carbon.

The mini player has no grain, so "where grain shows" would leave it bare. It
gets the four new materials (never grain, so Carbon's mini player is
unchanged): `MiniPlayerGlass`, the background both halves are drawn on, takes
`carbonShellMaterial` clipped to its own rounded shape. The window is
transparent, so an unclipped `.plusLighter` layer would draw specks in its
corners. Because the material is on the background only, the art, the glass
display and the keys drawn over it need no holes.

### 4. The cover screen (app)

New file `UI/Carbon/Controls/CoverScreen.swift`:

- **`CoverScreenImage`**: turns an `NSImage` (or `CGImage`) into the LCD
  picture. Resample the cover to `count × count` (or `lcdSide × lcdSide` for
  the grid look) with a high-quality draw into an sRGB `CGContext` first
  filled black (so a transparent PNG cover comes out opaque), aspect-fill and
  centred, so a non-square cover is cropped the way the well crops it today;
  hand the bytes to `CoverScreenRenderer`; wrap the result as an sRGB
  `CGImage` with `shouldInterpolate: false`. Cache in a small shared `NSCache`
  (count limit about 8) keyed by `NowPlayingCover`'s existing `coverKey`
  (track id plus artwork hash, or the stream id) with look, layout and
  strength. Not by `ObjectIdentifier` of the image: the loaders hand back a
  fresh `NSImage` for the same art, and a freed image's identifier can be
  reused by another cover. The work is a few hundred thousand pixels and runs
  once per track; do it off the main thread and show the previous picture (or
  the unlit panel) until it lands, keeping the existing crossfade. Ask the
  loaders for at least `lcdSide` pixels (`maxPixel: max(600, lcdSide)`): a
  theme with tall header and footer geometry can push the compact art past
  600 device pixels.
- **Where the conversion runs.** In `NowPlayingCover`, which already owns the
  loaded `NSImage` (private `@State`), the async loader and the crossfade, and
  is the one view both players use. It takes an optional screen spec (look,
  strength, layout, scale); nil is today's view, untouched. With a spec, its
  `.task(id:)` key adds look, strength and layout, so a theme edit or a scale
  change re-renders once and nothing renders in `body`. A stream's thumbnail
  is an `AsyncImage` (`StreamThumbnail`), which never exposes its image, so
  with a spec the loader fetches `stream.thumbnailURL` itself with
  `URLSession` and converts that.
- **`CoverScreenBezel<Content>`**: the housing. Drawn in points from
  `CoverScreenLayout`, with the corner radius passed in (the compact player
  passes `wellCornerRadius`, the mini player its art frame's existing
  `geometry.scaled(14, following: \.paperCornerRadius)`):
  - the rounded rectangle filled with the bezel colour,
    `theme.oledStrokeInner`, with a slight top-to-bottom darkening (about 8%);
  - the LCD inset by `band`, with a small corner radius (about 2.5 pt), drawn
    at exactly `lcdSide` device pixels with its origin on a whole device pixel
    (see below);
  - the bezel's shadow on the glass: a dark gradient from the LCD's top edge
    (black at 0.42 fading out over 8 pt) and a lighter one from its left edge
    (0.28 over 5 pt);
  - the lip where the bezel meets the shell: a 1 pt stroke just outside the
    well, dark along the top (black 0.45 on a pale shell, 0.75 on a dark one)
    running to a caught light along the bottom (white 0.85 on a pale shell; on
    a dark shell `theme.chassisHi` at about 0.5). "Dark shell" is
    `theme.isDark`, the test `ChassisLayer` and `RecessedWell` already use;
  - no drop shadow. This replaces `RecessedWell` for the art when a look is on.
  - It calls `grainFree` for its rounded rectangle (not the lip).
- **Landing on device pixels.** A resizable image cannot promise this, so the
  LCD is `Image(decorative: lcdImage, scale: displayScale)` with no
  `.resizable()`: an image at its natural size is `lcdSide / scale` points,
  one image pixel per device pixel. Keep `.interpolation(.none)` on it as a
  backstop. It sits `band / scale` points in from the bezel's top-left, then is
  offset by `CoverScreenLayout.pixelSnap` of the bezel's origin in window
  space (a `GeometryReader` reading `.global`), x and y separately. At default
  geometry the compact well's origin is (18, 58) and the mini art's (13, 46),
  whole points, so the offset is 0; it matters for a theme whose geometry
  dials left a fraction. The bezel's own shapes are not snapped. Do not put
  the LCD inside a `.drawingGroup()`.
- **Empty and non-cover states.** With a look on, anything that is not a real
  picture shows an unlit panel: nothing playing, a track with no art (where
  the compact player shows an empty well and the mini player an orange
  gradient today), and a stream whose thumbnail is missing or cannot be
  fetched (`StreamThumbnail` draws a hue gradient). The unlit panel is a flat
  `count × count` source run through the renderer, so its grid is the real
  grid: the colour is `theme.oledSurface` when it is pale (`themeLuminance >
  0.5`, the test `oledSurfaceShade` uses) and otherwise `oledSurface` mixed
  about 40% toward black. A stream's real thumbnail goes through the same
  renderer, cropped to fill, so the screen never shows a photograph beside a
  pixel cover.
- **Off** (`CoverScreenLook.resolve` is nil): today's views, untouched.

**Compact player** (`CompactArtColumn.artWell`): with a look on, the bezel
replaces the `RecessedWell`, at the same `metrics.artSide`. Tap, hover cursor,
tip and accessibility are unchanged.

**Mini player** (`MiniPlayerBody.artFrame` / `artContent` /
`localArtContent`): with a look on, the `.cover` art mode and a stream's
thumbnail are shown through the same bezel and renderer at the art frame's
246 pt (cell 3 at 2x and 1.5 pt gives 156 LCD pixels). `artContent` draws
`StreamThumbnail` directly for a stream, bypassing `NowPlayingCover`; with a
look on, route the stream through `NowPlayingCover` (which already handles
streams) instead. A stream always shows its thumbnail whatever the art mode
(the art key is disabled while one plays), so a stream gets the screen in
`.disc` mode too. The `.disc` art mode for a local track (the spinning record)
is never given a screen look: it is a record, not a screen. Today the art is a
sleeve laid on the card: a `wellDeep` fill, a white 0.16 glare gradient over
the picture, a black 0.6 stroke and a `depthShadow`. With a look on, all four
go and the bezel replaces them (a drop shadow is what makes a screen float).
The frame (246 × 246) and its corner radius stay; the art has no click
behaviour to keep.

**Scale changes.** The layout depends on the backing scale. Read it from the
view's environment (`\.displayScale`) so moving the window between a 1x and a
2x display re-plans the layout and re-renders once. Confirm the value changes
when a window crosses screens (nothing in the app reads it yet; the two places
that need a scale today read `NSScreen.main`, which is wrong for this); if it
does not, observe `NSWindow.didChangeBackingPropertiesNotification`.

**The fold.** Folding mounts `CompactArtColumn` under the veil, so the LCD is
rendered (or found in the cache) while the window travels. That is off the
main thread and lands as one image swap; the cache means a fold back and
forth finds it ready.

### 5. The theme editor

In `ThemeEditorView`, in the Interface section where the grain row is today:

- **Shell material**: the five material rows (grain and the four new), each the
  existing `effectRow` (switch plus strength slider). Switching one on writes 0
  to the other four in the same edit (one assignment to `draft.effects`, so
  one undo step restores the previous material). A hand-written or inherited
  theme can still carry two non-zero keys, so in these rows "on" means "the
  resolved winner", not `value > 0` as `effectRow` tests today; the others
  read OFF. A row's slider is enabled only for the material that is on. The
  editor writes the shared `effects`, as every effect row does today.
- **Cover screen** (new section, shown with the interface effects): the three
  look rows with the same exclusive behaviour, and a stepped control for LCD
  pixel size (1.5, 2, 3, 4 pt), enabled when a look is on, writing
  `effects["coverPixelSize"]` directly the way the monochrome switch writes
  its key. A short note under the heading says where it applies: "Compact
  player and mini player." The editor's search filter needs a `showCover`
  beside `showInterface`, or the section never appears in a filtered list.

`ThemeTokenCatalog` gets the new dials (with notes in the catalog's voice) and
two helpers naming the exclusive groups, so the editor and the tests read one
list. `EffectDialTests` already checks every dial round-trips and clamps; add
tests that each group's keys are exactly the Core enums' `effectKey`s, that
switching one on leaves the others at 0, and that `testBothSurfacesHaveDials`
is extended to the new surface.

The editor's preview (`ThemeSurfaceSimulator`) is a display slab and a paper
card, with no chassis; the app behind the floating editor is the preview for
both features, so the simulator does not change.

### 6. Pocket

`Sources/CrateDiggerApp/Resources/Themes/Pocket.cdtheme/` with `theme.json`
(`"id": "pocket"`, `"name": "Pocket"`, `"author": "CrateDigger"`,
`"version": "1.0"`, `"baseAppearance": "dark"` like the other three, and both
`light` and `dark` layers, which is what makes it adaptive) and
`logo-light.pdf` / `logo-dark.pdf`, named by each layer's `"logo"` key as in
Carbon. The logos come from `scripts/render-theme-logos.swift`: add a
`"pocket"` entry to its `renderers` table (it draws from the theme's own
palette; `BundledThemeTests` checks the 5.5:1 shape). The script rewrites the
PDFs of every theme that has a renderer, so either give it a theme-id argument
or restore the other three themes' logo files afterwards; they must not
change. No trademarked names or marks anywhere in the theme, its `"//"`
comment key or its logo.

The approved colours are in the draft at
`~/Library/Application Support/CrateDigger/Themes/Pocket Draft.cdtheme/theme.json`
on the owner's Mac, reproduced here so the spec stands alone.

Shared: `selectionInk #FFFFFF`.

Light (handheld grey, grey LCD, magenta keys):

```
backgroundBase #B9B6AF  backgroundGradientStart #D9D6CF  backgroundGradientEnd #A5A29B
chassis #C9C6BE  chassisHi #E7E4DD  chassisLo #AAA79F  chassisDeep #6D6A64
well #B8B5AD  wellDeep #8F8C85  paper #E4E1DA  paper2 #D2CFC7  hair #A9A69F
ink #1B1B22  ink2 #3A3A45  ink3 #5F5E66  ink4 #8D8B8C
metal #CFCBC4  metalHi #EDEAE4  metalLo #A29E97  metalDeep #5C5953
orange #A12A5E  orangeHi #C4487C  orangeLo #7A1C45
cyan #2F3699  cyanGlow #A9AEEA  indigo #3A46B5  red #D2362B
sun #E0A21A  sunHi #F3C861  sunLo #A87508
oledSurface #B7BBB0  oledStrokeInner #5A5C66
oledForeground #1F2326  oledForegroundMuted #1F2326A6  onAir #1F2326
selectionLedCore #F0589A  selectionGlow #E24C8B  selectionSpread #D2437F
shadow1 #0F0F0F1A r10 y3   shadow2 #0D0D0D3D r48 y22
```

Dark (indigo console purple, black glass, lavender type):

```
backgroundBase #171233  backgroundGradientStart #3A3172  backgroundGradientEnd #0E0B22
chassis #3B3273  chassisHi #5B50A3  chassisLo #251F4D  chassisDeep #0F0C24
well #2A2356  wellDeep #17123A  paper #1E1842  paper2 #171236  hair #4A4085
ink #F3F0FF  ink2 #CFC8EE  ink3 #9A90C8  ink4 #6A6199
metal #4F4592  metalHi #7568C2  metalLo #2E2760  metalDeep #100D26
orange #E8454A  orangeHi #F47C80  orangeLo #B62A30
cyan #3CCFB4  cyanGlow #BDF5EA  indigo #9C8CFF  red #FF5A5F
sun #F7C92C  sunHi #FFE27A  sunLo #C29A12
oledSurface #06050C  oledStrokeInner #0D0A1C
oledForeground #EDE8FF  oledForegroundMuted #EDE8FF8C  onAir #FF5A5F
selectionLedCore #3CCFB4  selectionGlow #3CCFB4  selectionSpread #3CCFB48D
shadow1 #00000085 r12 y3   shadow2 #000000B8 r54 y24
```

Effects, in the shared top-level `effects` (not in a layer):
`oledMonochrome 1`, `shellPlastic 0.08`, `coverPixel 0.55`,
`coverPixelSize 1.5`. Every colour key above is one `CarbonTheme.init` reads;
anything not listed falls back to `.linen` in the light layer and `.carbon` in
the dark one.

**The lamp rule.** The selection bar is a light-spreading glass over a bulb:
the bulb (`selectionLedCore`), its halo (`selectionGlow`) and the wash across
the row (`selectionSpread`) are one hue in each mode. Add a `BundledThemeTests`
case for Pocket that the three share a hue within 3° in both layers (the
listed values are within about 1°: 334-335° light, 169° dark), so a later edit
cannot split them again.

`BundledThemeTests`'s header comment says "the four themes"; with Pocket it
becomes true again (Carbon, Cobalt, Llama '97, Pocket). No test counts or
orders the bundled themes today. The picker (`ThemeRegistry.refresh`) sorts
defaults first, then by name, so Pocket lands last of the four.

When the bundled theme exists, the draft in the user's themes folder is the
owner's to delete; do not touch it from code or scripts.

### 7. Debug hooks and checking it

- `CRATEDIGGER_COMPACT=1` with `CRATEDIGGER_SNAPSHOT_PATH` already snapshots
  the compact player (the `late` snap at 8 s). Launch arguments
  `-cratedigger.ui.selectedThemeID pocket -CrateDigger.appearanceMode light`
  pick the theme and mode without writing preferences. The argument domain
  only shadows reads: the fold still writes `compact` to the stored
  `cratedigger.ui.playerLayout`. So pass `-cratedigger.ui.playerLayout full`
  on every checking launch (each then starts full whatever the last ended
  as), and expect the next ordinary launch to open compact until it is
  expanded once.
- The snapshot hook renders the window's own view tree
  (`cacheDisplay(in:to:)`), so a tiled overlay, its blend modes and an
  un-interpolated image must all survive it. If any does not, say so and check
  by screen capture instead. Other visible windows are written as their own
  PNGs; the mini player's window has no title, so it lands as `sheetN`.
- A cover in the compact well needs something playing. `CRATEDIGGER_COMPACT=play`
  starts the first track on disk, which makes sound; prefer a DEBUG-only hook
  that puts a named image file in the well (for example
  `CRATEDIGGER_COVER=<path>`, read by `NowPlayingCover`'s loader in place of
  the track's art and shown even with nothing playing) so the screen can be
  snapshotted silently. The mini player has no launch hook; add
  `CRATEDIGGER_MINI=1`, calling the same path as Window ▸ Mini Player
  (`showMiniPlayer`). Add both beside the other hooks in `AppDelegate`, DEBUG
  only.
- Compare against the mockups by eye: Pocket light and dark, compact and full,
  each look, each material at its `on` strength. Then Carbon, Cobalt and
  Llama '97 before and after: they must not change. Cobalt and Llama '97 can be
  compared by pixel diff. Carbon cannot: its grain tile is re-randomised on
  every launch (`noiseTile` uses `SystemRandomNumberGenerator`), so two Carbon
  snapshots never match even with no change; compare it by eye, or diff with
  grain forced off on both sides.
- Idle check: with Pocket on and the window still, CPU and GPU in Activity
  Monitor should match Carbon's. Fold and unfold with Pocket on and confirm it
  is no rougher than with Carbon. The veil's still is made by
  `CALayer.render(in:)` (`ConsoleContainerViewController.blurredSnapshot`),
  which can draw blend modes as plain source-over and ignore masks, so the
  material may sit in the still slightly differently than live. At quarter
  scale under a 22 pt blur it averages to a near-even shift; look for a
  brightness step as the veil rises and clears, most likely with blasted
  metal and the sheen.

### 8. Docs

- `CLAUDE.md`: in the Carbon design-system section, a short paragraph on shell
  materials (one at a time, tiles only, the exclusive dial group and its Core
  resolver) and on the cover screen (where it applies, whole-device-pixel rule,
  `CoverScreenLayout`), and a line naming the four built-in themes (it lists
  none today).
- `CHANGELOG.md` is written at release time by the release macro, not here.

## Left to the builder

- File and type names where the spec says "or".
- The exact shadow and lip opacities of the bezel, tuned by eye against the
  mockup in both modes.
- Whether the sheen survives measurement.
- How the editor lays out two exclusive groups in the space it has.
- How dark the unlit panel is on a dark `oledSurface`, tuned by eye from the
  40% starting point.

## Decisions made without the owner (flag these when handing over)

- Effects stay numbers; materials and looks are exclusive dial groups rather
  than a new enum field in the theme file.
- Material priority puts grain last.
- A look's dial value is its grid strength, so grid strength 0 means off.
- Pixel size steps are 1.5, 2, 3, 4 pt, default 1.5, and a cell is never
  smaller than 3 device pixels (so the look is not dark on a 1x screen).
- The look applies to stream thumbnails as well as covers, and never to the
  mini player's spinning record.
- The bezel uses the display's bezel colour (`oledStrokeInner`).
- Pocket uses the normal fonts and geometry and a single-colour display in both
  modes.
- Added in the code check:
  - The mini player gets the four new materials on its glass, never grain (it
    has none today, and giving it grain would change Carbon).
  - With no look, the compact player's cover keeps the grain Carbon draws over
    it today; it is not made a hole, since that would change Carbon.
  - In the mini player, a look removes the sleeve's glare, stroke and drop
    shadow along with the sleeve; frame size and corner stay.
  - Anything that is not a real picture (nothing playing, a track with no art,
    a stream with no reachable thumbnail) shows the unlit panel, replacing the
    mini player's orange placeholder and a stream's hue gradient.
  - In an exclusive group, a row reads ON only for the resolved winner.
  - The default pixel size gives 145 LCD pixels in the compact well, not 144:
    the art side is 230 pt, not 228.
