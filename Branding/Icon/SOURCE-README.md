# CrateDigger — macOS App Icon Build

Everything here is generated from the 2048×2048 master (`branding/icon.png`).
Two delivery tracks, so the app looks right on **macOS Tahoe (26)** *and* every
earlier release.

```
build/
├─ AppIcon.appiconset/          ← Xcode asset catalog (backwards compatible)
│   ├─ Contents.json
│   └─ icon_16 / 32 / 64 / 128 / 256 / 512 / 1024 .png
├─ CrateDigger.iconset/         ← raw named slices for iconutil → .icns
│   └─ icon_16x16 … icon_512x512(-2x).png
├─ Tahoe/
│   ├─ CrateDigger-1024-fullbleed.png   ← import into Icon Composer (Liquid Glass)
│   └─ CrateDigger-1024-master.png      ← transparent-corner reference
├─ build-icons.sh              ← fixes @2x names + runs iconutil
└─ README.md
```

## 1 · Backwards-compatible icon (macOS 13–26, all of it)

**Option A — Asset catalog (recommended for an Xcode app):**
Drag `AppIcon.appiconset/` into `Assets.xcassets`. Set
*Target → General → App Icon* to `AppIcon`. Done. Covers 16→1024 @1x/@2x.

**Option B — `.icns` (SPM bundle, AppKit `NSImage`, `CFBundleIconFile`):**
```bash
cd build
chmod +x build-icons.sh
./build-icons.sh          # → CrateDigger.icns
```
The script first restores the `@2x` filenames (the export tool writes `-2x`
because it can't put `@` in a name), then calls `iconutil -c icns`.

## 2 · macOS Tahoe Liquid Glass icon (macOS 26)

Tahoe renders app icons through Icon Composer with light / dark / clear / tinted
glass variants. Author it once, ship the `.icon`, and older systems automatically
fall back to track 1 above.

1. Open **Icon Composer** (bundled with Xcode 26).
2. Drag in `Tahoe/CrateDigger-1024-fullbleed.png` as the base layer. For real
   depth, split the artwork into layers (chassis plate → OLED meter → grille →
   vinyl disc → LED) and drop each on its own layer so the system can apply
   parallax + specular highlights.
3. Export `CrateDigger.icon` and add it to the Xcode target. Set *App Icon* to it.
4. Keep `AppIcon.appiconset` in the project — it's the fallback for < macOS 26.

### Notes
- The master has the squircle/rounded-rect baked in — correct for classic macOS.
  Icon Composer applies its **own** superellipse mask, so the full-bleed PNG is
  the one to feed it (not the rounded master).
- The icon is re-authored as vector from the Carbon branding design, so every
  size is rasterized crisply (not downscaled from one bitmap). If 16/32px read
  busy in the menu bar, ask and I'll cut a simplified vinyl-only glyph for those
  slots.
