# Tahoe Liquid Glass Icon — Icon Composer Steps

The packaged app already ships a proper multi-size `CrateDigger.icns`
(`Packaging/CrateDiggerApp/Resources/`), which renders correctly on macOS 13–26.
On Tahoe (macOS 26) it shows as a standard icon — it does **not** get the new
Liquid Glass treatment (specular highlights, dark/tinted/clear variants). To
opt into that, author a `.icon` with **Icon Composer** (ships with Xcode 26) and
compile it into the bundle. This is optional for the beta.

Master art: `Branding/Icon/Tahoe/CrateDigger-1024-fullbleed.png` (full-bleed,
1024×1024, no baked rounded-rect — the system applies the mask).

## 1. Author the `.icon`

1. Launch Icon Composer: **Xcode → Open Developer Tool → Icon Composer**
   (or Spotlight → "Icon Composer").
2. **File → New**, name it `AppIcon`.
3. Drag `CrateDigger-1024-fullbleed.png` onto the canvas as the base layer.
   - For the best glass effect, split the art into layers — e.g. *chassis*
     (background), *vinyl + spindle*, *OLED meter + LED* — each as its own
     transparent PNG, stacked back-to-front. Icon Composer adds depth/specular
     per layer. A single flat layer also works (less depth).
4. Leave the art **full-bleed**; do not add your own rounded corners or margins.
   The grid/mask preview shows how Tahoe will round it.
5. Set appearances in the inspector:
   - **Default** — the art as-is.
   - **Dark** — Icon Composer derives one; tweak the background if needed.
   - **Clear / Tinted** — optional; the chassis already reads well monochrome.
6. **File → Save** → produces `AppIcon.icon` (a bundle). Keep it in
   `Branding/Icon/` next to the other sources.

## 2. Integrate into the build

This app builds with SwiftPM + `scripts/package-app.sh`, **not** an Xcode project
with an asset catalog, so the `.icon` can't be dropped into `Assets.xcassets`
the easy way. Two options:

### Option A — keep the `.icns` for the beta (current, recommended for now)
Nothing to do. Tahoe renders the `.icns` fine; you skip Liquid Glass until 1.0.

### Option B — compile the `.icon` with `actool` (full Tahoe treatment)
Add an asset catalog containing the `.icon`, compile it into the bundle, and
point `Info.plist` at it by name.

1. Make `Branding/Icon/CrateDigger.xcassets/` and move `AppIcon.icon` inside it
   (Icon Composer can also export the catalog directly).
2. In `scripts/package-app.sh`, after copying resources, compile the catalog:
   ```bash
   xcrun actool "Branding/Icon/CrateDigger.xcassets" \
     --compile "${APP_BUNDLE}/Contents/Resources" \
     --app-icon AppIcon \
     --output-partial-info-plist /tmp/cd-actool.plist \
     --platform macosx --minimum-deployment-target 13.0 \
     --target-device mac
   ```
   This writes `Assets.car` (+ any `.icns`) into `Contents/Resources`.
3. In `Packaging/CrateDiggerApp/Info.plist`, add:
   ```xml
   <key>CFBundleIconName</key>
   <string>AppIcon</string>
   ```
   Keep `CFBundleIconFile` → `CrateDigger` as the pre-Tahoe fallback.
4. Repackage and verify in the Dock/Finder on a Tahoe machine.

> Note: `actool` needs full Xcode (the packaging script already requires it for
> signing). Verify the `.icon` schema matches the installed Xcode's Icon
> Composer version.

## Checklist
- [ ] `AppIcon.icon` authored from the full-bleed master (layered if possible)
- [ ] Default + Dark appearances set
- [ ] Beta: ship as-is (`.icns`), or 1.0: wire Option B and verify on Tahoe
