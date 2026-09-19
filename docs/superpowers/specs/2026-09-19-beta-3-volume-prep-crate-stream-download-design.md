# 2.2.0 beta 3: volume readout, footer, Prep Crate guide, stream downloads

2026-09-19. Target: 2.2.0 beta 3 (build 93), on `v2.2`.

Four independent items. Each ships on its own commit and none depends on
another, so a late one can slip to beta 4 without holding the rest.

1. Volume: a readout on the OLED, a dB / percent setting, and two fader bugs.
2. Footer: POSITION sits further from the left edge than VOLUME from the right.
3. Prep Crate: an empty Prep Crate explains itself.
4. Radio: download a stream for offline listening, split into tracks by chapter,
   with a Downloads list to see and remove them.

## 1. Volume

### What is there

The fader is a dB scale, not a percentage. `VolumeCurve` (Core) maps the
0...1 fader position linearly onto -60 dB...+5 dB, so unity (0 dB) sits at
`unityPosition` = 60/65 = 0.923 of the travel and the last 7.7% is boost.
Below unity the value goes to `AVPlayer.volume`; above it, `AVPlayer.volume`
stays at 1 and the extra is a makeup gain applied by `AudioLevelTap`.
`LibraryViewModel.playbackVolume`'s `didSet` is the one choke point: the fader
binding, the Volume Up / Down menu items and the keyboard shortcuts all pass
through it.

A permanent VOL meter used to sit in the OLED's corner and was removed on
purpose ("volume is a control, it belongs on the footer fader"). This brings
the number back only while it is changing.

### Readout

When `playbackVolume` changes, the OLED shows the level for 1.2 seconds through
the existing `showOLEDNotice`, which already restarts its timer on every call,
so a drag keeps the notice up and it clears itself after the last movement.

- Called from the `didSet`, guarded by `oldValue != playbackVolume`, so every
  route is covered once and the launch restore (which does not fire observers)
  stays silent.
- Text: `VOL  -12 dB`, `VOL  0 dB`, `VOL  +3 dB`, `VOL  MUTE` at the bottom;
  in percent `VOL  64%`. Same all-caps tone as `TAGS SAVED`.
- The string comes from Core: `VolumeCurve.readout(forPosition:unit:)`,
  next to the existing `label(forPosition:)`, which it reuses for dB.

### dB or percent

`VolumeReadoutUnit` (`decibels`, `percent`), default `decibels`, persisted as
`cratedigger.ui.volumeReadoutUnit`. A picker "Volume readout" in Settings,
Playback, copied from the CD animation speed option. No notification: the
view model reads the preference when it builds the notice.

**Percent means percent of the travel up to unity:**
`round(position / unityPosition * 100)`. The 0 dB tick reads exactly 100%,
the far end reads 108%, the bottom reads 0%. It describes where the fader is,
not the amplitude (true amplitude would read under 5% for half the travel).
The accessibility value on `VolumeKnob`, today `Int(value * 100)`, switches to
the same function so VoiceOver and the OLED agree.

### Bug: the fader snaps below the end

Three causes: the first two in `VolumeKnob.swift`, the third in the step logic.

- The unity magnet captures anything within 0.025 of 0.923. The boost zone
  above the tick is only 0.077 wide, so the magnet swallows a third of it.
  Narrow it to 0.012. The detent stays: with the percent readout it is now
  visibly "100%".
- `onTapGesture(count: 2)` (double-click resets to unity) coexists with a
  zero-distance drag, so two quick clicks near the far end first set the value
  and then overwrite it with 0.923. Double-click stays, but only acts when the
  click lands within the magnet band of the tick; elsewhere two clicks are two
  clicks.
- The Volume Up / Down steps are 0.05 of travel and walk 0.85, 0.90, 0.95,
  1.00, never landing on unity. `LibraryViewModel.setVolume` snaps a stepped
  value to `unityPosition` when the step crosses it. Decided in Core:
  `VolumeCurve.stepped(from:by:)`.

### Bug: no audible gain above unity (local files)

Reported on local files, where the gain stage should work, so this is a
root-cause investigation, not a guess. Order:

1. Measure, do not listen. Play a -12 dBFS sine (ffmpeg can generate it), read
   the level meter at 0.923 and at 1.0. The tap applies gain before it meters,
   so the meter shows whether the multiply runs at all.
2. If the meter moves and the output does not, the tap's writes are not
   reaching the output. It is created with
   `kMTAudioProcessingTapCreationFlag_PostEffects`. The 12-band EQ writes
   through the same buffer, so it is the discriminator: EQ audible means the
   writes land and the fault is in the gain value; EQ inaudible too means the
   flag is the cause for both, and `PreEffects` is the candidate fix.
