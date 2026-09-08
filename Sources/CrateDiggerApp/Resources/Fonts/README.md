# Bundled fonts

The faces `CarbonFont` names as the app's defaults, shipped so every Mac draws
what the author's does. Registered at launch by
`FontRegistrar.registerBundledFonts()`. `BundledFontTests` fails if a face
`CarbonFont` names is missing from this folder.

Until 2.0.3 only Major Mono Display was here. Inter and JetBrains Mono resolved
on the author's Mac from `~/Library/Fonts` and nowhere else, so every other
copy of the app fell back to Helvetica for all its interface and label type,
and nothing in the code could tell.

| Family | Faces | Role | Licence |
|---|---|---|---|
| Inter 4.1 | Regular, Medium, SemiBold, Bold, ExtraBold | `sans` — titles, artist names, body text | SIL OFL 1.1, `LICENSE-Inter-OFL.txt`. rsms/inter release zip, `extras/ttf/`. |
| JetBrains Mono 2.304 | Regular, Medium, SemiBold, Bold | `mono` — small uppercase labels, counts, readouts | SIL OFL 1.1, `LICENSE-JetBrainsMono-OFL.txt`. JetBrains/JetBrainsMono release zip, `fonts/ttf/`. |
| Major Mono Display | Regular | `display` — the OLED's big names | SIL OFL 1.1. |

Static faces, not the variable fonts: CoreText exposes a variable font only
under its default instance's name, so `JetBrainsMono-Bold` resolved to
Helvetica even where the variable file was installed.

A theme's own type lives in its `.cdtheme/Fonts/` folder instead; see
`Themes/Llama 97.cdtheme/Fonts/README.md`.
