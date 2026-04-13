# CrateDigger Design Package

This package gives CrateDigger a coherent visual system built around a single idea: a modern-retro record crate with a scan beam passing across a vinyl disc. It keeps the app's light AppKit chrome, but adds a stronger identity so the brand feels deliberate in the Dock, in launch artwork, and inside the About screen.

## Visual Direction

- Core motif: record crate + vinyl disc + scan beam
- Tone: polished utility, tactile music hardware, light modern-retro desktop
- Primary colors:
  - `Paper`: `#F4F7FB`
  - `Mist`: `#E3EBF7`
  - `Slate`: `#262D3A`
  - `Cyan`: `#2BB8F7`
  - `Amber`: `#FFC939`
  - `Coral`: `#EB634A`

## Deliverables

- App icon bundle: [Packaging/CrateDiggerApp/Resources/CrateDigger.icns](/Users/mrbarkan/Development/CrateDigger/Packaging/CrateDiggerApp/Resources/CrateDigger.icns)
- Icon preview: [Branding/Generated/CrateDiggerIcon-1024.png](/Users/mrbarkan/Development/CrateDigger/Branding/Generated/CrateDiggerIcon-1024.png)
- Splash artwork: [Branding/Generated/CrateDiggerSplash.png](/Users/mrbarkan/Development/CrateDigger/Branding/Generated/CrateDiggerSplash.png)
- About screen preview: [Branding/Generated/CrateDiggerAboutPreview.png](/Users/mrbarkan/Development/CrateDigger/Branding/Generated/CrateDiggerAboutPreview.png)
- Regeneration script: [scripts/generate-brand-assets.swift](/Users/mrbarkan/Development/CrateDigger/scripts/generate-brand-assets.swift)

## Notes

- macOS apps do not typically ship with an automatic splash screen the way iOS apps do, so the splash asset here is provided as branded launch artwork and a ready-to-integrate visual if you decide to add a startup panel later.
- The About window is implemented directly in AppKit so it matches the generated art without depending on bundle resources at runtime.
- If you want to refresh the package after tweaking the concept, run:

```bash
swift scripts/generate-brand-assets.swift
```
