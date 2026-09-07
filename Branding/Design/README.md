# CrateDigger brand canvas (2.0)

Source for the 2.0 brand direction: the logo mark and wordmark, the app icon
package, and the About window in both appearances. The live, editable canvas is
at https://claude.ai/code/artifact/1245b8ee-8a01-427c-91a2-443796b07c78

## What is here

- `build.mjs` draws the two shared pieces once and expands them into every
  artboard: `icon(size, variant)` is the app icon (the record as the icon,
  with `dark` / `clear` / `tinted` Tahoe appearances and `l1` / `l2` / `l3`
  Icon Composer layers) and `mark(size, ink, orange, paper)` is the flat glyph
  the wordmark uses. It also derives `AboutLight` from `About` by swapping the
  Carbon dark tokens for the light ones.
- `*.tpl.html` are the artboards with `<!--ICON:...-->` and `<!--MARK:...-->`
  markers where those drawings go. `canvas.json` lays them out.

## Decisions baked in

- Wordmark: Major Mono Display, the face the OLED already speaks in every
  theme. Inter and JetBrains Mono stay for everything else.
- Lockup: the mark box is 0.807 x the type size so its ink equals Major Mono's
  cap height (0.696 em), nudged down 0.072 x box so it centres on the caps;
  the panel sits on the baseline and the gap is a third of the type size.
- Icon: orange plate (`#FF8A5C` to `#E5552B`), black disc with two deep
  grooves and fine ones between, paper label with an orange spindle. Full
  bleed at 1024; the system applies the squircle.
- About: same faceplate as today plus the lockup under the icon, two chrome
  keys (Check for Updates, Release Notes), and no dashes in copy.

## Rebuild

```bash
cd Branding/Design && node build.mjs     # writes the .dc.html artboards
```

Then seed them into a canvas with the `/design` skill, or open the artboards
directly in a browser (serve the folder over http; `file://` is blocked).
