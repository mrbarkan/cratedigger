# Theming CrateDigger

CrateDigger's "Carbon" hardware look is a themeable skin system, the same way
a Winamp `.wsz` reskins Winamp: drop a file in a folder, pick it from a menu,
done. No Swift, no rebuild, no restart.

This document is for anyone building a theme. If you're working on the app
itself, see `CLAUDE.md` for the underlying architecture
(`ThemeDefinition` → `ThemeLoaderService` → `ThemeRegistry` → `CarbonTheme`/`CarbonGeometry`).

## Installing a theme

Themes live in:

```
~/Library/Application Support/CrateDigger/Themes/
```

CrateDigger creates this folder automatically. Drop either of these in:

- A bare `MyTheme.json` file (colors/fonts/geometry only), or
- A `MyTheme.cdtheme/` folder containing `theme.json`, plus an optional
  `Fonts/` subfolder of `.ttf`/`.otf` files if your theme uses a custom
  typeface.

Then in the app, open the **THEME** menu in the header (next to VIEW/EQ) →
**Refresh Themes**, and your theme appears in the list. Selecting it applies
immediately — no restart. **Show Themes Folder…** in the same menu opens the
folder in Finder.

A `.cdtheme` folder is the shareable unit: zip it up and send it to someone,
same as a Winamp skin file.

## The `theme.json` schema

Every field except `id`, `name`, and `baseAppearance` is optional. Omit
anything you don't want to change — CrateDigger fills it in from a base theme
(see `inherits` below). A theme that only overrides 3 colors is exactly as
valid as one that overrides everything.

```jsonc
{
  "id": "sunset-vinyl",           // stable slug, used for inherits + selection
  "name": "Sunset Vinyl",         // shown in the THEME menu
  "author": "Jane Doe",           // optional
  "version": "1.0",               // optional, informational

  "baseAppearance": "dark",       // "light" or "dark" — drives window chrome
                                   // (picking a theme is picking its appearance,
                                   // same as picking a Winamp skin)

  "inherits": "carbon",           // "linen", "carbon", or another installed
                                   // theme's id — every token you don't set
                                   // below is filled in from this theme

  "colors": { "orange": "#FF6236", "...": "..." },
  "shadows": { "shadow1": { "color": "#00000085", "radius": 12, "x": 0, "y": 3 } },
  "fonts": { "mono": "JetBrainsMono-Regular" },
  "geometry": { "chassisCornerRadius": 4, "playButtonSize": 90 }
}
```

### `colors`

Hex strings, `"#RRGGBB"` or `"#RRGGBBAA"` (leading `#` optional). These match
`CarbonTheme`'s tokens 1:1:

| Group | Tokens |
|---|---|
| Chassis (outer case) | `chassis`, `chassisHi`, `chassisLo`, `chassisDeep` |
| Well (recessed panels) | `well`, `wellDeep` |
| Paper (inset content panels) | `paper`, `paper2` |
| Text/ink | `ink`, `ink2`, `ink3`, `ink4`, `hair` |
| Accents | `orange`, `orangeHi`, `orangeLo`, `sun`, `sunHi`, `sunLo`, `cyan`, `cyanGlow`, `red`, `indigo` |
| Metal (knob/chrome bevels) | `metalHi`, `metal`, `metalLo`, `metalDeep` |
| Background wash | `backgroundBase`, `backgroundGradientStart`, `backgroundGradientEnd` |
| OLED display | `oledSurface`, `oledStrokeInner`, `oledForeground`, `oledForegroundMuted`, `onAir` |
| Selection | `selectionLedCore`, `selectionInk` |

A few colors are intentionally **not** themeable — they represent fixed
hardware materials rather than a "finish": the amber VU-meter LEDs, the
Conversion Patch Bay's dark steel housing, and the vinyl record's grey. These
stay constant across every theme, the same way a Winamp skin couldn't recolor
an LED that was drawn into the bitmap.

> **Known limitation:** the OLED display's glass foreground text is drawn
> through a small set of shared helpers (`oledFG`/`oledFGo` in
> `OLEDDisplay.swift`) that predate the theme system and default-parameter
> off a fixed value rather than reading the active theme per call site.
> Setting `oledForeground`/`oledForegroundMuted`/`onAir` in your theme is
> supported by the schema and by `CarbonTheme`, but won't yet visibly change
> the OLED display's ~50 call sites — this is flagged as a follow-up, not a
> silent no-op you need to work around.

### `shadows`

`shadow1` (small, tight) and `shadow2` (large, soft ambient) — used for the
chassis/panel drop shadows. Each has `color` (hex, alpha included or via a
separate `opacity`), `radius`, and optional `x`/`y` offsets (default `0`).

### `fonts`

Maps a semantic role to a PostScript font name:

| Role | Used for |
|---|---|
| `mono` | OLED numerics, tags, monospace UI text |
| `sans` | General UI text |
| `display` | Large display/logo text |

Ship the actual font files in your `.cdtheme`'s `Fonts/` folder (`.ttf`/`.otf`)
and reference their PostScript name (not the file name) here. If a name isn't
found — a typo, or you didn't ship the font — CrateDigger silently falls back
to the system font. You can't break the app by getting a font name wrong.

### `geometry`

Corner radii and control sizes, matching `CarbonLayout`'s fields
(`chassisCornerRadius`, `wellCornerRadius`, `paperCornerRadius`,
`oledCornerRadius`, `headerHeight`, `footerHeight`, `sidebarWidth`,
`inspectorWidth`, `mainGap`, `chassisInsetH`/`chassisInsetV`/`chassisRowGap`,
`brandWidth`, `viewSwitchWidth`, `transportButtonSize`, `playButtonSize`,
`keyHeight`, and the `patchBay*` set). Values are **clamped** to safe ranges —
unlike a bad color (which just looks ugly), bad geometry could break layout,
so an extreme value (e.g. `"playButtonSize": 999`) is silently capped rather
than producing a broken window. Omit anything you don't want to change; the
defaults are CrateDigger's shipped layout.

## `inherits` and partial themes

`inherits` is what makes a 3-color theme possible. Point it at `"linen"`,
`"carbon"`, or any other installed theme's `id`, and every token you don't
set is copied from there — colors, shadows, fonts, and geometry all merge
independently, so you can override just `geometry.playButtonSize` while
inheriting every color from `carbon`.

If `inherits` names a theme that isn't installed (a typo, or a theme that
references another user's custom theme they don't have), CrateDigger doesn't
error — it just leaves those tokens unset, and they fall back to whichever
built-in matches your `baseAppearance`.

## A complete minimal example

```json
{
  "id": "sunset-vinyl",
  "name": "Sunset Vinyl",
  "author": "Jane Doe",
  "baseAppearance": "dark",
  "inherits": "carbon",
  "colors": {
    "orange": "#FF8A3D",
    "cyan": "#3DBBFF",
    "chassis": "#241713"
  }
}
```

Save this as `~/Library/Application Support/CrateDigger/Themes/SunsetVinyl.json`,
hit Refresh in the THEME menu, and select it — everything else (chassis
bevels, OLED, transport, geometry) renders exactly like Carbon except for
those three colors.

## Built-in themes as reference

CrateDigger's own **Linen** and **Carbon** themes ship in this exact format
under `Sources/CrateDiggerApp/Resources/Themes/` — open either `theme.json`
as a full worked example of every color token in use.