3. If the meter does not move, follow `setMasterGain` from
   `applyVolumeToEngines` to `AudioLevelTap.store`. Known suspect: the gapless
   look-ahead item gets its own tap via `attachLevelMetering`, and a fresh tap
   may start at gain 1 until the fader next moves.
4. If everything works and +5 dB over 7.7% of travel is simply too little to
   notice on a loud master, that is a finding to bring back, not something to
   fix silently: raising `maxDB` moves `unityPosition` and with it every saved
   fader position.

Whatever the cause, it ends with a Core test where one can exist (a tap store
that carries its gain to a new item; `VolumeCurve` values) and a note in
`CLAUDE.md`'s Playback section.

**Not fixed here, stated instead:** radio streams and native DSD get no boost
(HLS exposes no audio track for a tap; DoP is bit-perfect by design). While
either is playing, the readout above unity is capped: it reads `VOL  0 dB` /
`VOL  100%` once the fader passes the tick, because that is what is heard.

### Tests

`VolumeCurveTests`: readout strings in both units at 0, mid, unity, max;
percent is exactly 100 at `unityPosition`; `stepped` lands on unity when
crossing it in both directions and clamps at 0 and 1.

## 2. Footer symmetry

The layout code is symmetric: both pods have the same padding (12), the same
`minWidth: 184, maxWidth: 380`, both sit in `maxWidth: .infinity` frames
inside one `HStack(spacing: 28)` with `.padding(.horizontal, 26)`, and
`FaderTrack` adds no inset of its own. Computed, both rails end 38 pt from the
footer's edge plus equal slack. The report is about the gap to the window
edge, so the code and the eye disagree and the first step is to find out
which is right.

1. Screenshot the running app at three window widths (minimum, 1200, 1440) and
   measure, in pixels, window edge to the first lit pixel of each rail and to
   each cap at both extremes.
2. If the gaps differ: find the element that breaks the symmetry (candidates:
   the footer not being centred in the chassis, the 477 pt transport pushing
   the HStack past its width at narrow windows so it overflows to one side)
   and fix that element.
3. If the gaps are equal, the asymmetry is optical and has two known sources.
   The transport has four keys left of PLAY and three right, so PLAY sits
   28.5 pt right of the footer's centre line and the left pod looks stranded.
   And VOLUME rests at 92% so its lit fill nearly touches its end, while a
   stopped POSITION rail is dark from the left. Fix the first: give the
   transport 57 pt of empty trailing width, so PLAY lands on the footer's
   centre line while both pods keep equal slack and equal edge gaps (each pod
   gives up 28.5 pt), then re-measure. The second is content, not
   layout, and is left alone.

Done means the measured gaps match within 1 pt at all three widths, with the
before and after numbers in the commit message. No unit test: this is layout.

## 3. Prep Crate guide

### What is there

An empty Prep Crate shows "No library loaded" and an OPEN FOLDER button. It
falls into `BrowserEmptyState.noLibrary` because selecting the source swaps in
an empty index and `isLocalSource` does not include `.prepCrate`. An empty
named crate gets the same wrong message.

### Change

`BrowserEmptyState` picks its content from a Core value,
`BrowserEmptyKind.resolve(source:libraryChosen:disconnected:)`:
`noLibrary`, `disconnected`, `prepCrate`, `emptyCrate(name)`. Pure and tested;
the view keeps its existing shell (icon, heavy headline, mono body at 380 pt,
one `KeyButton`).

