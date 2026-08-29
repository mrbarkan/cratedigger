# Changelog

All notable changes to CrateDigger are documented here. Versions follow
[semantic versioning](https://semver.org); the number in parentheses is the
build, which is monotonic across every release.

## 2.0.0 (75) — 2026-08-29 — BETA 3

Everything in the 2.0 line so far, newest work first. Unfinished by
definition: this is where 2.0 is built, and it is offered to nobody who has
not asked for it.

Beta 3 is about artwork and the panels you work in. Artwork you find is now
staged and only written when you say so, the ART tab finally shows the picture
that lives inside your audio files, and the conversion panel lost its costume.

Beta 2 was mostly foundations: CrateDigger keeping a record of what you listen
to, and the browser's selection and sorting moving into the tested core of the
app.

### Added

- **Artwork waits for you now.** Anything you import from the search window, or
  pick off your own disk, is held aside instead of landing in your album folder.
  You look at it, set roles, drop what you do not want, and press SAVE. Removing
  a file you already had is a mark rather than a deletion, so it is reversible
  right up until the moment you save. Leaving the ART tab with work pending
  keeps the work and tells you it is waiting.
- **See the artwork inside your files.** The ART tab shows the picture embedded
  in the audio itself, with its pixel size, alongside the images in the folder.
  It can be removed: saving rewrites the tracks to drop the picture, and it says
  how many files that is before you agree to it. The audio is copied rather than
  re encoded, so nothing is lost but the picture.
- **Your scans and the internet in one window.** FIND ART replaces the two keys
  that used to do half the job each. Images you choose from disk land in the same
  grid as the online results, with their role read from the filename, and go
  through the same review and the same import.
- **Import AutoEQ.** Paste or drop a parametric EQ config from squig.link,
  AutoEQ, oratory1990, Wavelet or Poweramp, and CrateDigger fits it onto the
  twelve faders. It draws both curves, the one the file asks for and the one
  twelve bands can actually produce, so you can see how close the fit is before
  you take it. Save it straight into one of your own slots.
- **Three EQ slots of your own.** Store a curve, name it, load it back. Right
  click a slot to save the current curve into it, rename it, or clear it.
- **Choose which EQs the header key cycles.** Every preset in the equalizer now
  carries a lamp. Lit ones are what the EQ key steps through, so a rotation of
  three presets is three presses instead of seven.
- **Find every album with poor artwork.** Library Cleanup has an Artwork tab
  that sweeps your whole library for albums with no cover or a cover too small
  to look at, lists them worst first, and fetches better ones in one run. It
  never replaces a cover with a smaller one.
- **A field you pick in the inspector.** The row under the cover shows Genre by
  default. Click it to show Bitrate, Sample, Added or Plays instead, and it
  remembers.
- **CrateDigger remembers what you play.** Play counts, skips, when you last
  heard something, when it was added, and a one to five star rating on every
  track. Rate from the inspector or with Command-Option-0 through
  Command-Option-5. None of it is visible in the browser yet; it is the
  foundation the smart crates and the listening stats are built on.
- **Deep Scan: fix tags by listening to the record.** Fix Tags searches with the
  tags a file already has, which is no help at all on a rip with no tags or with
  somebody else's. Deep Scan fingerprints the audio instead, asks AcoustID what
  it is, and offers the answer through the same review sheet, with the tracks
  paired to the record by recording rather than guessed into order. It never
  runs on its own: press DEEP SCAN in the match window when the proposed record
  looks wrong, or take the offer in the alert when nothing matched by name.
- **Receive beta updates.** Settings, Advanced. Off unless you turn it on, and
  turning it on is the only way a stable install is ever offered one of these
  builds. It selects a separate feed rather than tagging the stable one, so
  leaving it alone means a mistake in a beta cannot reach you. Turn it off to
  go back to finished releases.

### Changed

- **A much bigger cover.** The inspector's cover now takes whatever height the
  text below it leaves, and follows the window as you resize it. The tabs and
  the library tools moved out onto the chassis around the panel, the rows that
  repeated what the display above already said are gone, and a long album title
  sits on one line until you click it.
- **The Patch Bay is now Conversion.** A patch bay is where you plug cables
  between things; this picks a format and a folder layout, so it says so. Its
  keys lost their glow and their rows of lamps for a readout with a hairline
  scale, the folder modes read MIRROR, FLAT, TAGS and CUSTOM instead of one word
  that meant nothing, and the pattern editor only appears when you are using it.
  The destination is a single line you click.
- **Artwork search shows where each image came from.** Cover Art Archive,
  Discogs and your own disk each get a badge and a filter, every image shows its
  true pixel size, and releases can be ordered by the cover they actually carry.
  Discogs scans announce themselves while they load rather than appearing
  unannounced, and can be switched off entirely. The release you imported from
  is remembered, so reopening the search lands on it.
- **Notices are centered on the display.** Messages like "MATCHING TAGS" used to
  sit hard against the annunciators on the left and shove the transport strip
  sideways every time one appeared. They now sit in the middle of the glass and
  no longer move anything else.

### Fixed

- **A thumbnail is no longer blown up to fill the screen.** Opening artwork used
  the small picture inside your files even when the folder held real scans. It
  uses those now, and falls back to the embedded one only when there is nothing
  else, at its own size rather than stretched.
- **The equalizer reads 0 at the centre.** A fader sitting at zero used to show
  +0, or sometimes -0.

### Notes for testers

Betas can lose data. Point CrateDigger at a copy of your library, not the only
copy, and keep a stable install to fall back to. 2.0's plan is at
cratedigger.mrbarkan.com/roadmap.html.

## 1.5.10 (72) — 2026-08-28

Discogs, where the scans of the physical object live. Back sleeves, inners,
labels and obi strips, for the shelf of vinyl and cassettes that the front
cover alone never described.

### Added

- **Physical-release scans from Discogs.** The artwork sheet offered iTunes and
  Deezer fronts plus whatever the Cover Art Archive held, which for most
  releases is a front and little else. Discogs carries the deep scans: back
  sleeves, spines, labels, inners, inserts, obi strips. They arrive with a
  DISCOGS badge so it is clear what came from where, and a Discogs failure is
  never raised as an error, since the archive's images still stand on their
  own.
- **Three ways to find the release, cheapest first.** The `discogs` link
  MusicBrainz already carries, else the barcode, which is the same number
  printed on the same physical object, else artist and title with the album
  checked against the result before anyone's folder gets someone else's scans.
  Each rung costs a request only when the rung above it missed. Measured on
  releases that previously had one image each: Paracosm went to 3, 22, A
  Million to 10, Teen Dream to 21.
- **An optional Discogs token.** Settings, Integrations. Blank stays fully
  working; a token raises the rate limit from 25 requests a minute to 60.
- **Release notes worth reading.** What's New had not been rewritten since
  1.5.0, so nine releases of upgraders saw the same five theme editor notes. It
  now covers what actually shipped, and folds theming into one standing summary
  instead of five entries.

### Changed

- **The artwork sheet loads in two stages.** Walking the Discogs ladder takes
  several seconds. The archive's images now go on screen at about 1.5 seconds
  and the Discogs scans append behind them, rather than everything waiting on
  the slower source.
- **The website says what the app does.** It offered no way to download
  CrateDigger, and described crates as `.cdlib` files two storage formats ago.
  There is now a download route, accurate crate and artwork copy, and a public
  roadmap for 2.0 at cratedigger.mrbarkan.com/roadmap.html.

### Fixed

- **A slow MusicBrainz no longer reads as a failed search.** Artwork search
  reported "Network error: The request timed out" on queries that were merely
  still running. MusicBrainz search is far slower than anything else here, the
  same query answering in 0.8s and 5.2s within one session, so it gets 25
  seconds of its own instead of the 12 that suit iTunes and Deezer.
- **One slow rung no longer discards the whole search.** The search walks
  progressively looser queries, and any rung throwing threw all of them away.
  The strict quoted rung fails most often, which is exactly the case an oddly
  tagged album depends on falling through. Only a search where every rung
  failed is a failed search now.
- **The artist and album fields line up.** They were sized independently from
  their own contents, which could render the artist column shorter and lower
  than the album column.

## 1.5.9 (71) — 2026-08-27

Go to Current Song takes you back to the record you're hearing — from any crate.
The theme editor gained a pin and its own colour for every lamp on the display.

### Added

- **A pin on the theme editor.** The editor's whole point is watching the app
  restyle behind it, which stopped working the moment you clicked the browser
  and the panel dropped behind the window. It now floats above the app by
  default; the pin in its top-right corner drops it back into the pile.
- **Every display lamp has its own colour.** NOW, CNVRT, SCAN, SYNC, CD and DEV
  — the annunciators on the glass and the strip in the DISPLAY button — are now
  six separate tokens in the theme editor instead of borrowed accents, so you
  can tell the screens apart without retinting half the interface. Leave one
  unset and it follows the accent it always did: nothing you've themed changes.
- **Alternate row striping in the browser.** A new Alternate Rows token stripes
  the Artist, Album and Track columns. It ships transparent, so the lists look
  exactly as they did until you give it a colour.
- **A yt-dlp path in Settings.** Advanced now has a yt-dlp row alongside ffmpeg
  and ffprobe, so a custom install can be pointed at without the environment
  variable. Radio is the only thing that uses it.
- **Collapsing Local Library keeps the crate you're playing.** The chevron folds
  the rest away and leaves the one you're listening to on screen.

### Changed

- **Clearer names in the theme editor.** The token labelled "Alternate Rows"
  never painted alternate rows — it shades the bottom of a panel, and is now
  called Panel Shade. The accent tokens say outright which of them light the VU
  meters, the EQ panel, the POSITION bar and the VOLUME fader.
- **The Devices settings pane is laid out properly.** The divider runs the full
  height, add and remove sit in a bar under the list where macOS puts them, and
  Save and Remove are pinned below the form instead of scrolling off the bottom
  of the window with the last section.

### Fixed

- **Go to Current Song works.** The button asked the browser to scroll to the
  playing album and then immediately scrolled it back to where you were, so
  nothing moved. Pressing it now centres the record you're hearing, whether or
  not it was already selected, and expands the browser if the conversion cockpit
  had collapsed it.
- **Go to Current Song crosses crates.** Playing out of one crate and browsing
  another, the button did nothing at all: it only ever looked in the crate on
  screen. It now switches back to the crate the queue came from and reveals the
  track there.

## 1.5.8 (70) — 2026-08-27

The VU meters really do move on radio this time — including live streams, which
1.5.7 said were impossible.

### Fixed

- **The VU meters work on every stream, live ones included.** 1.5.7 pointed the
  meters at the radio player, but they still sat flat: every YouTube stream —
  not just live ones — arrives as HLS, and macOS won't hand out the audio from
  an HLS player. CrateDigger now measures its own output at the audio-hardware
  level instead, so the needles follow whatever you're listening to. Requires
  macOS 14.4 or later; on older systems the meters rest at zero as before.

## 1.5.7 (69) — 2026-08-26

CrateDigger installs its own updates now. The theme editor gained an undo, and
the VU meters finally move when you're listening to radio.

### Added

- **Updates install themselves.** "Check for Updates…" downloads the new
  version, verifies it was signed by us, installs it and relaunches — no more
  fetching a DMG and dragging the app across by hand. It also checks quietly
  once a day, and prereleases stay on their own channel, so a stable install is
  never offered a release candidate.
- **Undo in the theme editor.** UNDO steps back through your last ten changes —
  any change, including the screen presets and the COPY TO LIGHT/DARK that
  previously had no way back. A slider drag or a typed name counts as one step,
  not fifty.

### Changed

- **Texture grain stays on the console.** Grain used to fall across the display
  too, which made the screen look like a sticker printed on the front panel. It
  now stops at the bezel, leaving the glass to its own scan lines, halftone and
  glare. The dial is called Texture Grain.

### Fixed

- **The VU meters work on radio.** They were reading levels from the library
  player, which radio pauses when a stream starts, so they sat flat through
  every broadcast. They now follow whatever is actually making sound. Live
  streams are the exception and rest at zero: their audio arrives in a form
  macOS won't let the app measure.
- **Closing the theme editor closes the color picker.** The system picker used
  to stay floating over the app with nothing left to write to.

## 1.5.6 (68) — 2026-08-26

Emergency fix: 1.5.5 wouldn't open. Nothing else changed.

### Fixed

- **1.5.5 quit the moment you opened it.** The packaged app went looking for
  its bundled fonts and themes in a folder that only exists on the machine that
  built it, and killed itself when they weren't there — every Mac, every
  launch. It now finds them where they actually ship, and falls back to the
  system fonts and no built-in themes rather than quitting if they ever go
  missing.

## 1.5.5 (67) — 2026-08-24

Halftone actually prints now, selection stops following the accent, and the
floating artwork panel sits on glass instead of behind a neon outline.

### Fixed

- **HALFTONE did nothing on the display.** Two faults, both measured: the dot
  screen's blend wasn't grouped with what it blended against, so on the OLED it
  resolved to no change at all, and the dots were coarser than the type they
  print — an 8pt cell against 7.5–13pt readouts left nearly every stroke in a
  gap. The screen is finer now and bites: lit type drops 12% at 0.3 where it
  moved 3% before. GLARE had the same grouping fault and is fixed with it.
- **Halftone on a pale screen.** The dots were always dark ink, which only
  works on a lit panel: on an iPod- or calculator-style glass with dark type it
  dimmed the background and left the type alone. The ink is now chosen from the
  glass — dark dots on a lit screen, light dots on a pale one.

### Changed

- **Selected rows have their own colours.** The browser and sidebar selection
  read the accent tokens directly, so retinting a theme's accent moved every
  selected row with it. Selection now has `selectionGlow` and `selectionWash`
  of its own, next to the existing lamp and text tokens, defaulting to exactly
  what each built-in used before.
- **The floating artwork panel sits on glass.** A frosted plate lit by the
  record — the cover blown up and blurred behind a scrim — instead of a
  transparent surround ringed by a cyan outline that lit on hover. The rim just
  firms up under the pointer now.
- **VIGNETTE is gone.** It was a corner-darkening dial that earned nothing the
  theme's own colours couldn't do. One less thing in the INTERFACE section.

## 1.5.5 (66) — 2026-08-24

Effects. The console and the display can now be textured — film grain and a
lens vignette on the hardware, a reflection and a print dot-screen on the
glass — each with a switch and a dial in the theme editor, and each shipping
off. The theme editor's effects are split the way they're felt: what happens
to the interface, and what happens to the screen in it.

### Added

- **Interface effects: GRAIN and VIGNETTE.** Grain lays film noise over the
  whole console; vignette darkens the corners the way a lens does. Both sit in
  a new INTERFACE section of the theme editor alongside FLAT, and both are
  themeable directly as `effects.grain` and `effects.vignette`.
- **Display effects: GLARE and HALFTONE.** Glare sweeps a reflection across the
  display glass; halftone lays a print dot-screen over it, breaking the lit
  type into dots like a scanned photo of a screen. `effects.oledGlare` and
  `effects.oledHalftone`, next to SCAN LINES and MONOCHROME.
- **Every effect has a switch and a slider.** Each one ships off, so the switch
  lights it to a strength you can actually see and the slider takes it from
  there. The value shown is read back from the renderer, not a copy of it.

### Changed

- **OLED BLUE matches the hardware it's named after.** Its phosphor was a pale
  sky blue; sampled off a photo of the real panel it's a far more saturated
  aqua (`#81F0FC`), and its type is a proportional screen sans rather than a
  monospace. The real panel's yellow-green status strip is a second emitter and
  isn't modelled — the preset stays one phosphor.
- **The theme editor's DEPTH section is now INTERFACE.** It holds the console's
  effects, shadows included; the display's own effects stay under DISPLAY
  SCREEN with the screen presets.

### Fixed

- **Scan lines fall across the type, not behind it.** The rake was applied to
  the glass *under* the panes, where it could only ever texture the background
  between the letters. All three display effects now composite over the
  finished screen, which is where a rake, a reflection and a dot screen
  actually sit.

## 1.5.4 (65) — 2026-08-24

Housekeeping for the display. The glass ships clean now — no scan lines unless
you ask for them — and the rake got a switch and a dial of its own. The data
rail along the bottom is fixed hardware: five columns at one height, in the
same place on every screen. Two new screen presets, one of which is the way
back to stock.

### Added

- **CARBON screen preset.** The first button in the Display Screen row, and the
  reset: one click puts the glass back exactly as CrateDigger ships it — the
  near-black panel, warm-white type, full accent colours and the shipped
  display face. It reads its colours off the built-in theme, so it can't drift
  from what the app actually paints.
- **OLED BLUE screen preset.** The classic music-player OLED: pale blue pixels
  on true black, no rake. Where nothing is drawn, the glass is genuinely off.
- **SCAN LINES switch.** The CRT rake over the display now has its own switch
  and an intensity slider in the theme editor, next to MONOCHROME, writing
  `effects.oledScanlineOpacity` — so it's dialable by hand instead of arriving
  only as part of a preset.

### Changed

- **The shipped glass no longer rakes.** Both built-in themes now default to no
  scan lines; the CRT-flavoured presets (LCD GREEN, AMBER, RED LED) still bring
  their own. Type 0.018 into the slider for the old faint rake.
- **The SORT readout is off the display.** The browser's sort state was printed
  in the corner of the NOW screen, where it duplicated the column headers you
  were already looking at.

### Fixed

- **The bottom data rail stops resizing between screens.** Its hairlines used
  to move with the number of facts a screen had — three on SYNC, four mid-sync,
  five elsewhere — and a long value could shrink the row under them. It is now
  five fixed columns at a fixed height everywhere, so nothing shifts as the
  glass switches views.

## 1.5.3 (64) — 2026-08-21

The theme editor learned what a screen is. Seven one-click looks for the
display — green LCD, amber, VFD, LED, backlit, iPod, e-paper — plus two
switches that describe the hardware rather than the paint: a true single-colour
panel, and a console with no cast shadows. Carbon and Linen are one theme now,
and the header rail carries what's playing instead of readouts you could
already see.

### Added

- **Screen presets in the theme editor.** LCD GREEN, AMBER, VFD CYAN, RED LED,
  BACKLIT, IPOD and PAPER each set the display's six colours, its scanline
  strength and the face its titles are set in, in one click. IPOD is two
  panels: reflective grey-green in Light, blue-white backlit in Dark. A preset
  paints both versions of a light/dark theme — the glass is hardware, and
  hardware doesn't change when the room lights do.
- **MONOCHROME switch.** Real LCD, VFD and LED panels emit one colour. With
  this on, everything drawn on the glass — lit annunciators, meters, warnings,
  the ON AIR lamp — is the screen's own phosphor at whatever brightness it had,
  and the theme's accents stay on the chassis. Themeable directly as
  `effects.oledMonochrome`.
- **FLAT switch.** Drops every cast shadow in the interface — panels, keys, the
  display glass, album covers — while the bevels, gradients and glows stay. The
  same console, printed rather than moulded. Themeable as `effects.flat`.

### Changed

- **Carbon and Linen are one theme.** Carbon now carries both a light and a
  dark layer and follows your Light/Dark/System setting, instead of shipping as
  two themes you had to switch between. A preference still pointing at Linen
  moves to Carbon on launch; picking "light" is now the app's appearance
  setting.
- **Llama '97 redrawn.** Dark is the player everyone remembers — black
  playlist, phosphor-green track text, grey-blue bevelled chrome, blue
  selection, square corners — and it now ships with the monochrome panel on.
  Light is the same console in muted purple with white type on black glass.
- **The header rail carries playback, not settings.** The dB readout and the
  LIST / LIGHT / FLAT readouts are gone — they repeated three buttons sitting a
  few inches to their right. The volume meter is pinned to the right edge, and
  the track title and position bar stretch into the space that frees up. On the
  now-playing screen, where the title and clocks are already set in 44pt above,
  the rail keeps just the bare position bar.

## 1.5.2 (63) — 2026-08-19

Radio repairs. YouTube changed something, an out-of-date yt-dlp couldn't keep
up, and the three things that should have told you so were all broken: the
error said nothing useful, the update button reported success without updating,
and the failure notice pushed the transport controls off the bottom of the
screen.

### Fixed

- **The window no longer resizes itself to fit its contents.** Anything tall in
  the browser — the radio FIX panel was the one you'd hit — grew the window past
  the bottom of the display and took the transport footer with it. Measured at
  892pt before the panel and 1249pt after; the window now keeps the size you
  gave it.
- **Stream errors name the actual problem.** A failing chunk reported "there was
  a bad response from the server" no matter what happened, because the HTTP
  status was attached to an error type that discards it. A 403 now says it's a
  403 and that yt-dlp is the likely cause, and the FIX panel offers the remedy
  that matches instead of a generic list.
- **The UPDATE YT-DLP button tells the truth.** `brew upgrade yt-dlp` exits
  successfully whether or not it upgraded anything, so when Homebrew's formula
  was weeks behind — which is routine — the app congratulated you and nothing
  changed. It now checks the version actually moved, and when it hasn't, offers
  to download yt-dlp's own latest release and use that copy instead. Your
  package-managed install is left alone, and Playback ▸ Stream Engine ▸ Set
  yt-dlp Path… switches back.

## 1.5.1 (62) — 2026-08-18

Sending music to a device used to happen in three places at once, and the CNVRT
queue filled itself with tracks nobody chose. Both are now one thing you can
point at: a queue you fill deliberately, shown where you are looking.

### Added

- **Device strip.** Browsing a device now opens with a line across the top of the
  browser saying what is waiting for it, how big it is, and whether the device is
  plugged in — with SETTINGS, SYNC NOW and CLEAR right there.
- **Queued tracks are marked in the browser.** Artists and albums holding
  something bound for a device carry an orange dot in place of their bullet, so
  you can see what is spoken for while you dig.
- **Convert Queue.** Right-click anything and choose *Add to Convert Queue* to
  line it up. The Patch Bay's QUEUE tab lists it under CRATE QUEUE, with its own
  CLEAR.
- **Device queues in the Patch Bay.** The QUEUE tab shows every device queue
  above the crate queue, each with a PRE-CONVERT key that bakes it at the
  device's current settings so the eventual sync is a plain copy.
- **Every weight of every typeface.** The Theme Editor's font rows expand to map
  a real face to each weight — light, medium, semibold and bold — instead of
  synthesising them from one face. The OLED headline honours them too.
- **Screen Shade.** The dark wash over the OLED glass is now a theme colour
  rather than a fixed value, so light themes stop looking muddy.
- **Faster YouTube playback.** Progressive YouTube audio is fetched in bounded
  byte ranges instead of one open-ended request, which YouTube throttles by
  roughly 500x. A stream that would not start now starts.

### Changed

- **Queuing for a disconnected device no longer converts anything.** It records
  what you picked and stops. Convert it when you want, at settings you can still
  change, with PRE-CONVERT — or leave it and let SYNC convert on the way over.
- **Scope is Queue, Prep or Selection.** "All Loaded Tracks" is gone: no setting
  now means "everything", so the queue can no longer fill itself with a whole
  library you did not choose.
- **Sending to a device holds its route.** Finishing a send keeps the device and
  empties the queue, so filling one album by album no longer means re-choosing
  it. Format changes made while a device is routed save to that device instead of
  overwriting your own defaults.
- **The floating artwork viewer** carries one control bar instead of scattered
  buttons.
- *Re-stage with Current Settings* is now *Re-convert with Current Settings*, and
  keeps the entry in place rather than removing and re-adding it.

### Fixed

- Selecting CNVRT pushed the OLED's annunciator rail off the top of the glass.
- The OLED printed a hardcoded output path, which was wrong for anyone with their
  own output folder and wrong for every device transfer.
- Queue badges were keyed by track ID, so re-digging a folder silently cleared
  every one of them. They follow the file now.
- The zoom control in the floating artwork viewer lost its background.
- A long pre-convert could discard tracks queued while it was running.
- A YouTube stream that 403s on a just-resolved URL re-resolves once instead of
  going straight to the error panel.

## 1.5.0 (61) — 2026-08-13

Make it look like yours. CrateDigger's skins were always plain JSON files you
could hand-edit; now there's an editor for them, and a theme can carry its own
light and dark versions instead of shipping as a pair.

### Added

- **Theme Editor.** Press THEME in the header for the theme browser, then EDITOR
  to start changing one. Every colour, corner radius and typeface is a control,
  and the app repaints as you work — the preview is the application behind the
  panel, not a mock-up of it.
- **One theme, light and dark.** A theme set to BOTH carries both looks and
  follows your system setting. Each version stores only what it changes, so the
  shared palette is still written once. COPY TO LIGHT/DARK starts one version
  from the other.
- **Fonts, with real weights.** Choose any font on your Mac for the interface,
  the readouts or the display, and pick which style is the base. The family's
  actual weights are mapped, so bold headings use a drawn bold rather than a
  smeared regular. A font file can also be bundled inside a theme so it travels
  with it.
- **Cobalt**, a fourth built-in theme — and a worked example of the format:
  shared accents, separate light and dark layers, custom corner radii and a
  mapped font family.
- **DUPLICATE** forks the theme you're editing, so "start from this one" doesn't
  mean saving, closing and reopening a copy.
- **What's New**, shown once after an update and replayable from Help.
- **Appearance** is now a top-level menu, beside Playback.
- Installed themes can be **deleted** from the theme browser. The four that ship
  with the app are marked DEFAULT and can't be removed.

### Changed

- The THEME key opens the theme browser in the inspector — the way CNVRT opens
  the Patch Bay — instead of cycling blindly through an ever-growing list.
- Light / Dark / System now applies **to the theme you're using**, which stays
  selected, rather than switching the theme off. The themes that ship with the
  app are listed first and marked DEFAULT.
- Every editable token is named for what it paints ("Top Highlight", "Screen
  Glass") with a note saying where it appears, and the notes are searchable.
- Themes that are skipped at load — a malformed file, a duplicate id — are now
  listed instead of being dropped in silence.

### Fixed

- Editing an installed theme rewrote a *new* file derived from its id rather
  than the file it came from. Where a theme's folder was named differently from
  its id, the two collided and the edit was discarded on reload.
- A theme that overrode only fonts didn't re-letter the interface until
  something else happened to redraw.
- Choosing a font from the system panel never reached the theme.
- LIGHT/DARK changed a flag and nothing visible.
- A wide themed font could wrap the app name in the header and push the
  toolbar buttons out of the row.
- Built-in themes were each loaded twice on some launches, reporting themselves
  as duplicates.
- The themes that ship with the app were missing entirely when CrateDigger was
  run from Xcode, because only one of the two places a bundled resource can
  live was being searched.

## 1.4.0 (59) — 2026-08-12

Album art that Rockbox players can actually draw, and a device queue you can
fill in more than one go.

### Added
- **Folder cover art for Rockbox iPods.** Those players read a cover file in
  the album folder before they look inside the track, and they render a large
  embedded cover in greyscale once they have to scale it down to the theme's
  art size — which is why covers arrived in black and white. Transfers to a
  Rockbox iPod now leave the picture out of the files and write a 400 px
  `cover.jpg` beside them instead. Applies to every route onto the device:
  converting to a mounted player, copying originals, and the offline queue's
  SYNC.
- **FIX ART.** Select a connected device and press FIX ART in the inspector to
  write those covers for everything *already* on it — the art is read back out
  of the tracks on the device, so a player filled before this existed is fixed
  without re-sending a thing. The audio files aren't touched.

### Changed
- **A transfer narrates itself on the OLED.** The CNVRT screen now shows the
  running count, a progress bar, and the file being written (titled with the
  device name when it's a transfer). The progress bar inside the Patch Bay's
  queue list is gone — that pane is a list of what's in scope again.

### Fixed
- **Sending a second batch to a device adds to the queue.** Picking albums in
  one crate, sending them, then picking more in another crate replaced the
  queue instead of adding to it, so the first batch was silently dropped.

## 1.3.3 (58) — 2026-08-11

A small fix pass on the DEV screen and the switcher keys.

### Fixed
- **Connected players report their real free space.** A mounted iPod (or any
  FAT32/exFAT player) read as "0.0 GB FREE · 100% USED" — macOS reports no
  capacity for those volumes through the key the app was asking for. Free space
  now falls back to the plain volume reading, which also makes the "not enough
  room" warning before a conversion or a device sync accurate on those players.
- **The OLED keeps its size on the DEV screen.** Selecting a device grew the
  glass past the header; the screen is now fixed hardware for every view, and
  the device readout was trimmed to sit inside it.
- **The display key matches the other keys.** The strip above VIEW / THEME / EQ
  rendered 14pt narrower than them — the column had been silently clamped to a
  width the three keys below it overflowed.

## 1.3.2 (57) — 2026-08-09

Housekeeping for the filing workflow: staging that remembers what you filed,
grouping that stops asking questions it can answer itself, and a way out of a
tag check you didn't mean to start.

### Added
- **Media format icons.** Tag an album as CD, Vinyl, Cassette or Digital and the
  medium shows as an icon beside its name in the browser — including on each
  pressing under a grouped release, which is where a vinyl rip and a CD remaster
  most need telling apart. Right-click an album → **Media**, or use the FORMAT
  pill in the artwork inspector. Untagged albums look exactly as before.
- **Stop a tag check.** FIX TAGS on a large selection is thousands of file
  reads; the button now turns into **STOP** while it runs. Tags already healed
  from the files are kept.
- **Double-click the header to zoom.** The top strip of the window now behaves
  like a title bar, honouring your Desktop & Dock setting for what a double-click
  should do.

### Changed
- **Grouping versions no longer asks for a primary.** It picks the best copy
  (lossless first, then sample rate and bitrate, earliest year breaking ties).
  "Set as Primary" on a pressing still moves it.
- **Filing from the Prep Crate keeps you in the Prep Crate.** Adding an album to
  a crate used to jump you to that crate, which meant navigating back for every
  album in a backlog. It now follows the records only once staging is empty.

### Fixed
- **Digging a crate no longer stops the music.** A dig cleared the playback
  queue before scanning; it merges into the Prep Crate, so there was never
  anything to clear.
- **The Prep Crate no longer refills with albums you already filed.** Staging
  was rebuilt on launch by rescanning your dig folders, handing back everything
  you'd put away. It now skips anything a crate already holds — on launch, and
  on a re-dig of the same folder.

## 1.3.1 (56) — 2026-08-08

Fixes from the first day of 1.3.0, plus a browser that can finally show you a
playlist as a playlist.

### Added
- **The Track view is a table.** Pick your columns — track no, title, time,
  artist, album artist, album, genre, year, format, bitrate, sample rate, disc —
  by right-clicking the header bar. Click a header to sort, click again to
  reverse. Your choice is remembered.
- **Playlists open as a list, in their order.** They were being shown as
  Artist · Album · Track, which says nothing useful about a playlist, and the
  M3U's order was thrown away on load. The leading column is now the playlist
  position, and **you can drag rows to rearrange them** — the file is rewritten
  as you go. Sorting by a column is a view of the playlist rather than a change
  to it, so the # header takes you back to its own order.

### Fixed
- **Dragging several tracks dragged only one.** A multi-selection now travels
  intact, albums and artists too.
- **Fixing tags gave up on files with a damaged embedded cover.** A cover stored
  under the wrong image format — common enough to hit a whole album at once —
  made the tag write fail and the file kept its old tags. Those files now save,
  with the unreadable cover removed and a note telling you which ones so you can
  re-add artwork from the ART tab.
- **A failed tag write no longer fills the screen.** The error dialog was
  printing FFmpeg's entire analysis of every file that failed. It says what went
  wrong now, in one line.

## 1.3.0 (55) — 2026-08-08

A pass over the hardware: the transport now looks and feels like moulded
silicone, the interface keys went flat, and the DISC cut editor works.

### Added
- **Artwork search shows the real size of every image.** Tiles that used to
  claim "HD" on the strength of a metadata hint now report the original's
  actual pixels — HD above 1000px, the exact dimensions otherwise, and always
  in the tooltip. The Cover Art Archive advertises a 1200px tier even for 600px
  scans, so the old badge was routinely wrong.

### Changed
- **The transport is silicone.** Play/pause and the seven keys around it are
  moulded caps with the symbol printed under the surface — matte, no highlight
  ring. Playing lights an LED behind the cap that blooms from the middle, at
  about a third of the old glow. The mini player uses the same caps.
- **Interface buttons went flat** — one fill, a hairline edge, no gradient or
  shadow — and every key in the app now draws its label at the same size and
  tracking.
- **The EQ, spectrum and VU meters run the VOLUME fader's colours**, so the
  whole footer lights from one palette and follows the theme's accents.
- **VOLUME reveals a fixed colour ramp** as you slide instead of squeezing the
  gradient into the filled part, so a given colour always means the same level.
  POSITION is a single accent.
- **ADD TO CRATE lights its label** instead of turning the whole key into a lamp.
- The floating artwork viewer's controls sit on a matte slab, so they no longer
  disappear against light artwork.

### Fixed
- **The DISC cut editor responded to nothing.** Dragging the disc moved the
  whole window, and neither the drag nor the rotate/zoom sliders changed what
  was on screen. All three causes are fixed; the ADJUST CUT button also moved
  down out of the artwork and appears on hover.
- **The expand button in artwork search selected the image instead of previewing
  it.**
- **The browser highlighted rows you hadn't clicked** after switching sources — a
  multi-artist selection from the previous crate was never cleared.
- **The mini player stayed dark in the light theme.**
- **Radio could wedge under load.** Every yt-dlp call blocked a thread in the
  pool the whole app schedules on. Failures now also report yt-dlp's real
  reason instead of a generic message.
- Artwork toolbar buttons no longer truncate to "ADD ART…" / "SEARCH O…".

## 1.2.33 (54) — 2026-08-05

Housekeeping for the library index — the file that remembers every track you've
scanned.

### Changed
- **Saving the library no longer rewrites it when nothing changed.** Saving a
  crate re-filed every track it held, so adding one album to a big crate rewrote
  the entire index. Only real changes cause a write now, which on a large
  library is the difference between a visible pause and nothing at all.
- **The index is written in a stable order.** It used to come out shuffled every
  time the app restarted, so backup software saw the whole file as new on every
  save even when nothing had been edited. An unchanged library now writes
  identical bytes, so Time Machine and cloud sync have almost nothing to copy.
  Your next save rewrites it once as it settles into the new order.

### Fixed
- **A damaged library index is no longer overwritten.** If the index existed but
  couldn't be read — cut short by a crash, a full disk, an ejected drive —
  CrateDigger started up empty and the next save replaced the whole library with
  whatever had been added since. It now stops and tells you, leaving the file
  alone so it can be restored.

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
