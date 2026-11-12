# Device transfers: what's already there, upgrades, and folder art

2026-11-11. Status: draft for approval.

## Why

Sending music to a device today behaves three different ways depending on
the path it takes, and none of them understands "this album is already on
the device":

| Path | What happens when a file is already at the destination |
|---|---|
| Copy-mode device, mounted (`runExternalDeviceCopy`) | Silently writes `01 Song (2).flac` beside it. No prompt. Summary says "N files copied". |
| Convert-mode device, mounted (CNVRT hand-off, `runConversion`) | One alert: Skip Existing / Overwrite / Cancel. In template mode, an earlier Merge / Version folders / Cancel prompt for album folders holding other audio. |
| Device offline, queued (`stageForSync` → `syncQueuedTransfers`) | Queuing dedupes against the queue only. SYNC skips any entry whose exact path exists on the device, with no option to replace. |

All three detect "already there" by exact path. Changing format (MP3 → FLAC)
changes the extension, so an upgrade is never recognised as one; Overwrite
would leave both files on the device.

The user's picture: **drag a whole crate onto the device and have the app
copy only what isn't there yet, then ask about the real duplicates.** And: a
playlist of loose tracks was sent earlier; now sending the full album should
fill in the rest, not duplicate what's there.

Separately, the `cover.jpg` sidecar a Rockbox iPod gets is invisible as an
option. It is switched on by the device kind alone
(`ExternalDeviceProfile.usesFolderCoverArt`), and on that device the CNVRT Art
row is forced to **Strip**, which is true of the files but hides the cover
written beside them. Preferences ▸ Devices has no artwork control at all.

## Goals

1. One behaviour for every device path (copy, convert, offline queue): new
   tracks go over, identical tracks are skipped, tracks that differ are
   decided by the user.
2. Recognise the same track on the device by **what it is** (album and
   disc/track), not by file name, so format upgrades, better art and other
   releases are seen.
3. Filling the gaps in a partially-present album is silent and lands in the
   album's existing folder.
4. Never decide on the user's behalf what happens to a differing album, and
   never remove device files without the user choosing to.
5. Folder art (`cover.jpg`) becomes a visible, per-device switch that can be
   combined with any of Keep / Re-embed / Strip.

## Non-goals

- Changing how ordinary (non-device) folder conversions handle collisions.
  Their Skip/Overwrite and version-folder prompts stay as they are.
