# Changelog

All notable changes to CrateDigger are documented here. Versions follow
[semantic versioning](https://semver.org); the number in parentheses is the
build, which is monotonic across every release.

## 1.1.0 (43) — 2026-07-22

Silent refresh of the 1.1.0 DMG (same release, updated build):

- Staging tracks for an offline device now says which conversion got baked
  ("12 tracks ready to sync · M4A 192 kbps"); the per-device settings live in
  Preferences ▸ Devices.
- New right-click action on queued tracks: **Re-stage with Current Settings**
  — staged conversions are frozen at stage time, so this re-bakes them after
  you change the device's format. Copy-mode queues (nothing staged) say so
  and don't offer it.

## 1.1.0 (42) — 2026-07-22

### Added
- **Theming ("skins").** The Carbon look is now a themeable skin system, the
  way a Winamp `.wsz` reskins Winamp: drop a `.cdtheme` folder into
  `~/Library/Application Support/CrateDigger/Themes/` and cycle it from the
  THEME key — no rebuild, no restart. Themes override colors, shadows,
  fonts, geometry, and (new since the beta) the OLED glass itself —
  foreground phosphor, ON AIR lamp, and scanline strength via the new
  `effects` block. Ships with three bundled themes: **Carbon, Linen, and
  Llama '97**. Full guide: `docs/THEMING.md`.
- **Library cleanup, reworked.** Duplicate detection now runs off-main with
  strict/broad modes, duration guards, a reviewable checkbox UI, per-group
  ignore (persisted), and crate repointing when duplicates are trashed.
- **FIX TAGS goes online.** One press matches releases online and offers the
  fields to fix — now with a per-album queue (position readout, SKIP, end
  summary) and batch disc numbers.
- **Pre-transfer device sync.** Saved devices stay in Sources while offline;
  stage tracks to a sync queue (PENDING badges) and SYNC pushes everything
  when the device reconnects, with a live DEV readout on the OLED.
- **Check YouTube Streaming** (Playback ▸ Stream Engine): one click verifies
  the yt-dlp radio pipeline end-to-end and offers the matching repair —
  install via Homebrew, or the right update command — then re-checks itself.
- **Artwork, top to bottom:** Search & Add Album Covers for a whole gallery
  selection; the full physical-package taxonomy (Matrix / Runout, Sticker,
  Sleeve, Spine, Obi, Poster, Wrapped Cover) with Cover Art Archive scans
  arriving pre-classified; a role-ordered ART grid with remove; Split Folder
  for albums mixing two codecs; and a thumbnail-only disk cache that stops
  hoarding full-size copies of every cover.
- **Activity lamp** in the titlebar's top-right corner — the traffic lights'
  opposite number — glowing while the library works.
- Gallery arrow-key navigation, ⌘A select-all, visible multi-selection;
  Go to Current Song (⌘L); collapsible Sources sections; Move Index Files
  alongside the renamed, explained Folders preferences; the Major Mono
  display face returns to the OLED's big names.

### Changed
- The play dome is honest hardware now: one printed ⏯ glyph that never
  changes — dark with a pitch-black print when paused, theme-lit when
  playing. The display toggle is a thin strip of light in the screen's own
  color; THEME acknowledges each press with a dash LED; EQ gained a CUSTOM
  lamp; ON AIR breathes while streaming and flashes while connecting.
- Album-artwork search is looser: edition decorations ("(Deluxe Edition)",
  "[2017 Remaster]") are stripped on retry and MusicBrainz walks a
  strict-to-loose query ladder, so tagged titles find their release.
- The VU/RTA OLED screen is retired (it earned neither its slot nor its CPU);
  an audio-reactive visualizer is planned in its place.

### Fixed
- Disc numbers survive committing out of the Prep Crate, and track/disc
  numbers are written even when totals are missing — multi-disc albums no
  longer collapse into one "DISC 1".
- Imported albums classify their artwork automatically and promote the real
  cover — no more random booklet page as the album's face until you sorted
  the ART grid by hand.
- Album versions: ghost empty rows, garbage edition labels, and same-tagged
  pressings merging across folders are all fixed; the Group sheet shows
  per-version stats and a reveal-in-Finder button.
- Artwork stale disk cache, silent save failures, and unstable cover picks;
  grouped now-playing tracks reveal their browsable album.

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
