# Changelog

All notable changes to CrateDigger are documented here. Versions follow
[semantic versioning](https://semver.org); the number in parentheses is the
build, which is monotonic across every release.

## 1.0.1 (38) — 2026-07-08

### Added
- **Floating artwork panel (FLOAT).** The album-art viewer can pop out into a
  small, chromeless, always-on-top panel that stays open while you keep working
  in the app — reference a cover or read a booklet while editing tags. Its frame
  lights up on hover, and it drags and resizes freely.
- **System media keys & Now Playing.** Hardware media keys (F7/F8/F9), AirPods
  gestures, Control Center, and the macOS Now Playing widget now drive playback,
  and show the current track's title, artist, album, and artwork.
- **Freeform folder-pattern editor.** The conversion PATTERN is now a row of
  draggable tags. Reorder them by dragging, and tap the gap between two tags to
  toggle `/` (new folder) ↔ `·` (same folder) — so you can build any structure,
  e.g. `Album Artist / Year Album / tracks`. A live preview shows the result, a
  Genre tag was added, and the layout persists per external device.

### Changed
- The Convert patch bay shows a discrete "more below" indicator when settings
  rows scroll out of view.

## 1.0.0 — 2026-07-05

- First public release.
