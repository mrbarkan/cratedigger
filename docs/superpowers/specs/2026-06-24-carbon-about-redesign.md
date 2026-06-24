# Carbon About Redesign — Design Note

Date: 2026-06-24
Status: Approved (visual mockup approved by user)

## Goal

Replace the dated light "design-package" About window (white glass cards, old
crate artwork) with a Carbon hardware faceplate that matches the app and the new
Carbon-chassis app icon.

## Direction (approved)

- Carbon hardware faceplate; "keep highlights" content level.
- Follows the app's light/dark Carbon appearance (not always-dark).

## Layout — split faceplate (~720×500)

- **Left bay:** a recessed well cradling the app icon, like a seated device.
- **Right column:**
  - Eyebrow: `MODERN-RETRO AUDIO WORKBENCH` (mono, cyan)
  - Title: `CrateDigger`
  - Tagline: two-line summary
  - OLED strip: `VERSION <x> · BETA <n>` (orange) + `CREATED BY MRBRKN SMASH` (ink), LED dot
  - Three feature rows: SCAN / PREVIEW / CONVERT — accent dot + label + one-line desc
  - Footer: `smash.mrbarkan.com` link (cyan) + `macOS · Swift · AppKit · FFmpeg`

## Architecture

- Rebuild as a SwiftUI `CarbonAboutView` hosted in the existing `NSWindow` via
  `NSHostingController`, reusing the Carbon theme (`\.carbon`) + `CarbonFont` +
  recessed-well / OLED styling. Themed with the current `AppearanceMode`
  (mirrors `CarbonRootView`).
- Retire the AppKit `AboutViewController` body and the crate-era brand helper
  views (`BrandArtworkView`, `GlassCardView`, `BrandPillView`,
  `BrandFeatureRowView`, `BrandBackdropView`, `BrandArtworkPalette`) **iff** they
  are unused elsewhere; otherwise leave them.
- Render the hero icon as a **faithful SwiftUI vector** (`CarbonChassisIconView`)
  rather than a bundled PNG. The app target has no resource bundle, and adding
  SPM `resources:` would force the packaging script to copy the generated
  `.bundle` (and `Bundle.module` fatal-errors if it's missing — a crash risk in
  the packaged build). A vector renders crisply in dev + packaged, is
  theme-aware, and matches the app's all-vector aesthetic.
- Version text sourced from the bundle with `AppVersion` fallback (same path as
  the version pill).

## Out of scope

- Splash artwork refresh.
- Tahoe Icon Composer `.icon` (separate follow-up).
