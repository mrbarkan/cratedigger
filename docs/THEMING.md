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
  typeface, and an optional logo image next to `theme.json` (see `logo`
  below).

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

  "inherits": "carbon",           // "carbon" (or another installed theme's
                                   // id) — every token you don't set below is
                                   // filled in from this theme

  "colors": { "orange": "#FF6236", "...": "..." },
  "shadows": { "shadow1": { "color": "#00000085", "radius": 12, "x": 0, "y": 3 } },
  "fonts": { "mono": "JetBrainsMono-Regular" },
  "logo": "logo.png",             // image beside theme.json, shown in the header
  "geometry": { "chassisCornerRadius": 4, "playButtonSize": 90 },
  "effects": { "oledScanlineOpacity": 0.05 }
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
| Lamps | `lampNow`, `lampConvert`, `lampScan`, `lampSync`, `lampCD`, `lampDevices`, `lampSearch` (the screen annunciators), `transportLamp` (the LED behind the silicone transport caps), `keyLamp` (the LEDs on the VIEW, THEME and EQ keys, sheet title dots and the activity lamp), `meterHot` (the loud end of the VOLUME ramp, the EQ bars and the VU LEDs, which run from `cyan` up to it). Each falls back to the accent it borrows when unset, so a theme whose keys are black can still light its LEDs and meters. |

A few colors are intentionally **not** themeable — they represent fixed
hardware materials rather than a "finish": the amber VU-meter LEDs, the
Conversion Patch Bay's dark steel housing, and the vinyl record's grey. These
stay constant across every theme, the same way a Winamp skin couldn't recolor
an LED that was drawn into the bitmap.

The OLED tokens recolor the display glass end to end:
`oledSurface`/`oledStrokeInner` are the panel itself,
`oledForeground`/`oledForegroundMuted` the phosphor text (a green-phosphor
terminal or amber VFD look is three color overrides away), and `onAir` the
radio lamp.

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

### `logo`

The file name of an image sitting next to `theme.json` inside your `.cdtheme`
folder, for example `"logo": "logo.png"`. PNG, JPEG, PDF and SVG all work, and
a vector PDF stays crisp at any size. CrateDigger draws it in the header on
the right, opposite its own name, scaled to fit a strip 110 by 20 points (5.5
to 1), so a wide mark reads best. Without one, the theme's `name` is set there
in the same type as "CrateDigger", so every theme has a mark.

A light and a dark layer can each name their own file, since a mark drawn for
a dark console rarely survives a light one:

```jsonc
"logo": "logo.png",                      // shared, used by any layer without its own
"light": { "logo": "logo-light.png" },
"dark":  { "logo": "logo-dark.png" }
```

The three built-in themes ship this way; their marks are drawn by
`scripts/render-theme-logos.swift` from each theme's own palette.

A logo is not inherited (the file lives in your bundle, not the parent's), and
a bare `.json` theme cannot carry one.

In the theme editor, the BRAND section shows the header row at actual size
with your mark in place. Choose an image with FILE, or drop one onto the
section, and it opens in a crop table the shape of the slot: drag to move it,
pinch or use the SIZE fader to scale it (FIT shows the whole image, FILL
covers the strip), then APPLY renders it into the theme as `logo.png`, or
`logo-light.png` / `logo-dark.png` when the theme has both looks and you are
editing one of them. ADJUST reopens the shipped mark for reframing; CLEAR
removes it from the layer you are editing and leaves the other alone.

### `geometry`

Corner radii and control sizes, matching `CarbonLayout`'s fields
(`chassisCornerRadius`, `wellCornerRadius`, `paperCornerRadius`,
`oledCornerRadius`, `keyCornerRadius`, `headerHeight`, `footerHeight`, `sidebarWidth`,
`inspectorWidth`, `mainGap`, `chassisInsetH`/`chassisInsetV`/`chassisRowGap`,
`brandWidth`, `viewSwitchWidth`, `transportButtonSize`, `playButtonSize`,
`keyHeight`, and the `patchBay*` set). Values are **clamped** to safe ranges —
unlike a bad color (which just looks ugly), bad geometry could break layout,
so an extreme value (e.g. `"playButtonSize": 999`) is silently capped rather
than producing a broken window. Omit anything you don't want to change; the
defaults are CrateDigger's shipped layout.

### `effects`

Display-effect strengths, clamped to safe ranges like `geometry`:

| Key | What it does | Range |
|---|---|---|
| `oledScanlineOpacity` | CRT scanline strength on the OLED glass. `0` turns scanlines off; the built-ins use `0.018`. | `0`–`0.15` |
| `flat` | Drops every cast shadow in the interface — panels, keys, the display glass, album covers. Bevels, gradients and glows stay, so the console reads as printed rather than moulded. | `0` off, `1` on |
| `oledMonochrome` | Makes the display a single-emitter panel: everything drawn on the glass — lit annunciators, meters, the ON AIR lamp — is `oledForeground` at whatever brightness it had, instead of the theme's accents. The chassis is untouched. | `0` off, `1` on |

## `inherits` and partial themes

`inherits` is what makes a 3-color theme possible. Point it at `"carbon"` or
any other installed theme's `id`, and every token you don't set is copied
from there — colors, shadows, fonts, geometry, and effects all
merge independently, so you can override just `geometry.playButtonSize` while
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

CrateDigger's own themes ship in this exact format under
`Sources/CrateDiggerApp/Resources/Themes/` — open any `theme.json` as a full
worked example of every color token in use. **Carbon** is the one to copy for
a light/dark pair: its shared block holds what both looks agree on, and the
`light`/`dark` layers hold only what each one changes.

Note that inheriting an adaptive theme inherits its *layers* too, so a `light`
or `dark` block in the parent overrides a shared token you set in the child.
Set such a token in your own layers (or drop `inherits`) when that bites.

## Editing the built-in themes (beta only)

Normally the editor **forks** a shipped theme: opening Carbon gives you
"Carbon Copy", a user theme that inherits from it, saved into
`~/Library/Application Support/CrateDigger/Themes/`. That is right for anyone
running the app, because the built-ins live inside the app bundle.

While 2.0 is in beta the defaults are still being tuned, so a development
build opens them **in place** instead. Saving writes straight to
`Sources/CrateDiggerApp/Resources/Themes/<Theme>.cdtheme/theme.json` in the
checkout the app was compiled from, and to the copy inside the running build's
resource bundle so the change appears without a rebuild.

What that means in practice:

- Only the tokens you actually touch are written, so a token the theme leaves
  unset stays unset. That matters for the screen lamps, which follow the
  accent until something pins them.
- The first save on a given theme reformats it into the canonical sorted form
  the editor writes, so expect one large mechanical diff per theme and small
  ones after that. Any key the schema does not model, such as the `"//"` note
  in `Llama 97`, is carried across untouched.
- Re-render the marks with `swift scripts/render-theme-logos.swift` if the
  palette moved, then run `scripts/test.sh --filter BundledThemeTests`.

This is deliberately temporary. `BuiltInThemeEditing.isOpen` in
`Sources/CrateDiggerApp/UI/Theme/BuiltInThemeEditing.swift` turns it off for
the RC, and it never applies to a packaged build in any case: it does nothing
unless the app can see the checkout it was built from.
