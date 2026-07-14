# Changelog

All notable changes to CrateDigger are documented here. Versions follow
[semantic versioning](https://semver.org); the number in parentheses is the
build, which is monotonic across every release.

## 1.1.0 (40) — BETA 1 — 2026-07-14

### Added
- **Theming ("skins").** CrateDigger's Carbon look is now a themeable skin
  system, the same way a Winamp `.wsz` reskins Winamp: drop a `.cdtheme`
  folder (colors, shadows, fonts, geometry, plus optional custom typefaces)
  into `~/Library/Application Support/CrateDigger/Themes/`, pick it from the
  new THEME menu, done — no rebuild, no restart. Themes can partially
  override another installed theme via `inherits`, so a 3-color reskin is as
  valid as a full one. Ships with two bundled themes, Carbon and Linen; see
  `docs/THEMING.md` for the format if you want to build your own.

This is a beta build — the theming system is new and hasn't seen wide use
yet. Everything from 1.0.2 (FIX TAGS, artwork search image counts, the empty
media-case placeholder, the disc tray, and the mini player / EQ / Now
Playing fixes) is included.

## 1.0.2 (39) — 2026-07-14

### Added
- **FIX TAGS.** A one-press repair for tracks that lost their track number on
  import (e.g. scanned before ffmpeg/ffprobe was set up). Re-checks each
  affected track against its file, fills in blanks automatically, and shows a
  review sheet for any tag that genuinely disagrees with the file — including
  albums where every track's number collided (all "11", for example).
- **Artwork search shows how many images each release actually has.** Every
  result in the album-art search now carries an "N IMAGES" badge from the
  Cover Art Archive, loaded in the background as you scroll, so you can tell
  which edition is worth opening before you click into it.
- **An empty case stands in for missing artwork**, instead of an abstract
  generated poster — a CD jewel case for CD/digital albums, a bare vinyl
  inner sleeve (with ring wear) for vinyl.

### Changed
- The DISC tab (and mini player) now always shows the disc that's actually
  loaded and playing, like a hardware deck's tray — it no longer follows
  whatever album you're browsing.
- Reduced background CPU/IPC usage: the system Now Playing display is only
  updated on a seek or state change instead of five times a second, and the
  12-band EQ is skipped entirely while every band is flat.

### Fixed
- Alt cover art no longer gets picked as an album's main cover art.
- Cover art now loads reliably in the mini player.

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
