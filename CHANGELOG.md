# Changelog

All notable changes to CrateDigger are documented here. Versions follow
[semantic versioning](https://semver.org); the number in parentheses is the
build, which is monotonic across every release.

## 1.2.32 (53) — 2026-08-05

### Fixed
- **Cover art sent to a device is actually resized now.** A device profile that
  asks for smaller covers (the Rockbox iPod preset caps them at 600 px) was
  being ignored for any artwork tagged at a print DPI — a 1200 px cover marked
  300 DPI measured as 288 pt, looked "small enough" to the resize check, and got
  embedded at full size. Those covers are now capped by real pixel dimensions,
  so transfers carry art at the size the device asked for instead of the
  original, and the size shown in the inspector matches the file.

## 1.2.31 (52) — 2026-08-05

Finishing the CD path: ripped albums arrive with their cover, and the CD screen
tells you what's in the drive.

### Added
- **Ripped albums come with their cover.** Once a disc is identified,
  CrateDigger fetches that release's artwork and embeds it as it rips — no
  separate trip through artwork search afterwards.
- **Adjust the cut on a scanned disc.** A CD laid on a scanner is never quite
  centred or straight, so its label sat crooked and off-centre on the spinning
  disc. The DISC tab has an ADJUST CUT mode: the disc holds still, you drag it
  into place, and sliders handle rotation and zoom. Your scan is never altered —
  the framing is remembered alongside the album and can be redone or reset at
  any time.
- **The CD screen shows the disc in the drive.** Previously it only appeared
  while a rip was running, so an inserted disc showed nothing. It now names the
  identified release with its year, track count and total running time — the
  check you want before pressing RIP — and says plainly when a disc isn't in the
  database.

### Fixed
- **Deleting artwork updates the Artwork Viewer.** An image removed in the
  inspector stayed on screen in an already-open viewer.
- **The CD screen tells the truth while ripping.** It reported the output format
  as FLAC whatever you had chosen, a rip speed that was never measured, and a
  fixed library path instead of your actual destination. All three are real now,
  alongside a measured elapsed time.
- **Rips follow your conversion options.** The artwork handling on the OPTIONS
  tab never reached a rip, and every rip was forced to stereo — a mono or
  quadraphonic disc now rips as it was pressed.

## 1.2.2 (50) — 2026-08-05

Fixes for ripping, found by actually ripping a CD.

### Fixed
- **Converted and ripped files keep their tags.** A ripped CD came out with only
  its album artist — the title, artist, album, year and genre were all lost.
  CrateDigger had been relying on those being copied across from the original
  file, which works when the original has tags, but an audio CD's tracks have
  none at all. They are now written directly. Any field you have left blank
  still inherits whatever the original file had.
- **Rip progress moves while it's ripping.** The display sat at zero for the
  whole rip and jumped straight to finished. It now counts up track by track and
  names the one being written.

### Changed
- **Add artwork a folder at a time.** The artwork panel's ADD button now takes
  several images at once, or a whole folder of scans, instead of one file per
  trip through the file picker. Each image is filed by its name — `back.jpg`
  becomes the back, `booklet_03.tif` a booklet page, `cd1.png` the disc — so a
  scanned sleeve arrives already sorted rather than piling into Cover. A single
  unlabelled image still becomes the cover, as before.

## 1.2.1 (49) — 2026-08-05

CDs now identify themselves before you rip them, plus repairs to the tool
windows introduced in 1.2.0.

### Added
- **Audio CDs identify themselves.** Insert a disc and CrateDigger works out
  what it is — artist, album, year and every track title — *before* you rip a
  single second. It reads the disc's table of contents, which is unique enough
  to name the exact pressing, so it works even on discs that arrive with no
  information at all (the usual case: macOS shows them as "1 Audio Track",
  "2 Audio Track"…). Where one disc belongs to several releases — an album on
  its own and the same disc inside a box set — CrateDigger asks which you meant
  rather than guessing, since it changes the album name. A disc nobody has
  catalogued yet offers a link to add it.
- **Rips are filed like everything else.** A rip now follows your folder pattern
  and naming settings, with the real track titles. Previously every ripped track
  was called "Track 1", "Track 2"… inside a folder named "Audio CD", tagged with
  the artist "Audio CD", regardless of your settings.

### Fixed
- **The tool windows work properly again.** Edit Tags opened almost too small to
  read; Library Cleanup opened taller than the screen with its buttons off the
  bottom; and Cancel and Close did nothing in any of them. All four now open at
  a sensible size, stay within the screen, have proper minimum and maximum
  sizes, and close when you tell them to.
- **The header's VIEW / THEME / EQ buttons line up.** They had drifted to three
  different widths — EQ's row of indicator lights was pushing its button wider
  than the others. All three are now the same size, with their indicators
  aligned.
- **APPLY ALL is more careful.** When fixing tags across several albums at once,
  only confident matches are applied without you seeing them. Anything looser
  stays in the queue for you to review rather than being written to your files
  unseen.

### Changed
- Edit Tags, Fix Tags, Match Tags and Library Cleanup share one visual style
  now, instead of three slightly different ones.

## 1.2.0 (47) — 2026-08-05

Queue control, a sleep timer, and tool windows you can actually move.

### Added
- **Play Next and Play Last.** Right-click any artist, album or track — or use
  ⌘⌃N / ⌘⌃L — to queue it behind whatever is playing, without interrupting it.
  A new QUEUE tab in the inspector lists what's coming up, and lets you reorder
  it, drop individual tracks, or clear the lot.
- **Sleep timer.** Playback ▸ Sleep Timer: 15, 30, 45, 60 or 90 minutes, or
  "After This Track" / "After This Album / Playlist" to stop on a musical
  boundary instead of mid-song. Timed modes show a countdown.
- **A conversion queue you can see.** The Patch Bay now has QUEUE, SETTINGS and
  OPTIONS tabs. QUEUE lists exactly which tracks a conversion will process and
  the filename each one will be written as, with live progress while it runs.
- **Real album-art options for conversion.** OPTIONS lets you keep the original
  art, re-embed a compatible copy, or strip it — and cap its size independently.
  Previously the choice was inferred, so "keep the art but make it smaller" and
  "remove the art" were both impossible to ask for.
- **A queue view for disconnected devices.** Browsing a device that isn't
  plugged in now shows what's waiting for it: how many tracks, how large the
  transfer will be, how much is staged on this Mac, and whether any queued track
  has lost its source file. Sync or clear the queue from the same strip.
- **Radio: a Fix button that knows what broke.** When a stream fails,
  CrateDigger now explains why and offers the repair that fits — updating yt-dlp
  when YouTube has changed under it, waiting out a rate limit, or picking a
  different station when the video is simply private or gone. The raw log is one
  click away.
- **Suggested stations.** Radio now ships a browsable list of long-running
  stations you can add in a single tap, instead of starting from an empty URL
  field.
- **More album art found automatically.** Artwork search now also consults
  Deezer when the iTunes Store has nothing, which fills in a lot of small-label,
  non-US and electronic releases.

### Changed
- **Edit Tags, Fix Tags, Library Cleanup and Search Album Artwork are now
  windows, not sheets.** They can be moved, resized, and left open beside the
  browser, and each remembers where you put it.
- The Patch Bay's "collapse the browser for a roomier panel" prompt is gone.
  Collapsing panes still works from the chassis controls.

### Fixed
- **Tracks with no duration now show one.** Some files — commonly variable
  bitrate MP3s, and certain FLAC and AIFF encoders — reported no length, leaving
  a dash where the time should be. CrateDigger now falls back to a second source
  for the duration. Existing libraries pick this up on the next dig or Refresh
  Tags.
- **A failed radio stream no longer stays "on air".** After a stream failed to
  start, the display kept showing ON AIR and the station name even once you'd
  moved on and played something from your library.
- **Keyboard navigation is visible again.** Moving between browser columns with
  the arrow keys now lights the column you're steering, and dims the selection
  in the columns you aren't.

## 1.1.2 (46) — 2026-08-05

A stability and performance release. The headline fix is a crash that could
take the app down while saving tags.

### Fixed
- **Crash while saving tags.** Certain tag values — most often ones picked up
  from an online release match, or read from an ID3 tag that uses a separator
  byte inside a field — could abort CrateDigger outright the moment it wrote
  them to a file. Those values are now cleaned up before they reach ffmpeg, and
  no tag can take the app down this way again. Converting files was open to the
  same crash and is fixed too.
- **Repeat All now wraps on the transport buttons.** Pressing Next on the last
  track of a queue stopped playback instead of looping back to the first;
  Previous on the first track restarted it instead of jumping to the last.
  Letting a track play out always wrapped correctly — now the buttons agree.
- **A broken file no longer starts playback on its own.** If CrateDigger hit a
  file it couldn't read while you had a queue loaded but paused, it skipped
  past it *and* started playing. It now skips quietly and stays paused.
- **Volume survives a DSD handoff.** Changing the volume while a DSD track
  played bit-perfect didn't reach the regular playback engine, so falling back
  to PCM could jump to an old level.
- **Trashed files stay out of your library.** Scanning an external drive walked
  into its hidden Trash folder and imported audio you'd already deleted.
- **Device sync no longer loses tracks queued mid-sync.** Staging tracks for a
  device while a sync was already running could silently drop them from the
  queue. Syncing also no longer reports "not enough space" for a queue whose
  files are mostly on the device already.

### Changed
- **Faster tag matching.** Applying an online match to an album now writes the
  whole album in one pass instead of once per file, with progress on the OLED.
  A new APPLY ALL button accepts the current album and every remaining one in
  the queue in a single go.
- **Lighter mini player.** The mini player redrew its entire panel — artwork,
  display, transport and all — several times a second just to advance the time
  counter. Only the clock readout and progress bar refresh now.
- **Quieter launch with saved radio stations.** CrateDigger fetched artwork and
  titles for every station at once on startup, which could spike the CPU. They
  now load one at a time, and a station that stops responding gives up after 30
  seconds instead of hanging around for the session.
- **Faster device syncs.** Long transfers spent an increasing amount of time
  rewriting their own queue file between tracks.

## 1.1.1 (45) — 2026-07-23

### Added
- **DSD playback.** `.dsf` and `.dff` files now scan into the library like any
  other format, labeled by their real rate (DSD64 / DSD128 / DSD256). Pressing
  play decodes them on the fly with the bundled ffmpeg — your originals are
  never touched — so VU meters, the EQ, seeking, and scrobbling all keep
  working. The OLED shows "DECODING DSD…" while a track spins up.
- **SACD ISO import.** File ▸ Import SACD ISO… rips a SACD image straight into
  per-track, fully tagged DSF files, filed as `Artist/[Year] - Album` and landed
  in the Prep Crate — like ripping a CD. Requires the open-source `sacd_extract`
  tool (CrateDigger can't bundle it for licensing reasons); the app shows the
  one-time build recipe if it's missing.
- **DSD Output menu (experimental).** Playback ▸ DSD Output adds a bit-perfect
  DoP mode for DSD-capable DACs. It ships opt-in and defaults to the reliable
  PCM decode path while the native mode is still being verified on hardware.

### Fixed
- **Adding an album to a crate twice could duplicate its files.** Re-committing
  tracks that were already imported silently created " (1)" copies on disk.
  The importer now recognizes byte-identical files and reuses the existing
  copy, and committing tracks out of the Prep Crate removes them from staging
  so an accidental second commit can't happen.
- **Duplicated tracks showed as blank gaps in the browser.** Crates damaged by
  the double-import bug rendered ghost rows (a 24-track album showing 12 titles
  and empty space); the library now repairs those entries on load so every
  track is visible again.
- **Cleanup missed exact-duplicate files.** Duplicate detection skipped tracks
  whose duration was unknown; byte-identical copies are now caught by exact
  file-size match, so the " (1)" duplicates surface in Library Maintenance and
  can be cleared (crate references repoint to the kept copy automatically).
- **DSD files showed a codec name instead of their rate.** Real-world DSFs
  probe with a bytes-per-second sample rate; they now label correctly as
  DSD64/128/256 instead of "DSD_LSBF_PLANAR".

---

## 1.1.0 (44) — 2026-07-22

### Fixed
- **Scanning could hang the whole app.** Reading tags runs ffprobe, which blocks
  its thread; the scanner ran one per CPU core directly on Swift's concurrency
  pool, so a large dig (or several folders at once) could park every pool thread
  and freeze the UI until the scan finished. Probes now run on their own queue —
  a 644-file scan that took >14 min to unstick now finishes in ~2 s.
- **Big libraries used far more memory than they needed.** Every track kept its
  own copy of its album cover, because reading cached artwork back out of the
  in-memory store silently duplicated the image each time. Covers are now shared
  across the tracks that use them (~5× less artwork memory on a real library),
  which also removes a crash on very large multi-folder imports.

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