Prep Crate, icon `tray.and.arrow.down` (the sidebar row's):

> **The Prep Crate is empty**
>
> This is the staging area. Everything you dig lands here first, so you can
> look it over before it joins your library. Scanning only reads: nothing on
> disk moves unless you ask it to.
>
> 1. DIG CRATE (⌘O), or drop a folder anywhere on the window.
> 2. Check it over: FIX TAGS, TAGS, artwork, CLEANUP.
> 3. Select what is ready and press ADD TO CRATE. It leaves the Prep Crate
>    when it is filed.
>
> [ DIG CRATE… ]

The key calls `openFolderViaPanel()`, as today. Names match the controls
exactly as they are labelled in the header and inspector.

Empty crate, same shell, no button:

> **"Name" is empty**
>
> Select albums or tracks in All Records or the Prep Crate and press ADD TO
> CRATE, or drag them onto this crate in the sidebar.

`noLibrary` also fires for an empty playlist, CD or device today; those keep
it. Only the two cases above change.

### Tests

`BrowserEmptyKindTests`: each source with and without a chosen library, and
disconnected taking priority for local sources only.

## 4. Stream downloads

### What

Right-click a stream in YT Records, **Download for Offline…**. The audio is
saved as one file into the library, lands in the Prep Crate like any dig, and
when the stream has chapters they arrive as Record Divider markers, so it
plays track by track immediately and converts or transfers to a device as one
file per track.

### Decisions

- **Split by markers, not by cutting.** Chapters map onto `RecordMarker`s on
  the imported `LoadedTrack`. Playback already navigates markers, and
  `planConversionJobs` already cuts one output per marker through
  `RecordTrackPlanner`, which is also what a convert-mode Transfer to Device
  runs. No new cutting code, the original stays whole and lossless, and a wrong
  boundary can be fixed in Record Divider afterwards.
- **Known gap, stated in the UI:** a copy-originals device profile sends the
  one whole file. The download's finish notice says so when chapters were
  found: "Convert or use a converting device profile to get one file per
  track."
- **Video and mix only.** A live stream has no end and a playlist is many
  downloads; both keep the menu item disabled with a tooltip. Playlists are a
  follow-up.
- **yt-dlp stays bring-your-own**, resolved by `ExternalToolLocator` exactly as
  for playback. Missing yt-dlp reuses the existing missing-tool alert.
- **AAC in m4a, not re-encoded** when YouTube offers it
  (`bestaudio[ext=m4a]`), falling back to extract-and-encode to m4a. Opus is
  better at the source but AVPlayer cannot play it.
- **One download at a time.** A second request while one runs is refused with
  an OLED notice.

### Personal-use notice

The first download shows an `NSAlert`, once:

> **Downloads are for personal use**
>
> Downloading keeps a copy of this stream on your Mac for your own offline
> listening. You are responsible for having the right to keep it. Do not
> share or redistribute what you download.
>
> [ Download ]  [ Cancel ]

`PreferencesStore.hasAcknowledgedStreamDownloadNotice`, the same shape as
`hasSeenWelcomeTour`, set only when Download is pressed; Cancel shows it again
next time. No "show again" setting.

### Core

- `StreamDownloader` (new, beside `StreamResolver`). `arguments(for:into:ffmpeg:)`
  is pure and tested, like the resolver's:
  `-f bestaudio[ext=m4a]/bestaudio -x --audio-format m4a --embed-metadata
  --no-playlist --no-overwrites --newline
  --progress-template download:%(progress._percent_str)s
  --ffmpeg-location <ffmpeg> -o <folder>/%(title)s.%(ext)s -- <url>`.
  The `--` terminator stays, as everywhere else.
- `StreamDownloader.progress(fromLine:) -> Double?` parses the progress
  template line. Pure, tested.
- `StreamingCommandRunning` (new protocol): like `CommandRunning` but delivers
  stdout line by line and returns a handle that can terminate the process.
  `CommandRunning` reads to end of file and cannot report progress;
  nothing else in the app needs this yet, so it is a separate small type and
  `ProcessCommandRunner` is untouched. Cancelling a download kills yt-dlp and
  deletes the `.part` file; unlike conversion, cancellation here is real.
- `RecordMarker.markers(from: [StreamChapter], duration:)`: closes each
  chapter on the next one's start and the last on the file's real duration
  (`StreamChapter.endSeconds` is optional, `RecordMarker.endSeconds` is not);
  drops chapters shorter than a second; returns empty for fewer than two
  chapters. Pure, tested.
- `StreamDownloadPlanner.folder(for:in:)`:
  `<destination>/<Channel>/<Title>/`, both through `PathComponentSanitizer`.

### App

`LibraryViewModel+StreamDownload.swift`, modelled on `+SACDImport`:

1. `guard !refuseWhileLibraryDisconnected()`.
2. Personal-use notice if not yet acknowledged.
3. Destination: `currentConversionDestinationURL ?? managedLibraryFolderURL`,
   else the existing "No Destination Set" alert.
4. Refresh metadata if the stream has no chapters cached yet, so a first
   download still splits.
5. Run off the main actor; progress feeds `conversionProgress` with
   `oledView = .cdRip`, the way the SACD import does, with the percent as
   completed over 100. Browsing and playback are not touched.
6. On success: write `cover.jpg` from `thumbnailURL` into the folder (folder
   art is already `resolveArtwork`'s second rung, and embedding a thumbnail in
   m4a needs yt-dlp extras we cannot count on), then `loadFolders([folder])`.
   The markers and tag defaults wait in a `pendingStreamImports` map keyed by
   file path, which `handleImport` consumes before staging: it sets
   `recordMarkers` from the chapters and fills blank tags (artist from the
   channel, album from the stream title). An entry whose file never arrives is
   dropped when the scan ends.
7. Failures go through `StreamFailureAdvisor` and the inline fix panel, not a
   new alert.

`RadioListView`'s context menu gains **Download for Offline…** between Copy
Link and the divider. The downloaded file is an ordinary library track from
then on: it scrobbles, counts plays and can be retagged. Downloading twice is
stopped by the stream already having a download (the item reads **Remove
Download…** instead), with `--no-overwrites` behind it.

### Downloads list

A place to see what has been downloaded and to take a download back without
losing the stream.

- **The link.** `StreamSource` gains `downloadedPath: String?`, an additive
  optional, so old blobs decode unchanged. Set when the download's file is
  imported. A stream is "downloaded" when the path is set **and** the file
  exists: a file deleted in Finder simply drops out of the list, and the stale
  path is cleared the next time the list is built.
- **Where.** A third row under Radio in the sidebar, **Downloads**, with a
  count: `RadioCategory.downloaded`. It is a filter over the same streams, not
  a second store, so `RadioCategory.of(_:)` keeps answering live or records and
  `contains(_:)` answers the new case from `downloadedPath`. The row is hidden
  while nothing is downloaded. `RadioListView` draws it as it draws the other
  two, without the BROWSE and ADD URL keys, and its empty state is never seen.
- **On every radio list**, a downloaded stream's row carries an `OFFLINE` chip
  and its subtext adds the file size.
- **Playing a downloaded stream plays the file.** `StreamResolver.resolve`
  returns the local file URL when the stream has a download, before it ever
  runs yt-dlp, so it works with no network and no yt-dlp, and the chapter
  tracklist and OLED behave exactly as online. A pure branch, tested.
- **Remove Download…** in the row's context menu (all three lists), after a
  confirmation: *Move the offline copy of "Title" to the Trash? The stream
  stays in your list and plays online.* Then, in order:
  `guard !refuseWhileLibraryDisconnected()`; stop playback if this file is
  what is playing; take the track out of the Prep Crate, every crate, the
  `TrackStore` and the `ListeningStore` through the existing Remove from
  Library path; `FileManager.trashItem` the file (Trash, not delete, so a
  mistake is recoverable); trash its folder too when nothing but `cover.jpg`
  is left in it; clear `downloadedPath`. A failure to trash is reported and
  leaves the link intact.
- **Show in Library** on the same menu: `revealTrack` on the downloaded file,
  switching to the crate or Prep Crate that holds it.
- **Remove Stream** on a downloaded stream keeps the file. It is an ordinary
  track by then; only the link goes. The confirmation says so.
- **Moves.** The file can be renamed or moved by a retag, Rename, Move Library
  or Consolidate. `StreamStore.repointDownload(from:to:)` is called at the same
  choke points that already call `ListeningStore.repoint(from:to:)`
  (`updateTrackURLInIndex`, `updateTrackURLsInIndex`, and the move and
  consolidate loops). A missed one degrades to "not downloaded", never to a
  wrong file, because of the exists check.

### Tests

`StreamStoreDownloadTests` (old blob decodes with no path, `repointDownload`,
missing file reads as not downloaded, `RadioCategory.downloaded` membership),
`StreamResolverTests` gains the local-file branch (no runner call).
`StreamDownloaderTests` (argument vector for video and mix, refusal of live
and playlist, progress parsing including garbage lines),
`RecordMarkerFromChaptersTests` (open-ended last chapter, missing duration,
single chapter, unsorted input), `StreamDownloadPlannerTests` (sanitised
folder, empty channel). The view-model wiring is untested like the rest of it,
so everything decidable above lives in Core.

## Out of scope

- Playlist and live downloads; a download queue; re-downloading in place
  (remove, then download again).
- Raising the +5 dB ceiling, a limiter, boost on streams or DSD.
- Scroll wheel over the volume fader.
- Stock-firmware iPod sync (parked for v3).

## Release notes

What's New for 2.2.0 gains three lines (volume readout, Prep Crate guide,
stream downloads); the two fader fixes and the footer go in the changelog
only. `CLAUDE.md`: Radio section gets the download path, Playback gets the
boost finding, and the stale `ExternalDeviceTransferSheetController` mention
is removed.