- Track-by-track decisions. The decision unit is the album.
- Content fingerprinting (AcoustID etc.) to match tracks. Tags and numbers only.
- Syncing deletions (removing from the device what isn't in the crate).
- Stock (non-Rockbox) iPod databases; that is the parked 2.4 work.

## Anti-goals (failure even if it "works")

- Any path that still writes ` (2)` copies onto a device without asking.
- A modal per album on a 200-album crate.
- A pre-selected choice the user can confirm without looking ("ask the user").
- Every converted album reading as "different art" because re-encoding
  changed the art's hash.
- Deleting files on the device that the user didn't choose to replace,
  including non-audio files the app doesn't recognise.

## What gets built

### 1. Comparing the batch against the device (Core)

A pure Core service (name is the builder's call, e.g. `DeviceDuplicateMatcher`)
takes the tracks being sent, the device profile's transfer settings and the
device's catalog (`[LoadedTrack]` from `DeviceCatalogStore`), and classifies
each album in the batch.

**Album identity** (my call): album artist, falling back to artist, plus
album title, both case- and diacritic-folded with the disc suffix stripped,
reusing the normalisation in `OutputPathPlanner.albumFolderKeys` where
possible. **Year is not part of it.** A remaster or reissue often carries a
different year, and the user wants a different release *asked about*, not
copied in silently beside the old one. The cost is that two releases sharing
a title (two self-titled albums) meet as one identity. They then read as a
different release and come to the sheet, where Keep both separates them for
good (see "several copies" below).

**Matching a track**: within an album identity, same disc number + track
number (missing disc number = 1). When either side has no track number, fall
back to folded title.

**Classifying an album.** Let *S* be the tracks sent and *D* the device's
tracks with the same identity. Each sent track is one of: **missing** (no
counterpart in *D*), **same** (counterpart in the same form, below) or
**changed** (counterpart in a different form). The album is then:

- **New**: *D* is empty. Planned and copied normally, without asking.
- **Present**: every sent track is *same*. Skipped without asking, counted as
  "already on device". This holds even when *D* has more tracks than *S*
  (sending 5 tracks of an album the device holds in full).
- **Gaps**: no track is *changed*, at least one is *missing*, and the album
  is not a different release. The missing tracks are copied without asking
  into **the device's existing album folder** (the folder *D* lives in), not
  a freshly planned one, so a year or template difference can't split one
  album into two folders. That includes the case where none of the sent
  tracks is on the device yet (device has 1 and 3, 2 and 4 are sent).
- **Differs**: any track is *changed*, or the album is a **different
  release**. Goes to the review sheet.

**Different release** means, for any track pair matched by disc + track
number, the folded titles differ, or both sides carry a track-total tag and
the totals differ. File counts on either side never count as a difference by
themselves: a partial album on the device is the gap-filling case.

**Several copies on the device** (e.g. `Kind of Blue` and `Kind of Blue [2]`
after a Keep both). Each device album folder holding that identity is a
separate candidate *D*. If any candidate classifies the album as Present,
it's Present. Otherwise the candidate sharing the most matched tracks is
the one compared, shown in the sheet ("2 copies on device") and acted on by
Replace. Ties go to the folder the planner would have chosen.

**A destination path that is taken but unmatched** (two albums' `01
Intro.mp3` in a flat layout, or a stale catalog). It is never overwritten
silently and never given a ` (2)` silently. It goes to the sheet as a row
for its album, saying a different file already uses that name. Replace
overwrites it, Keep both writes a suffixed name (explicitly chosen, so not
silent), and Leave it skips. Every write path checks the file system just
before writing, so a stale catalog lands here too, not in a silent
overwrite.

**Keep both in layouts without album folders** (`flat`, `sourceRelative`):
the new files get ` (2)` file names. It's the user's explicit choice there.

**"Same form"**: on a copy-mode device, the source's format, bitrate and
sample rate against the device copy's; a difference in any is "changed". On a
convert-mode device audio form is not compared at all (see "Answers that
stick" below); only art and different release count there.

**Art difference** is by pixel size, never by hash (convert re-encodes art):
the largest of embedded art dimensions and, when present, the device album
folder's `cover.jpg` dimensions, versus what the transfer would write (the
profile's art cap applied to the source art). A different size counts as a
difference; identical size does not.

A differing album is always one row, never per-track mismatches.

In layouts without album folders (`flat`, `sourceRelative`) the matcher still
matches by tags; Gaps tracks are planned normally since there's no album
folder to reuse.

### 2. The catalog has to be current

- Before comparing, the transfer needs the device's catalog. If there is a
  saved catalog, use it. If not, scan the device first, **with the same
  whole-volume scan browsing uses** (my call), saved under the same key, so
  browsing a device behaves exactly as it does today. Progress shows on SCAN
  as it does for a browse.
- **Existing bug to fix:** only SYNC invalidates the catalog today
  (`invalidateDeviceCatalog`), and invalidating *deletes* it. Copy transfers,
  convert transfers and FIX ART don't touch it, so the browser shows stale
  contents. My call: **patch the catalog in place after every write**
  (copy, convert, sync, replace-delete, FIX ART) instead of deleting it: add
  the written files as `LoadedTrack`s (tags known from the source plus the
  output format), remove deleted ones. That keeps a last-known catalog for the
  offline queue to compare against. A patched entry that turns out wrong is
  caught by the file-system check before every write and fixed by RESCAN.
- A stale saved catalog on a mounted device is still a risk (files changed on
  the device by another program). My call: accept it; RESCAN fixes it, and
  every write path below still checks the file system before writing.

### 3. The review sheet ("Already on <device name>")

Shown once per transfer, only when at least one album **Differs**. AppKit
sheet like the others (`NSViewController` + `onDecision`), presented from the
root so it works in the compact player.

- One row per differing album. Each row shows the album and artist, then
  what's on the device next to what would be sent: format/bitrate, track
  count, art size. Example:
  *Kind of Blue* · on device: MP3 128k, 5 tracks, art 600 px → sending:
  FLAC 16/44.1, 11 tracks, art 1400 px.
- Three choices per row, **none pre-selected**:
  - **Replace**: the album's existing audio files on the device are deleted,
    and the new tracks are written into the same folder. The folder's
    `cover.jpg` is replaced when folder art is on.
  - **Keep both**: the new copy goes into a sibling version folder
    (`Kind of Blue [2]`, reusing `nextAvailableVersionFolderName`). Nothing on
    the device is touched.
  - **Leave it**: this album is skipped entirely; the device is untouched.
- A "Set all to…" control at the top applies one choice to every row.
- The confirm button stays disabled until every row has a choice. Cancel
  stops the whole transfer (nothing is written, including New and Gaps).
- A line above the rows summarises the rest of the batch: "120 new · 14
  already there · 6 albums to finish". Those need no decision.
- The look is decided by the user from a real-window capture at true size
  before it's approved (see project memory on design review). Layout
  details are the builder's to propose.

**What Replace removes** (decided by the user):

- **Quality or art upgrade** (same release): only the device tracks that have
  a counterpart in what's sent are swapped. Device tracks with no counterpart
  stay. Sending 5 FLACs over an 11-track MP3 album leaves 5 FLACs and 6 MP3s.
- **Different release**: the whole device album (every audio file of the
  compared copy) is removed and the sent release takes its folder, so a
  folder never holds a mix of two releases.
- The row says which of the two it will do, with counts ("replaces 5 of 11
  tracks" / "replaces the whole album, 11 tracks removed").

**Answers that stick** (decided by the user):

- **Leave it is remembered** per device and album identity, and that album
  stops coming to the sheet. Where it's stored is the builder's call (it
  belongs to the device profile, not the library). My calls on how it is
  undone: the sheet has a "Show N albums left alone" toggle that brings them
  back as rows, the transfer summary counts them ("N left alone, as before"),
  and Preferences ▸ Devices has a button to forget them all. When no sheet
  would otherwise appear, the summary line is the only reminder.
- **A change to the device's own settings is not a difference.** On a
  convert-mode device every file is written at the profile's format, so an
  audio-form difference there can only come from the profile having changed
  since. My call on the rule: **on convert-mode devices audio form is never
  compared**, only art size and different release. Re-converting what is
  already on a device to new settings is out of scope here.
  Known limit, flagged: changing a profile's art size cap still makes albums
  read as differing in art. The builder may avoid that by comparing source
  art against the cap only when the source art itself is larger than what the
  device holds, or leave it.

**Replace deletes, it does not trash** (confirmed by the user): on a
removable volume, moving to the Trash keeps the files in the device's hidden
`.Trashes`, still taking space and, on some players, still visible. Replace
removes only the audio files the matcher attributed to that album on the
device (and `cover.jpg`); any other file in the folder stays.

Order of work for a Replace: write the new files first, then delete the old
ones, so an interrupted transfer never leaves the album missing. Where an old
and new file share a path (same format, different art), the write overwrites
it in place.

### 4. Wiring per path

- **Copy-mode, mounted.** `runExternalDeviceCopy` stops planning with
  `avoidExistingFiles: true`. It runs the matcher, shows the sheet if needed,
  and copies according to the decisions. A Gaps album's tracks are planned
  into the device's existing album folder.
- **Convert-mode, mounted.** The device hand-off to CNVRT keeps its cockpit.
  When Go is pressed for a device run, the matcher and sheet replace both the
  version-folder prompt and the Skip/Overwrite alert **for device runs only**.
  Non-device conversions keep their prompts.
- **Offline queue.** At queue time, compare against the last-known catalog
  and show the same sheet. The decision is stored on each queue entry
  (`DeviceSyncQueueEntry` gains it, and decoding stays compatible with
  existing queue files). A device that has never been scanned has no
  catalog, so everything queues as New. At SYNC the device is the truth:
  re-run the matcher against its catalog (scanning first if there is none).
  Entries whose stored decision still fits run. If any album now Differs and
  has no decision, **the same sheet appears at SYNC** before anything is
  written, listing just those albums (my call). Nothing gets stuck in the
  queue waiting for a remove-and-resend.
- **Summaries** (all paths) report copied, already there, gaps filled,
  replaced, kept both, left alone and failed, with per-file detail lines like
  today's.

### 5. Folder art as a switch

- `ExternalDeviceTransferSettings` gains `writesFolderCoverArt: Bool`.
  Synthesised `Codable` today, so decoding needs a default for profiles saved
  without the key: **true for `rockboxIPod`, false otherwise**, so nothing
  changes for existing devices. `usesFolderCoverArt` reads the setting
  instead of the kind. Choosing the Rockbox kind for a new profile turns it
  on by default.
- The switch is independent of the Art mode, so the **embedded art mode has
  to be stored per device too** (my call). Today it isn't: the sync and bake
  paths derive it as `conversionPreset(embeddingArtwork: !usesFolderCoverArt)`,
  so once folder art reads a setting, turning it on for a generic device
  would quietly strip embedded art. `ExternalDeviceTransferSettings` gains
  `artworkMode: ArtworkMode`, decoded for existing profiles exactly as it
  behaves today: Strip for `rockboxIPod`, otherwise Keep when
  `artworkMaxDimension` is nil, else Re-embed. Every path (mounted convert,
  bake, SYNC) reads it. It's editable in Preferences ▸ Devices and saved back
  by `persistSelectionToDevice` from the cockpit.
- Rockbox profiles default to Strip + folder art, because Rockbox draws a
  large *embedded* cover in greyscale once it has to scale it down. Both
  controls stay enabled there. The defaults only reflect what works best.
- **Where it appears:** Preferences ▸ Devices (per profile), and a new row on
  the CNVRT Patch Bay under Art, e.g. "Folder Art: On / Off". The forced
  `artworkMode = .none` for Rockbox in `transferToDevice` becomes the profile's
  default instead of an override.
- **Ordinary folder conversions** get the same switch on the Patch Bay
  (persisted in `ConversionOptionsSelection`), using the existing
  `FolderCoverArtWriter`. Default off.
- Copy-mode devices honour the switch too (they already write covers for
  Rockbox today).
- The DEVICES OLED cell keeps reading "cover.jpg" when folder art is on, and
  shows the embedded mode otherwise; with both, it should say both (wording is
  the builder's).
- Folder art size stays `FolderCoverArtWriter.defaultMaxDimension` (400 px);
  making it configurable is out of scope.

## Constraints

- New decidable logic (matching, "same form", art comparison, the Gaps folder,
  decision → file plan) lives in Core with XCTests; the view model only wires.
  CLAUDE.md: view-model glue is where bugs concentrate.
- Every new writer to the device respects the existing preflights
  (writability, free space). Free space counts only what will actually be
  written, minus what Replace frees (my call: don't credit the freed space,
  keep the check conservative; the builder may refine).
- Busy Signals: the scan before a transfer and the transfer itself each stamp
  `beginBusyJob`/`endBusyJob`.
- The sheet presents from `LibraryPresentations`/root, not from `MainShell`.
- Release line: this is 2.3.x beta work on `v2.3`.

## Left to the builder

- Type and file names; how the sheet is laid out (subject to the user's
  approval from a real capture).
- Whether to invalidate or patch the catalog after a write.
- Exact text of summaries, OLED cells and the Patch Bay row.
- How to present progress for the pre-transfer scan.
