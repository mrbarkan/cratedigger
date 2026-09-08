# Llama '97 fonts

The skin's type, shipped inside the theme the way a third-party `.cdtheme`
ships its own. Registered at launch by `FontRegistrar.registerBundledFonts()`,
which walks every bundled theme's `Fonts/` folder.

| File | Role | Why | Licence |
|---|---|---|---|
| `Silkscreen-Regular.ttf`, `Silkscreen-Bold.ttf` | `display` | Winamp's `text.bmp` ticker is a 5x6 uppercase bitmap font; Silkscreen is that face as a TTF. | SIL OFL 1.1, `LICENSE-Silkscreen-OFL.txt`. Jason Kottke, via google/fonts `ofl/silkscreen`. |
| `PixelOperatorMono8.ttf`, `PixelOperatorMono8-Bold.ttf` | `mono` | The EQ's `60 170 310`, `PRESETS`, the `Add Del Sel Misc` keys: tiny bold pixel sans. Monospaced so counts align; 8px grid, crisp at 8pt on Retina. | CC0 1.0, `LICENSE-PixelOperator-CC0.txt`. Jayvee Enaguas, via dafont `pixel_operator`. |

The `sans` role is Arial (`ArialMT` / `Arial-BoldMT`), which every Mac has and
which is literally the default in Winamp's `pledit.txt`. Nothing to ship.
