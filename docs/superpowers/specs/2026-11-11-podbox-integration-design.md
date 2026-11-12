# PodBox integration: one design from proposals A and B

2026-11-11. Status: draft for approval. Written while the owner was away, so
every choice below that the owner has not seen is marked **design's call**.

Sources: `.superpowers/podbox-research.md` ("the brief", sections cited as §
and Appendix A to F), `.superpowers/podbox-docs/`, proposals A and B in
`.superpowers/`, and the device-transfer duplicates spec and plan of the same
date, which this work sits on top of. Where the proposals disagreed about what
the code does, the code was read (see "Checked against the code").

## Why

The owner's iPod Video runs PodBox, a Rockbox fork, and holds 1,729 tracks.
CrateDigger treats it as a plain "Rockbox iPod": it copies or converts music
and writes a `cover.jpg` per album. The brief found two things wrong on the
real device today and a list of PodBox functions CrateDigger does nothing for:

- **macOS `._*` AppleDouble files are being read as music.** PodBox scans by
  extension, so `._01 - Zebra.m4a` is a track it cannot read. Its
  `unreadable.txt` is 20 KB of them, and past 256 refusals it re-parses them on
  every scan (§4). CrateDigger's own copies create them.
- **The iPod has no artist pictures at all** (§4). PodBox draws them from image
  files only, and nothing writes one.
- Nothing reads the player's play log back, writes playlists or lyrics, knows
  the firmware or its build, or tells the owner the one step only the iPod can
  do after a transfer.

The owner asked for PodBox to be "fully integrated ... so it supports 100% of
its functions such as artist images, folder structure, etc."

The device is real and irreplaceable in practice. The worst outcome of this
work is not a missing feature. It is a bug that damages the iPod.

## Goals

1. Every PodBox function in the brief has a stated outcome: built, built
   behind a named check on the real iPod, or done on the player with
   CrateDigger saying exactly what to do. Nothing is silently missing.
2. CrateDigger cannot damage the player. One guarded door for every byte
   written to or deleted from a device, with rules that tests prove without a
   device.
3. What the player learns (plays, ratings, its own playlists) can come back
   into the library without ever being counted twice.
4. The owner always knows the next step on the iPod (eject, rescan, Update Art
   Cache) at the moment it matters.
5. Each phase ships alone. Phase 1 is small enough to build in one night and
   already fixes the junk-files problem.

## Non-goals

- Writing the tag database, the art cache, sound analysis or any `.dat`, `.tcd`
  or `.aat` file. Running PodBox's Windows tools.
- Installing or updating PodBox firmware, themes, fonts or voices.
- Writing `config.cfg`. It is read.
- Managing ebooks. CrateDigger is a music library.
- Supporting stock Rockbox beyond what is already proven there (covers,
  cleanup, the scrobbler log). Nothing in the brief was verified on stock.
- Stock (non-Rockbox) iPod databases, the parked 2.4 work.
- A new `ExternalDeviceKind`.

## Anti-goals (failure even if it "works")

- Any write, rename or delete under `.rockbox/`, `.rockbox_backup/`, `.backup/`
  or `iPod_Control/`, by any path, for any reason other than the single
  exception named in phase 5.
- Overwriting or deleting a file CrateDigger cannot prove it wrote. A lost
  journal must mean "not ours", never "probably ours".
- Deleting a real file because its name starts with `._`.
- A play counted twice, or attributed to a track on a guess.
- Anything written to the device, or to listening history, because a volume
  named "IPOD" was plugged in. Mounting triggers reads only.
- Truncating, rotating or "marking as read" any log on the player.
- Rewriting a picture or cover with identical bytes, which changes its date and
  makes the player rebuild thumbnails for nothing.
- A wrong person's face shown as an artist because a name search guessed.
- A feature that rests on an inference shipping switched on before its check
  on the real iPod has passed.

## Decisions between A and B

The proposals converged on the foundation. B's is taken whole: capabilities
detected at mount, no new device kind, one guarded write door (allowlist plus
journal), the strict AppleDouble proof, a content-keyed play import, UUID
matched devices for anything automatic, and nothing written outside a session
the user started. A's feature list is taken for coverage. What remained open
after their responses is decided here. All are **design's calls**.

| # | Question | Decision | Why, in one line |
|---|---|---|---|
| D1 | Artist picture sources | Phase 2: the owner's own images, then Deezer. Phase 2b: MusicBrainz to Wikidata to Commons as a background job. fanart.tv, Discogs and TheAudioDB only with a key the owner enters (phase 5). Never Last.fm. | Deezer alone is thin for the owner's Brasil and Classical shelves; Commons needs no key; TheAudioDB's public key is test-only; Last.fm returns a placeholder star. |
| D2 | When a found picture is accepted without asking | Only when the name matches under PodBox's own fold **and** one of that artist's album titles on the device matches an album the source lists for the candidate. Everything else waits in the picker. | A wrong face is the visible failure, and the picker makes waiting cheap. B asked for exactly this over its own 10x rule. |
| D3 | Manual picker | Built, phase 2 (A's Artist Pictures sheet). | It is the only route to full coverage, and it writes through the same door. |
| D4 | Default picture location | `/Artwork/People/<Name>.jpg`. Artist folders are an option and the overflow target. | It works with the owner's Category level, wins on the player, and is one folder to undo. |
| D5 | Folder layout | Nothing changes for an existing profile. A "PodBox recommended" preset (`Album Artist / YYYY Album`) is the default for new PodBox profiles only, phase 4. | A template change must never move where the owner's next album lands without being chosen. |
| D6 | Play import: automatic or previewed | Previewed every time by default. A per-device "Import without asking" switch, off by default, UUID match required, falls back to the preview whenever anything is unmatched or ambiguous. Undo Last Import exists either way. | Listening history cannot be rebuilt; the owner has not seen an import yet. |
| D7 | Device path to library track | Tags decide (identity, slot, title, then duration). The journal's remembered library path only breaks a tie among candidates the tags already accept. | A hint can then never attribute a play to a track the tags reject, and no new repoint duty is created. |
| D8 | Last.fm for device plays | Built, phase 3b, opt-in per device, confirmed on each send, never when the player's log is in Last.fm mode. | A wants it for coverage, B's guards make a public, hard-to-undo act safe. |
| D9 | Ratings from the player | Read-only, fill unrated tracks only, phase 3b, after a real exported file exists as a fixture (M9). No "always use the iPod's". No write-back. | The format is known only from stock Rockbox; play counts in it overlap the play log. |
| D10 | Lyrics file | `<stem>.lrc8`. | Always UTF-8 by definition, so nothing depends on a BOM or the player's codepage. (Each proposal ended up arguing the other's first choice.) |
| D11 | Lyrics sources | Phase 4: a sidecar beside the library file, or LRC text in the source's tags. LRCLIB lookup is phase 5, off by default. | Copying what the owner has is integration; fetching is a new feature and sends track names out. |
| D12 | Playlist format | Exactly what the player writes: UTF-8 BOM, `.m3u8`, one absolute path per line with the learned `/<HDD0>` prefix, no `#EXTM3U`, no `#EXTINF`. No learned prefix, no playlists. | It is the only form proven to load, and extended lines add nothing on an iPod. |
| D13 | When playlists are rewritten | Only inside a session the user started (transfer, SYNC, Write Playlists Now). Never on connect. | Foundation rule: mounting never writes. |
| D14 | `/Artwork/Covers` | Built last (phase 5), only for profiles whose layout has no album folders, behind M11. | A Covers file overrides the folder `cover.jpg` and spends the cap shared with pictures. |
| D15 | Compilation album artist on converted copies | Phase 4, a per-device switch, on for new PodBox profiles, off for existing ones. Convert mode only; the library is never touched. | Without it compilations split by artist on PodBox (§2.4), but it changes tags the owner has not agreed to change. |
| D16 | Audiobook and podcast folders | Classifier and notes in phase 5. Routing to `Audiobooks/` and `Podcasts/` is a switch, on for new profiles only. | Tags decide the shelf on PodBox, so routing is tidiness, not function. |
| D17 | Owner-editable text files | `known_artists.txt` is the single file under `.rockbox/` CrateDigger may ever write, phase 5, behind M13 and the owner's yes. `trim.txt`, `tagnavi_*.config`, `overrides.cfg`, `player_name.txt` and theme `.usercfg` are shown and revealed in Finder, never written. | They are hand-written preferences with nothing from the library to fill in, and an absolute "never under `.rockbox`" rule is worth more than a text editor. |
| D18 | Audio files and the journal | Audio is checked by the policy and copied by the door's copy routine, but its deletion stays under the duplicates spec (the user's Replace). The journal keeps no hash for audio. | Hash ownership is for files a PodBox writer may replace by itself; an audio delete is already a decision the user made. |
| D19 | `cover.jpg` ownership | Unchanged from the duplicates spec: the transfer that wrote a folder's tracks owns its cover. The door adds identical-bytes skip, a Mac-side backup of the replaced cover and a safe write. | That question was already decided there; this only makes the write safer. |
| D20 | Cleanup size limit | A `._` file larger than 128 KB is left and counted, even with the right magic. B said 16 MB. | The twins macOS makes for attributes are 4 KB; a big one holds a real resource fork. |
| D21 | Cleanup scope | Only twins of media files (audio, image, playlist, lyrics, epub, pdf by the name after `._`). Other proven twins are counted and left. | The harm is to the music scan and the picture keys; the owner's Notes and Contacts are not ours to tidy. |
| D22 | Cleanup backups | Every deleted twin is first copied to the journal folder on the Mac. B kept none. | It costs about 7 MB for this iPod and makes the one deleting feature reversible. |
| D23 | Offer at mount | No dialog on connect. The device row and DEVICES screen show "N Mac files read as music" with a Clean Up action. | Mounting only reads; A's one-time prompt was the only modal-on-plug in either proposal. |
| D24 | Stock Rockbox and RockPod | Covers, cleanup, eject guidance, and the scrobbler log if present. Lyrics, playlists and the play log are PodBox only until someone has a stock device to check. | Features ship on facts; A's stock paths were inferences. |
| D25 | Unset player clock | The play counts, with no month bucket and no "last played". | Dating it at import time (A) would inflate this month. |
| D26 | Firmware shown when offline | Phase 1 shows it only while mounted. The last-seen line is stored with the PodBox preferences in phase 2. | Phase 1 then changes no file the duplicates work is editing tonight. |
| D27 | Root-level files | Allowed for audio and covers only when the profile's music folder is empty (a direct-file player). B denied the root always. | The app supports such players today (see below). |

### Checked against the code

- `PathComponentSanitizer.sanitizedComponent` replaces only `/`, `:` and `\`
  (`OutputPathPlanner.swift:552`). It is not FAT-safe; A assumed it was. `? * "
  < > |`, trailing dots and Windows reserved names reach the device today.
- `ExternalDeviceProfile.match` falls back to mount path, then to the volume
  **name** when either side has no UUID (`ExternalDeviceProfile.swift:347`).
  Every Rockbox iPod is named "IPOD", so B's UUID rule is needed.
- `ListeningStats.recordPlay(at:)` sets `lastPlayed = date` unconditionally
  (`ListeningStats.swift:106`). An imported old play would move it backwards.
- `FolderCoverArtWriter.write` uses `Data.write(options: .atomic)` and replaces
  any cover present (`FolderCoverArtWriter.swift:46`).
- Three device copy sites use `FileManager.copyItem`, which carries extended
  attributes: `LibraryViewModel+ExternalDeviceTransfer.swift:402` and
  `LibraryViewModel+DeviceSync.swift:403` and `:419`. A fourth path lets ffmpeg
  write straight onto the device.
- `FolderTemplateConfig.separators` exists (`OutputPathPlanner.swift:97`), so
  the `YYYY Album` folder needs no planner change.
- `LastFMScrobbler` has single `scrobble` only; no batch call.
- `LibraryIndexFiles.extensions` is `cdcrate, cdtracks, cdplays`
  (`LibraryIndexCopy.swift:7`).
- Preferences ▸ Devices tells the user to leave the music folder blank "for
  direct-file players that expect tracks at the device root"
  (`DevicesPreferencesView.swift:165`), hence D27.
- `ConversionService` already passes `-map_chapters 0`, so converted
  audiobooks keep chapter marks in formats that carry them.
- On this branch the duplicates work has landed its matcher (Task 1) and is
  mid Task 2. `DeviceTransferExecutor` and `patchDeviceCatalog` (Task 5) do not
  exist yet. Phase 1 is laid out so its Core half needs neither.

## Safety

This section outranks every other. A writer that cannot meet it is not built.

### What CrateDigger may touch on a device

| Area | Read | Write | Delete |
|---|---|---|---|
| Music folder (the profile's subpath) | yes | audio, `cover.jpg`, later `.lrc8`, `folder.jpg`, `database.ignore` | audio the user chose to Replace; files the journal proves ours; proven `._` twins |
| `/Playlists` (or the configured catalog folder) | yes | `*.m3u8`, top level, phase 4 | journal-proven ours; proven twins |
| `/Artwork/People`, `/Artwork/Covers` | yes | `*.jpg`, top level, phases 2 and 5 | journal-proven ours; proven twins |
| `.rockbox/` | a fixed list of small text and header reads (below) | **never**, except `library/user/known_artists.txt` in phase 5 | **never** |
| `.rockbox_backup/`, `.backup/`, `iPod_Control/`, `.Trashes/`, `.Spotlight-V100/`, `.fseventsd/` | no | **never** | **never** |
| `/.scrobbler.log` | yes | **never** | **never** |
| Anything else on the volume | listing only | never | proven twins of media files only |

Reads under `.rockbox/`: `library/format.dat` (first 28 bytes),
`rockbox-info.txt`, `default-config.cfg`, `config.cfg`,
`library/cache/unreadable.txt`, `library/user/playback*.log`,
`library/user/player_name.txt`, `database_changelog.txt`, the first line of
`tagnavi_custom.config`, `.playlist_control` (the `P:` lines, for the path
prefix), the 28-byte header of `library/cache/art/no_art_*.dat`, and `stat`
(never open) of `library/cache/art/stamps.dat` and
`library/database/database_idx.tcd`. Every read has a size cap and opens for
reading only.

### Invariants every writer obeys

- **I1. One door.** Every byte written to a device and every file deleted from
  one goes through `DeviceFileIO` (the primitives) after `DeviceWritePolicy`
  has said yes. PodBox writers go through `DeviceFileExecutor`, which wraps
  both with the journal. No other code calls a file-system mutator on a device
  path.
- **I2. Allowlist, not blocklist.** The policy names what may be written
  where, by role. The denied trees are checked first and win over any
  configuration, including an empty music folder. Paths with `..`, absolute
  paths, and paths whose resolved real path leaves the volume are refused.
- **I3. Ownership before overwrite.** A PodBox writer replaces or deletes a
  file only when the journal holds the SHA-256 and size of what CrateDigger
  wrote there and the bytes on disk still match. Anything else is foreign:
  left alone and reported.
- **I4. Proof before cleanup.** A `._` file is deleted only with the full
  AppleDouble proof (below), re-checked at the moment of deletion, and after a
  copy has been kept on the Mac.
- **I5. Idempotent.** Identical bytes are never rewritten. Applying the same
  plan twice changes nothing the second time, dates included.
- **I6. Mounting only reads.** On mount CrateDigger probes. It writes nothing
  to the device and nothing to listening history. Extras (pictures,
  playlists, lyrics, known artists), play import and scrobbling also need the
  device matched by volume UUID.
- **I7. Same device at apply time.** A session records the volume UUID when it
  plans. The executor refuses to apply if the volume at that path now reports
  a different one or none.
- **I8. Interrupted is safe.** Files are written to `<name>.cdtmp` beside the
  target, flushed with `fsync`, then renamed over it. A failure removes the
  temp file. A crash can leave a `.cdtmp` (PodBox does not scan that
  extension) or a finished file with no journal record, which then reads as
  foreign. Both fail toward leaving things alone.
- **I9. Music never waits on garnish.** Extras run after the audio and the
  catalog patch. Their failure never fails or rolls back the transfer.
- **I10. Caps are hard.** No plan exceeds PodBox's `/Artwork` limits (2,048
  files, 48 KB of names, counted against 1,900 and 44 KB) or writes a path the
  player cannot open.
- **I11. Library history is guarded too.** An import records each log entry
  by its content, in the library's own folder, and starts with
  `guard !refuseWhileLibraryDisconnected()`. Unmatched and ambiguous entries
  are never recorded, so they are retried, not guessed.
- **I12. Inferences are gated.** A feature that rests on something not read
  from PodBox's source or seen on the device ships behind a per-device switch
  that stays off until its named manual check passes.

### How tests prove them without a device

- **`FakeIPod`** (test helper): builds a temp-dir replica of the device's
  layout from §4 and Appendix D (`.rockbox/` with config, `library/` with
  `.dat` and `.tcd` stand-ins, logs, `iPod_Control/`, `.rockbox_backup/`,
  `Music/<Category>/<Artist>/<YYYY Album>/` with tracks, covers and `._`
  twins, `/Playlists` with player-written files). `manifest()` returns path,
  size, SHA-256 and modification date for every file in the protected trees.
  **Every writer test ends with `assertPlayerStateUntouched()`**, which
  compares the manifest before and after. (I1, I2)
- **`DeviceWritePolicyTests`**: the allow and deny tables row by row, a
  property test over generated paths (traversal, case variants such as
  `.ROCKBOX`, trailing dots, symlinks out of the volume), empty music folder.
  (I2)
- **`DeviceWriteDoorLintTests`**: reads the Swift sources under
  `Services/DeviceFiles`, `Services/DeviceTransfer`, `Services/PodBox`,
  `FolderCoverArtWriter.swift` and `UI/ExternalDevices`, and fails if any of
  them calls `copyItem`, `moveItem`, `removeItem`, `trashItem`, `createFile`,
  `write(to:` or `FileHandle(forWritingTo` outside `DeviceFileIO.swift`,
  apart from an allowlist of lines with a stated reason (staging files on the
  Mac). Crude, and it is what stops the next writer walking round the door.
  (I1)
- **`DeviceFileExecutorTests`, `DeviceWriteJournalTests`**: identical bytes
  leave the date unchanged; a foreign file is refused; an owned file is
  replaced and backed up; an owned file edited since reads as foreign; a
  write that fails mid-way leaves no temp file; a rename with no journal
  record reads as foreign next time; a wrong volume UUID refuses the whole
  plan; a full disk refuses before writing. Failures are injected through a
  `FileManager` subclass. (I3, I5, I7, I8)
- **`AppleDoubleSweeperTests`**: each clause of the proof has a look-alike
  that must survive (real audio named `._x.m4a`, directory, symlink, 10-byte
  file, AppleSingle magic, wrong version, over the size limit, under
  `.rockbox/`), and a file changed between plan and apply is refused. (I4)
- **`DeviceSessionGateTests`**: the table of action by trigger by UUID match.
  (I6)
- **`PodBoxArtworkBudgetTests`, `FATNameTests`**: caps and path limits. (I10)
- **`DevicePlayImportTests`**: import twice equals import once; the same entry
  in a rotated copy and the live log counts once. (I11)
- **FAT sandbox** (`scripts/fat-sandbox.sh`): a 64 MB FAT32 disk image made
  with `hdiutil create -fs MS-DOS` and attached with `-mountpoint` inside the
  scratch directory and `-nobrowse`, never under `/Volumes`, so device
  detection cannot see it. `FATSandboxTests` skip when
  `CRATEDIGGER_FAT_SANDBOX` is unset and otherwise settle what is about
  macOS, not PodBox:
  - S1 which writes create a `._` twin (`copyItem`, data-only `copyfile`,
    ffmpeg output, `Data.write`);
  - S2 whether stripping attributes removes the twin;
  - S3 whether `Data.write(.atomic)` leaves `.TemporaryItems` at the root;
  - S4 that `rename` over an existing file works;
  - S5 what bytes an NFD name is stored as;
  - S6 how `?` and a trailing dot are handled;
  - S7 the executor's whole suite, run again on real FAT.
- **DEBUG dry run**: `CRATEDIGGER_PODBOX_DRYRUN=<volume path>` probes, prints
  every plan and exits. That code path constructs no executor.

Agents building this never write under `/Volumes/IPOD`. Everything on the real
iPod is one of the owner's checks below.

## Manual checks on the real iPod

Run by the owner, in order. Each is read-only or undone by removing the files
it names. M4 is the one exception: it is the first real cleanup, it deletes,
and it is undone from the Mac-side backup instead. A switch tied to a check
stays off until the owner has recorded "go".

| # | Opens | Kind | Do exactly this | Go | No-go |
|---|---|---|---|---|---|
| M1 | Phase 1 use | Read-only | Quit CrateDigger. Run the debug build with `CRATEDIGGER_PODBOX_DRYRUN=/Volumes/IPOD`. | Prints PodBox, layout 5, `ipodvideo`, build 2026-11-08, prefix `/<HDD0>`; a cleanup plan whose count is close to the `._` lines in `unreadable.txt`; "0 files would be written". | Anything else, or any file on the iPod with a new date. Stop; nothing else runs. |
| M2 | FAT names in the planner (phase 4) | Read-only | From the dry run's "names" section: the raw bytes of the `Gdańsk` folder, and every name under `Music` containing `? * " < > \|` or ending in a dot. | Names are stored NFC (or the list says which), and the list of odd names is known. | Names stored NFD: the picture file names in phase 2 are written to match, and M5 is repeated with a non-ASCII artist. |
| M3 | M4 | Read-only | In the dry run's cleanup plan, pick three listed files. `xxd -l 8 <file>` each. Read the plan's size table. | All three start `00 05 16 07 00 02 00 00`; every candidate is 128 KB or less; nothing listed lies under `.rockbox`, `.rockbox_backup`, `.backup` or `iPod_Control`. | Any miss. The cleanup stays disabled. |
| M4 | Whole-volume cleanup | Deletes proven twins; backed up first | In the device browser, Clean Up Mac Files on **one album folder**. Check the folder in Finder (Cmd-Shift-. shows hidden files). Eject; let the iPod rescan; reconnect. | The album plays; its `._` files are gone and nothing else is; `unreadable.txt` no longer lists that folder; the backups exist under the journal folder. Then run it for the whole volume. | Anything else missing: copy the files back from `backups/<session>/`, and the feature stays off. |
| M5 | Artist pictures (phase 2) | Removes one named file | Enable pictures for one artist whose name has `&`, an accent or a leading "The". Send. Eject. On the iPod: Settings ▸ Library ▸ Maintenance ▸ Update Art Cache, then open the artist. Note whether the picture was already there before running Update Art Cache. | The picture shows. No `._` file sits in `/Artwork/People`. | Remove `/Artwork/People/<Name>.jpg`, run Update Art Cache. The switch stays off. |
| M6 | Play import (phase 3) | Read-only on the iPod; scratch library | Point `CRATEDIGGER_CRATES_DIR` at a copy of the crates folder. Run Import Plays and stop at the preview. | The two "Zebra" entries (§ Appendix B) map to the library's Zebra, dated 2026-11-11 22:25 local, 29 s and 33 s of 292 s, neither counted as a play. | Any other track, time or count. Import stays off. |
| M7 | Playlists (phase 4) | Removes two named files | Write two three-track test playlists: `CD Test A.m3u8` with the `/<HDD0>` prefix, `CD Test B.m3u8` with paths starting `/Music`. Eject. Open both on the iPod. | A plays. (B playing only widens what could be supported later.) | A does not play: remove both files; playlists stay off. |
| M8 | Lyrics (phase 4) | Removes one named file | Send one track with a synced lyric. Play it and open the lyrics screen. | Lines show in time, accents correct. | Remove `<stem>.lrc8`. Lyrics stay off. |
| M9 | Ratings (phase 3b) | The player writes one file | On the iPod: rate three tracks, then Settings ▸ Library ▸ Maintenance ▸ Export Modifications. Connect. Copy `/.rockbox/database_changelog.txt` to the Mac (read-only for CrateDigger). | The file's first line is `## Changelog version 1` and it becomes the parser's fixture. | A different format: ratings wait for a parser written from the real file. |
| M10 | Recommending Re-embed on PodBox | Removes one named folder | Convert one album with art Re-embedded into `Music/_CrateDigger Test/`. Eject, rescan. | The album is in the library with a colour cover, and an `.m4b` in it keeps its chapters. | Tracks missing (read as video, `tagcache.c:3370`) or grey art: remove the folder; the embedded-only note says "set the iPod to Image Files" instead. |
| M11 | `/Artwork/Covers` (phase 5) | Removes one named file | For one album in a flat test profile, write `/Artwork/Covers/<Artist> - <Album>.jpg`. Update Art Cache. | That cover shows for that album only. | Remove the file. The feature is not built further. |
| M12 | Art-cache reminder wording | Read-only | After M5, note the date of `.rockbox/library/cache/art/stamps.dat` before and after the eject, before running Update Art Cache. | Either answer is fine: it decides whether the tip says "run" or "PodBox will". | none |
| M13 | `known_artists.txt` (phase 5) | Removes one named file | Turn Featured Artists on. Let CrateDigger write the file with one guest name. Restart the iPod. | The name stays whole in the Artists list. | Remove `/.rockbox/library/user/known_artists.txt`. The feature stays off. |

## Every PodBox feature, with a verdict

Verdicts: **Built** (phase), **Built behind** (a check above), **On the
iPod** (not possible from macOS; what CrateDigger says instead), **Shown, not
written** (design's call, D17: possible, deliberately left to the owner's own
editor, visible in the app).

| Feature (brief) | Verdict | Phase | Check | What CrateDigger does |
|---|---|---|---|---|
| Detect PodBox, model, build, library layout (§3) | Built | 1 | M1 | Probe at every mount; firmware line in Preferences ▸ Devices and on DEVICES. |
| Stock Rockbox / RockPod told apart (§3) | Built | 1 | M1 | Shown as "Rockbox"; gets covers, cleanup, eject guidance. |
| `._` files read as music, `unreadable.txt` (§4) | Built | 1 | M3, M4 | Stops making them; removes proven ones; says the list clears at the next scan. |
| Recommended `<Artist>/<Album>` structure (§2.1) | Built | exists; preset in 4 | none | Today's template already matches; the PodBox preset adds the year. |
| Year From Folder Name (§2.1) | Built | 4 | none | Preset writes `YYYY Album`; a note when a title like "1984" would be read as a year. |
| Disc folders `CD1`, `Disc 2` (§2.1) | Built | 4 | none | Templates make none; a note for a copied disc folder the player will not recognise. |
| Scan root, `database scan paths` (§2.1) | Built (read) | 2 | none | Readiness note when the music folder is outside the scanned paths. |
| `database.ignore` / `database.unignore` (§2.1) | Built | 5 | none | Hide / Show Folder on the iPod, an explicit action on a device folder. |
| `iPod_Control/Games_RO` skipped (§2.1) | On the iPod | none | none | Nothing to do; CrateDigger never enters `iPod_Control`. |
| Album cover as `cover.jpg` (§2.2) | Built | exists | none | Unchanged. `cover` is tried before `folder`, so one file. |
| Cover rules: baseline JPEG, under 512 KB for cars (§2.2) | Built | 2 | none | Two tests on `FolderCoverArtWriter`; quality steps down if over. |
| Cover found from a disc folder's parent (§2.2) | Built | exists | none | Covers are written per folder that holds tracks. |
| Embedded covers, source order setting (§2.2) | Built behind | 2 (note) | M10 | Reads `art cache album source`; notes when the iPod uses embedded only. |
| `/Artwork/Covers` (§2.2) | Built behind | 5 | M11 | Folderless layouts only (D14). |
| Image beside a single-file book (§2.2) | Built | 5 | none | Written as `<stem>.jpg` when spoken-word handling is on. |
| Art keyed per album (§2.2) | On the iPod | none | none | Nothing to prepare. |
| Thumbnails, Update Art Cache (§2.2, §2.11) | On the iPod | 1 (tip) | M12 | "Next on the iPod" tip after any art change; cleared when the player has done it. |
| Artist pictures, `/Artwork/People` (§2.3) | Built behind | 2 | M5 | Default location. |
| Artist pictures in artist folders (§2.3) | Built behind | 2 | M5 | Option and overflow, only where no image is there or ours is. |
| Author pictures (§2.3) | Built behind | 2 | M5 | Same mechanism: album artist of a book is the author. |
| Name matching rules (§2.3, Appendix A) | Built | 2 | M5 | Ported and proven against vectors from PodBox's own C. |
| `/Artwork` limits (§2.3) | Built | 2 | none | Hard budget; the rest reported or sent to artist folders. |
| Artist art on/off settings (§2.3) | Built (read) | 2 | none | Readiness note when `database artist art` is off. |
| Tags read by the database (§2.4) | Built | exists | none | Transfers carry them; convert keeps them. |
| Album artist fallback, compilations (§2.4) | Built | 4 | none | Note in the review; optional fill on converted copies (D15). |
| No sort tags (§2.4) | On the iPod | 5 (note) | none | One-time note: "turn on Sort ▸ Ignore The/A/An". |
| 500-character tag limit (§2.4) | Built | 5 (note) | none | Informational note. |
| Audiobook shelf (§2.4) | Built | 5 | none | Classifier, notes (missing author, retag loses the place), optional routing. |
| Podcast shelf and episode order (§2.4) | Built | 5 | none | Classifier, near-miss genre note, optional routing. |
| Chapters (§2.4) | Built | exists | M10 | Copy keeps them; convert maps them. |
| Featured artists, `known_artists.txt` (§2.4) | Built behind | 5 | M13 | Managed block, only when the setting is on and the owner says yes. |
| Trim Titles, `trim.txt` (§2.4, §2.10) | Shown, not written | 5 | none | Listed under PodBox Files with Reveal in Finder. |
| Audio formats (§2.5) | Built | exists | none | Everything CrateDigger writes plays. Note for lossless above 48 kHz on an iPod Video. |
| Files with video skipped (§2.5) | Built | 5 (note) | M10 | Note at review time. |
| Synced lyrics sidecar (§2.6) | Built behind | 4 | M8 | `<stem>.lrc8` from a sidecar or tag text. |
| Embedded `SYLT` lyrics (§2.6) | Built | 4 | M8 | Read from the source and written as the sidecar; not embedded in output. |
| Unsynced lyrics (§2.6) | On the iPod | 4 (count) | none | PodBox does not show them; the summary counts them. |
| Lyrics lookup | Built | 5 | M8 | LRCLIB, off by default (D11). |
| Playlists to `/Playlists` (§2.7) | Built behind | 4 | M7 | Ticked playlists and crates, written in the player's own form. |
| The player's own playlists (§2.7) | Built | 4 | none | Listed under the device; Import to Library. Read-only on the device. |
| Moods, Journeys, playlist engine (§2.7) | On the iPod | 1 (tip) | none | Tip after new music: "Update Sound Analysis" when the engine is on. |
| Live queue `.playlist_control` (§2.7) | On the iPod | none | none | Read only, to learn the path prefix. |
| Database, Scan on Eject (§2.8) | On the iPod | 1 (tip) | none | "Eject. PodBox adds the new music when it restarts." |
| Play counts kept across rebuilds, `plays.dat` (§2.8) | On the iPod | none | none | Never touched. |
| `playback.log` (§2.9) | Built behind | 3 | M6 | Imported into listening history. |
| `/.scrobbler.log` (§2.9) | Built | 3 | fixture only | Imported when present. Not on this iPod, so not checked on it. |
| Last.fm (§2.9) | Built behind | 3b | M6 first | Opt-in submission of imported plays (D8). |
| `database_changelog.txt`, ratings in (§2.9) | Built behind | 3b | M9 | Fill unrated tracks. |
| `database_changelog.txt`, ratings and counts out (§2.9) | On the iPod | none | none | Not written: the round trip is untested and feeds the player's database. Ratings are made on the iPod. |
| `player_name.txt` (§2.9) | Built (read) | 1 | none | Shown as the player's name. Not written (D17). |
| Private `.dat` files (§2.9) | On the iPod | none | none | Never opened, beyond two 28-byte headers. |
| `tagnavi_custom.config`, `tagnavi_user.config` (§2.10) | Shown, not written | 5 | none | PodBox Files: present or not, first line valid or not, Reveal in Finder. |
| `langs/overrides.cfg`, theme `.usercfg` (§2.10) | Shown, not written | 5 | none | PodBox Files. |
| `config.cfg` (§2.10) | On the iPod | 1 (read) | none | Read for settings. The player rewrites it, so notes name the menu path instead. |
| Art cache, sound analysis, database prebuilt (§2.11) | On the iPod | 1 (tip) | none | Needs the player or PodBox's Windows tools. Tips say which menu. |
| Firmware install and update, themes, voices (§1) | On the iPod | 5 | none | Firmware line shows the build date and links to PodBox's releases page. CrateDigger never unzips onto the device. |
| Ebooks, `Books/` (§2.1) | Shown, not written | 1 | none | Cleanup covers their `._` twins; filing them is done in Finder. |
| Layout newer than 5 (Appendix C) | Built | 1 | none | Message; file features that do not depend on the layout keep working; read-back tries the known paths read-only. |

## What gets built

Folder conventions: device-safety types in
`Sources/CrateDiggerCore/Services/DeviceFiles/`, PodBox logic in
`Sources/CrateDiggerCore/Services/PodBox/`, models in `Models/`, wiring in
`Sources/CrateDiggerApp/UI/ExternalDevices/LibraryViewModel+PodBox.swift`
(a 32nd extension; CLAUDE.md's list is updated). Each Core type has an XCTest
class named `<Type>Tests`. Fixtures are literals in the test sources, copied
from the brief's appendices; nothing is read from the iPod to build tests.

### Phase 1: PodBox is recognised, and the iPod stops reading junk

Scope: detection and firmware readout, the write door, AppleDouble
prevention and cleanup, eject guidance. No network, no new library data, no
change to any saved profile.

It is built in two halves so tonight's work cannot collide with the
duplicates work in progress.

**1a. Core, new files only.**

```swift
// Models/DeviceFirmware.swift
public enum RockboxFlavour: String, Codable, Sendable { case podBox, stockRockbox, unknownRockbox }

public struct RockboxBuildInfo: Equatable, Codable, Sendable {
    public let target: String?            // "ipodvideo", "ipod6g"
    public let version: String?           // raw, "-261108"
    public let gitHash: String?           // nil when empty
    public let buildDate: DateComponents? // from a trailing YYMMDD
    public var modelName: String          // "iPod Video", "iPod Classic", "iPod (<target>)"
}

public struct PodBoxConfig: Equatable, Sendable {
    public init(defaultConfig: String?, config: String?)   // defaults table <- default-config.cfg <- config.cfg
    public func value(_ key: String) -> String?
    public var playLogMode: PlayLogMode                    // .off, .on, .lastFM; default .on
    public var playlistDirectory: String                   // default "Playlists"
    public var scanPaths: [String]                         // default ["/"]
    public var yearFromFolder: Bool, artistArt: Bool, featuredArtists: Bool
}

public struct DeviceFirmware: Equatable, Sendable {
    public let flavour: RockboxFlavour
    public let layout: Int?                 // format.dat u16; nil = never booted, or not PodBox
    public let build: RockboxBuildInfo?
    public let config: PodBoxConfig
    public let playerPathPrefix: String?    // "/<HDD0>", learned from the player's own files
    public let playerName: String?
    public let unreadableAppleDoubleCount: Int   // lines of unreadable.txt naming a "._" file
    public var summaryLine: String          // "PodBox · iPod Video · build 8 Nov 2026 · library layout 5"
}

public struct DeviceCapabilities: OptionSet, Sendable {
    public static let appleDoubleSweep, coverSidecar, centralPeopleArtwork,
                      playlistCatalog, playbackLogImport, scrobblerLogImport, lyricsSidecar
    public init(firmware: DeviceFirmware?, fileSystem: String?)   // "msdos", "exfat", ...
}
public static let knownLayout = 5
```

Capability rules (one test per row):

| Condition | Capabilities |
|---|---|
| Volume is `msdos` or `exfat` | `appleDoubleSweep` |
| `.rockbox` exists | + `coverSidecar`; `scrobblerLogImport` when `/.scrobbler.log` exists |
| PodBox, layout 5 | + `centralPeopleArtwork`, `lyricsSidecar`, `playbackLogImport`; `playlistCatalog` when `playerPathPrefix` is known and the playlist folder is not in a denied tree |
| PodBox, never booted (layout nil) | file features only; no read-back; message "Start the iPod once so PodBox can finish setting up" |
| PodBox, layout above 5 | file features; read-back tries layout 5 paths read-only; message "This iPod runs a newer PodBox library layout (N) than CrateDigger knows (5)" |

```swift
// Services/PodBox/DeviceFirmwareProbe.swift
public enum DeviceFirmwareProbe {
    /// Opens nothing for writing and holds no handle past its return. nil = no .rockbox.
    public static func probe(volumeRoot: URL, fileManager: FileManager = .default) -> DeviceFirmware?
    public static func layoutVersion(formatDat: Data) -> Int?          // "LYOT" then LE u16; checksum NOT verified
    public static func buildInfo(rockboxInfo: String) -> RockboxBuildInfo
    public static func configValues(_ text: String) -> [String: String] // split on the first ": "; "#" and blanks skipped
    public static func playerPathPrefix(fromPlayerLines: [String]) -> String?  // ^/<[A-Z]+[0-9]+>
    public static func flavour(layout: Int?, rockboxEntries: Set<String>) -> RockboxFlavour
    public static func appleDoubleCount(unreadableText: String) -> Int
}
```

Flavour: `LYOT` present is PodBox. Else all of `default-config.cfg`,
`trim.config`, `docs/settings-help.txt` and no `rocks/` is PodBox not yet
booted. Else `rocks/` present is stock. Else unknown. Read caps: 28 bytes,
16 KB, 64 KB per config, 256 KB for `unreadable.txt`, the first 64 KB of one
player playlist and of `playback.log`. `config.cfg.new` is ignored. The
device's real header carries `FF FF FF FF` as its checksum, which is not the
CRC of an empty tail, so a strict reader would reject the real iPod.

```swift
// Services/DeviceFiles/DeviceWritePolicy.swift
public enum DeviceFileRole: Sendable {
    case audio, cover, temp                         // phase 1
    case artistPicture, artistFolderPicture         // phase 2
    case lyrics, playlist                           // phase 4
    case centralCover, ignoreMarker, knownArtists   // phase 5
}
public enum DeviceDeleteReason: Sendable { case appleDouble, ownedByCrateDigger, userReplace, staleTemp }
public struct DeviceWritePolicy: Sendable {
    public init(musicSubpath: String, playlistDirectory: String = "Playlists",
                audioExtensions: Set<String> = LibraryScanService.defaultSupportedExtensions,
                enabledRoles: Set<DeviceFileRole> = [.audio, .cover, .temp])
    public func checkWrite(_ relativePath: String, role: DeviceFileRole) throws    // DeviceWritePolicyError.forbidden(reason)
    public func checkDelete(_ relativePath: String, reason: DeviceDeleteReason) throws
    public static let deniedTrees: [String]   // .rockbox, .rockbox_backup, .backup, iPod_Control, .Trashes, .Spotlight-V100, .fseventsd
}
```

| Role | Where | Name |
|---|---|---|
| `audio` | under the music folder; the volume root only when the music folder is empty | extension in the scanner's supported set |
| `cover` | a folder `audio` may be written to | `cover.jpg` |
| `temp` | beside a target the same call may write | `<target name>.cdtmp` |
| `artistPicture` | `Artwork/People/`, top level | `*.jpg` |
| `artistFolderPicture` | a folder under the music folder | `folder.jpg` |
| `lyrics` | beside an audio file | `*.lrc8` |
| `playlist` | the playlist folder, top level | `*.m3u8` |
| `centralCover` | `Artwork/Covers/`, top level | `*.jpg` |
| `ignoreMarker` | a folder under the music folder | `database.ignore`, `database.unignore` |
| `knownArtists` | exactly `.rockbox/library/user/known_artists.txt` | the one exception to the denied trees |

Deletes: `userReplace` only for an audio file under the music folder (the
duplicates plan's deletions); `appleDouble` anywhere outside the denied trees;
`ownedByCrateDigger` and `staleTemp` wherever the matching role may write. A
role not in `enabledRoles` is refused, which is how a phase or a manual check
gates a writer in one place. Comparison is NFC and case-insensitive, so
`.ROCKBOX/x` is denied too.

```swift
// Services/DeviceFiles/DeviceFileIO.swift   (the only file that mutates a device path)
public enum DeviceFileIO {
    /// copyfile(COPYFILE_DATA) to "<dest>.cdtmp", fsync, rename, restore the source's
    /// modification date, strip attributes, remove a proven "._" twin.
    public static func copyDataOnly(from source: URL, to destination: URL, fileManager: FileManager = .default) throws
    /// Same-folder temp, fsync, rename. Never Data.write(.atomic).
    public static func writeAtomically(_ data: Data, to destination: URL, fileManager: FileManager = .default) throws
    public static func stripExtendedAttributes(at url: URL)            // listxattr / removexattr, XATTR_NOFOLLOW
    public static func removeProvenTwin(of url: URL) -> Bool
    public static func remove(_ url: URL) throws                       // unlink; a missing file is not an error
    public static func createDirectory(_ url: URL) throws
}

// Services/DeviceFiles/DeviceWriteJournal.swift
public struct DeviceFileRecord: Codable, Hashable, Sendable {
    public enum Kind: String, Codable { case created, replaced, deleted, tempIntent }
    public let relativeKey: String      // NFC, case-folded
    public let relativePath: String     // as written
    public let kind: Kind
    public let role: String
    public let size: Int64?
    public let sha256: String?          // nil for audio (D18)
    public let backupFile: String?      // replaced or deleted files: a copy kept on the Mac
    public let libraryPath: String?     // audio only, from phase 3: a tie-break hint, never proof
    public let volumeUUID: String?
    public let sessionID: UUID
    public let date: Date
}
public final class DeviceWriteJournal {
    /// <AppSupport>/CrateDigger/DeviceJournal/<profileID>/journal.jsonl + backups/<sessionID>/...
    public init(profileID: UUID, directory: URL? = nil, fileManager: FileManager = .default)
    public func ownedRecord(forKey key: String) -> DeviceFileRecord?   // latest record, if our last act there was a write
    public func append(_ records: [DeviceFileRecord]) throws           // appended and flushed
    public func backUp(_ data: Data, relativePath: String, sessionID: UUID) throws -> String
    public func records(sessionID: UUID) -> [DeviceFileRecord]
}

// Services/DeviceFiles/DeviceFileExecutor.swift
public enum DeviceFileContents: Sendable { case data(Data), file(URL) }
public enum DeviceFileOperation: Sendable {
    case write(relativePath: String, role: DeviceFileRole, contents: DeviceFileContents, replacesForeign: Bool = false)
    case delete(relativePath: String, reason: DeviceDeleteReason)
}
public enum DeviceFileOutcome: Equatable, Sendable {
    case written, unchanged, refusedForeign, refusedPolicy(String), refusedWrongVolume, refusedNoSpace,
         deleted, alreadyGone, refusedNotAppleDouble, failed(String)
}
public struct DeviceFileExecutor {
    public init(volumeRoot: URL, expectedVolumeUUID: String?, policy: DeviceWritePolicy,
                journal: DeviceWriteJournal, fileManager: FileManager = .default)
    public func apply(_ ops: [DeviceFileOperation], sessionID: UUID,
                      progress: (Int, Int) -> Void = { _, _ in }) -> [DeviceFileOutcome]
}
```

`apply`, for a write: (1) volume UUID still matches, else every op is
`refusedWrongVolume`; (2) policy; (3) free space at least the size plus 8 MB;
(4) target exists: identical bytes is `unchanged`; journal hash and size match
the bytes on disk means back up, then replace; otherwise `refusedForeign`
unless `replacesForeign` (used only by `cover`, D19, which still backs up);
(5) temp, `fsync`, rename; (6) strip attributes, remove a proven twin;
(7) append the journal record. For a delete: `ownedByCrateDigger` needs the
hash to match now, with a backup first; `appleDouble` re-runs the proof and
backs up first; a file already gone is `alreadyGone`. Before a session's
first write the journal gets one `tempIntent` record per planned `.cdtmp`
path; a leftover `.cdtmp` from a crash is removed (`staleTemp`) only when
such a record names it.

```swift
// Services/DeviceFiles/AppleDoubleSweeper.swift
public struct AppleDoubleSweepPlan: Sendable {
    public let candidates: [String]          // relative paths, proven
    public let leftAlone: [String: Int]      // reason -> count: "not media", "too large", "not AppleDouble"
    public let sizeHistogram: [Int: Int]
    public var operations: [DeviceFileOperation]
}
public struct AppleDoubleSweeper {
    public static let maximumSize = 128 * 1024
    public static func isAppleDouble(header: Data) -> Bool   // 00 05 16 07 00 02 00 00
    /// Walks, reads 8 bytes per "._" file, deletes nothing. scope nil = whole volume.
    public func plan(volumeRoot: URL, scope: [URL]?, mediaExtensions: Set<String>) -> AppleDoubleSweepPlan
}
```

The proof, all of: name starts with `._` and is longer than two characters;
`lstat` says regular file; size from 26 bytes to 128 KB; bytes 0 to 3 are
`00 05 16 07` and 4 to 7 are `00 02 00 00`; not under a denied tree; the name
after `._` has a media extension (D21). No audio, image or playlist format
starts with those eight bytes. An orphan twin (its file already deleted by a
Replace) qualifies: the bytes are the proof.

```swift
// Services/DeviceFiles/DeviceSessionGate.swift
public enum DeviceSessionTrigger { case mount, userAction }
public enum DeviceAction { case probe, transferAudio, sweep, writeExtras, importPlays, scrobble }
public enum DeviceSessionGate {
    public static func allows(_ action: DeviceAction, trigger: DeviceSessionTrigger, matchedByUUID: Bool) -> Bool
}
```

`mount` allows `probe` only. `userAction` allows `transferAudio` and `sweep`
for any matched profile (as today), and the other three only with a UUID
match.

```swift
// Services/PodBox/PodBoxNextSteps.swift
public struct DeviceWriteChanges: OptionSet, Sendable { audio, covers, pictures, lyrics, playlists, cleanup, knownArtists }
public enum PodBoxNextSteps {
    public static func after(_ changes: DeviceWriteChanges, firmware: DeviceFirmware?) -> [String]
    /// The player has done the step when the file it rewrites is newer than our write (1 minute tolerance).
    public static func isDone(lastWrite: Date?, playerFileModified: Date?) -> Bool
}
```

Lines, PodBox only: audio or playlists changed: "Eject the iPod. PodBox adds
the new music when it restarts. If it does not appear: Settings ▸ Library ▸
Maintenance ▸ Update Database." Covers or pictures changed: "Then Settings ▸
Library ▸ Maintenance ▸ Update Art Cache." Cleanup: "The unreadable-files list
clears at the next scan." Playlist engine on and audio changed: "Update Sound
Analysis measures the new tracks." Lyrics only: nothing. Other Rockbox: "Eject
the iPod before unplugging."

Tests (1a): `DeviceFirmwareProbeTests` (the device's 28 bytes give layout 5;
short, empty and wrong-magic files give nil; checksum ignored; the brief's
`rockbox-info.txt` gives iPod Video and 2026-11-08; stock version forms; CRLF;
config layering; prefix from a playlist line, a log line and a `P:` line; the
four flavours from temp trees), `DeviceCapabilitiesTests`,
`DeviceWritePolicyTests`, `DeviceFileIOTests`, `DeviceWriteJournalTests`,
`DeviceFileExecutorTests`, `AppleDoubleSweeperTests`, `DeviceSessionGateTests`,
`PodBoxNextStepsTests`, `DeviceWriteDoorLintTests`, `FATSandboxTests`, and the
`FakeIPod` helper. Plus `scripts/fat-sandbox.sh` (`up`, `down`).

**1b. Wiring, after the duplicates plan's Task 5, or at today's sites if it
has not landed.**

- `LibraryViewModel+PodBox.swift`:
  - `@Published var deviceFirmware: [MountedDevice.ID: DeviceFirmware]`,
    filled by a detached probe where `mountedDevices` changes
    (`LibraryViewModel.swift` near line 2344), cleared on unmount.
  - `func devicePolicy(for profile:) -> DeviceWritePolicy`.
  - `func finishDeviceSession(device:profile:written:[URL] deleted:[URL] changes:) async -> [String]`,
    called by every device write path after the catalog patch: strip
    attributes on what was written, sweep the folders touched, save the
    journal, return the next-step lines. One `transfer` busy job spans it.
  - `func cleanUpMacFiles(device:scope:)`: plan (stamped as a `scan` job),
    confirm with the counts ("1,731 Mac metadata files found. They are not
    music. A copy is kept on this Mac. Remove them?"), apply (stamped as
    `transfer`), report, offer Eject.
  - `func ejectDevice(_:)` via `NSWorkspace.unmountAndEjectDevice(at:)`, only
    after the session's journal is saved.
- Copy sites: the three `copyItem` calls named above become
  `policy.checkWrite` then `DeviceFileIO.copyDataOnly`. Convert runs that let
  ffmpeg write onto the device check every planned destination with the
  policy before starting. The duplicates plan's deletions go through
  `policy.checkDelete(_, .userReplace)` and `DeviceFileIO.remove`.
- `FolderCoverArtWriter.write` takes a writer closure defaulting to
  `DeviceFileIO.writeAtomically`, and skips a cover whose bytes are already
  there.
- UI:
  - Preferences ▸ Devices, Device section: a read-only **Firmware** row
    (`summaryLine`, or "Rockbox", or "PodBox, not started yet"), shown while
    the device is mounted; a **Clean Up Mac Files…** button with the count
    from `unreadableAppleDoubleCount` when it is not zero.
  - DEVICES screen: the Kind cell reads "PODBOX" with the model as its sub.
  - Device row context menu and device folder context menu: Clean Up Mac
    Files…, Eject.
  - Transfer summary: the next-step lines last, and an Eject action.
  - DEBUG `CRATEDIGGER_PODBOX_DRYRUN`.
- CLAUDE.md: a "PodBox and the device write door" section (the invariants in
  short; "a new device writer goes through `DeviceFileIO` after the policy and
  ends with `finishDeviceSession`"), and CHANGELOG lines.

Owner's checks before real use: M1, M2, M3, M4.

### Phase 2: artist pictures

```swift
// Services/DeviceFiles/FATName.swift
public enum FATName {
    /// NFC; ? * removed; " -> '; < > | -> -; control characters -> _; trailing dots and spaces trimmed;
    /// CON PRN AUX NUL COM1-9 LPT1-9 get a trailing "_"; at most 255 UTF-16 units, extension kept.
    public static func component(_ raw: String, extension ext: String?) -> String?
    public static func fitsPlayerPath(_ relativePath: String, prefix: String?) -> Bool   // 252 UTF-8 bytes with the prefix
    public static func collides(_ a: String, _ b: String) -> Bool
}

// Services/PodBox/PodBoxArtName.swift   (a literal port of the brief's Appendix A)
public enum PodBoxArtName {
    public static func folded(_ name: String) -> String          // the kept code points, as text
    public static func key(_ name: String) -> UInt32             // art_name_hash
    public static func altKey(_ name: String) -> UInt32          // exactly one comma, else 0
    public static func matches(_ a: String, _ b: String) -> Bool // any non-zero key of one equals any of the other
    public static func fileStem(for name: String) -> String?     // FATName form when its key still matches, else folded(name); nil when the key is 0
}
```

Port notes, each a test: the hash runs over whole code points in `UInt32`
with wrapping multiply; the `"the "` and `", the"` rules are byte tests done
before decoding; the Latin table decides Ø (the brief's prose and its table
disagree; the table is from source); non-Latin capitals are not lowercased;
this is not `DeviceAlbumIdentity.fold` and must never be swapped for it.
**Differential vectors**: `scripts/podbox-artname-vectors.sh` (a dev script,
not part of the build) fetches `art_name.c` at commit `f0850c4`, compiles it
with a stub decoder and prints name, key and alt key for every artist name in
the library plus an adversarial list. Only the output is committed, as a JSON
fixture. No GPL source enters the repo.

```swift
// Services/PodBox/PodBoxArtLookup.swift
public struct DeviceArtTree: Sendable {          // built from one listing of the device
    public init(peopleFiles: [String], coverFiles: [String], folderImages: [String: [String]],
                foldersWithAudio: Set<String>, artistsByFolder: [String: Set<String>])
}
public enum PodBoxArtLookup {
    /// What the player would find for this person, by its three steps (§2.3). nil = no picture.
    public static func artistPicture(for name: String, albumFolders: [String], tree: DeviceArtTree) -> String?
}

// Services/PodBox/PodBoxArtworkBudget.swift
public struct PodBoxArtworkBudget: Sendable {
    public static let files = 1_900, nameBytes = 44 * 1024, people = 8_192
    public func room(existingNames: [String]) -> (files: Int, nameBytes: Int)
}

// Services/PodBox/ArtistPictureStore.swift     (library.cdartists in the crates index folder; in LibraryIndexFiles)
public struct ArtistPictureRecord: Codable, Sendable {
    public var foldedKey: String, displayName: String
    public var outcome: Outcome                  // .found, .notFound, .uncertain, .rejected
    public var source: ArtistPictureSourceID     // .userFile, .libraryFolder, .deezer, .commons, .fanartTV, .discogs, .theAudioDB
    public var sourceID: String?, artworkHash: String?, preparedHash: String?
    public var pickedByUser: Bool, checkedAt: Date
}
public struct ArtistPictureStore {
    public init(indexDirectory: URL, fileManager: FileManager = .default)
    public func record(forFoldedKey key: String) -> ArtistPictureRecord?
    public mutating func set(_ record: ArtistPictureRecord)
    public func save() throws
}

// Services/PodBox/ArtistPictureSources.swift
public struct ArtistPictureCandidate: Sendable { name, sourceID, imageURL, albumTitles: [String], source }
public protocol ArtistPictureSource: Sendable {
    func candidates(for name: String) async throws -> [ArtistPictureCandidate]
}
public enum DeezerArtistParser { public static func parse(_ data: Data) throws -> [ArtistPictureCandidate] }
public enum ArtistPictureMatcher {
    public static func verdict(_ c: ArtistPictureCandidate, name: String, deviceAlbumTitles: [String]) -> ArtistPictureVerdict  // .confident, .uncertain, .noMatch
}
public enum ArtistPictureImage {
    public static func cropRect(for size: CGSize) -> CGRect      // square; portraits biased to the top third
    public static func prepare(_ data: Data) -> Data?            // 400 px, sRGB, baseline JPEG, no metadata, at most 100 KB; nil under 300 px or wider than 2:1
}

// Services/PodBox/ArtistPicturePlanner.swift
public struct ArtistPicturePlan: Sendable {
    public let operations: [DeviceFileOperation]
    public let alreadyHasPicture: [String], notFound: [String], uncertain: [String],
               overBudget: [String], unnameable: [String]
}
public enum ArtistPicturePlanner {
    public static func plan(catalog: [LoadedTrack], tree: DeviceArtTree,
                            prepared: [String: Data],            // folded key -> the exact bytes to write
                            destination: ArtistPictureDestination,   // .artworkFolder, .artistFolders, .off
                            journal: DeviceWriteJournal) -> ArtistPicturePlan
}

// Services/PodBox/PodBoxAdvisor.swift
public struct PodBoxNote: Identifiable, Sendable { kind, text, albums: [String], menuPath: String? }
public enum PodBoxAdvisor {
    public static func deviceNotes(catalog: [LoadedTrack], firmware: DeviceFirmware, musicSubpath: String) -> [PodBoxNote]
}

// Models/ExternalDeviceProfile.swift
public struct PodBoxPreferences: Codable, Hashable, Sendable {
    public var sweepsAppleDouble = true
    public var artistPictures: ArtistPictureDestination = .off        // .artworkFolder for new profiles once M5 has passed
    public var findsArtistPicturesAutomatically = true
    public var lastSeenFirmware: String?                              // display only
    public var passedChecks: Set<String> = []                         // "M5", "M6", ...
}
public var podBox: PodBoxPreferences?     // decodeIfPresent; nil = defaults
```

Rules:

- **Names** come from the device catalog's tags, which is what PodBox reads:
  each album's album artist, else its artist, one per `PodBoxArtName.key`.
  Skipped: key 0, "Various Artists", "Unknown Artist", `<UNTAGGED>`.
- **Never shadow the owner.** A person the player already finds a picture for
  (by `PodBoxArtLookup`, ignoring images in folders that directly hold audio,
  which are album covers) gets nothing unless the found file is ours by hash.
- **Source order**: the owner's pick; an `artist.jpg` or `folder.jpg` in a
  library folder named after the artist and holding only their albums; Deezer
  (`search/artist`, then `artist/<id>/albums` for D2; serial, 200 ms apart;
  the empty-hash placeholder rejected; quota error code 4 backs off 1, 2, 4 s
  then stops the run). Phase 2b: MusicBrainz artist search through the
  existing 1 request per second gate, its `wikidata` relation, property P18,
  then Commons at 800 px, as a background job outside any transfer, results
  kept in the store. "Not found" is retried after 30 days or on demand.
- **Requests carry the artist name and nothing about the user**, with a
  generic client name.
- **When**: after a transfer's catalog patch, inside `finishDeviceSession`,
  bounded (8 s per artist, 2 minutes per session, the rest wait), accepting
  only confident matches; or from the **Artist Pictures sheet** (device
  context menu, Preferences ▸ Devices): a grid of the device's artists with
  current picture and source, "Check" on uncertain ones, and per artist
  Accept, other candidates, Choose File…, No Picture (remembered). Apply
  writes to the store and, if mounted and UUID matched, to the device. The
  sheet presents from `LibraryPresentations`; its look is approved by the
  owner from a real capture. DEBUG `CRATEDIGGER_ARTIST_PICTURES=1` opens it
  with made-up rows.
- **Removal**: "Remove artist pictures CrateDigger added" is a plan of
  journal-owned deletes.
- **Readiness** (`deviceNotes`, read-only): Mac files present; artist art
  switched off on the iPod; music folder outside the scanned paths; play log
  off; names with key 0; paths over the player's limit; compilations with no
  album artist. Shown as captions in Preferences ▸ Devices.
- **Cover guarantees**: tests that `FolderCoverArtWriter` output is baseline
  and under 512 KB.
- **Reminder**: the DEVICES ticker reads "NEXT ON IPOD · UPDATE ART CACHE"
  until `PodBoxNextSteps.isDone` says the player has done it (`stat` of
  `stamps.dat`).

Tests: `FATNameTests`, `PodBoxArtNameTests` (the brief's worked examples,
the vectors, the fixed-point and `fileStem` properties), `PodBoxArtLookupTests`
(owner's People file blocks, by alt key too; artist-folder image blocks; an
album `cover.jpg` does not; a category folder with many artists is ignored;
the self-titled album), `PodBoxArtworkBudgetTests`, `ArtistPicturePlannerTests`
(replanning with everything present gives zero operations),
`DeezerArtistParserTests` and a Wikidata parser test on saved JSON,
`ArtistPictureMatcherTests`, `ArtistPictureImageTests`,
`ArtistPictureStoreTests`, `PodBoxAdvisorTests`, a decode test for a profile
saved without `podBox`.

Owner's check: M5 (and M12). `artistPictures` stays `.off` until it passes.

### Phase 3: what the iPod played

```swift
// Services/PodBox/PlaybackLogParser.swift
public struct PlayLogEntry: Hashable, Sendable { text: String, timestamp: Int, elapsedMS: Int, lengthMS: Int, path: String }
public enum PlaybackLogParser {
    /// "#" lines are comments. Split on the first three colons only. An unterminated last line is ignored.
    public static func entries(in data: Data) -> (entries: [PlayLogEntry], malformed: Int)
    public static func orderedLogNames(_ names: [String]) -> [String]   // playback_0001.log ... then playback.log
}
public enum ScrobblerLogParser {   // Audioscrobbler 1.1; #TZ/UTC versus #TZ/UNKNOWN; 7 or 8 fields
    public static func entries(in data: Data) -> (entries: [ScrobblerLogEntry], utc: Bool)
}
public enum PlayerClock {
    /// The player writes local wall time as an epoch. nil before 2007 or more than 36 h ahead of now (clock unset).
    public static func date(localEpoch: Int, timeZone: TimeZone, now: Date) -> Date?
}

// Services/PodBox/DevicePlayResolver.swift
public enum DevicePlayMatch: Sendable { case matched(LoadedTrack), unmatched, ambiguous }
public struct DevicePlayResolver {
    public init(catalog: [LoadedTrack], library: [LoadedTrack], mountRoot: URL, pathPrefix: String?,
                hints: [String: String] = [:])          // device relative key -> library path, from the journal
    public func match(devicePath: String, lengthMS: Int) -> DevicePlayMatch
}

// Services/PodBox/DevicePlayImport.swift
public struct DevicePlayImportPlan: Sendable {
    public struct Item: Sendable { key: String, libraryPath: String, date: Date?, isPlay: Bool }
    public let items: [Item]
    public let unmatched: [PlayLogEntry], ambiguous: [PlayLogEntry]
    public let alreadyImported: Int, malformed: Int
}
public enum DevicePlayImporter {
    public static func plan(entries: [PlayLogEntry], resolver: DevicePlayResolver, ledger: DevicePlayLedger,
                            volumeUUID: String, timeZone: TimeZone, now: Date) -> DevicePlayImportPlan
}
public struct DevicePlayLedger {        // library.cddeviceplays in the crates index folder; in LibraryIndexFiles
    public init(indexDirectory: URL, fileManager: FileManager = .default)
    public func contains(_ key: String, volumeUUID: String) -> Bool
    public mutating func record(batch: DevicePlayBatch, volumeUUID: String)   // keeps the last 5 batches for undo
    public mutating func removeLastBatch(volumeUUID: String) -> DevicePlayBatch?
    public mutating func markScrobbled(_ keys: [String], volumeUUID: String)
    public func save() throws
}
// Models/ListeningStats.swift
public mutating func recordPlay(at date: Date, calendar: Calendar = .current)   // lastPlayed = max(existing, date)
public mutating func recordUndatedPlay()                                        // playCount only
public mutating func removeImportedPlay(at date: Date?, restoringLastPlayed: Date?)
// Services/LastFMScrobbler.swift
public func scrobbleBatch(_ plays: [ScrobblePlay], sessionKey: String) async throws -> (accepted: Int, ignored: Int)   // 50 per request
public enum DeviceScrobblePlanner {
    public static func batches(_ plays: [ScrobblePlay], alreadySent: Set<String>, now: Date) -> (batches: [[ScrobblePlay]], tooOld: Int)
}
// Services/PodBox/RockboxChangelog.swift        (3b, written from the M9 fixture)
public enum RockboxChangelogParser { public static func parse(_ text: String) -> [ChangelogRecord] }
public enum DeviceRatingMerge {
    public static func fillUnrated(_ records: [(libraryPath: String, rating0to10: Int)],
                                   current: [String: Int]) -> (updates: [String: Int], conflicts: Int)   // ceil(r / 2)
}
```

Rules:

- **Reading**: `playback_NNNN.log` in numeric order, then `playback.log`,
  from `.rockbox/library/user/`. Opened for reading, never renamed, truncated
  or deleted. `elapsed` above `length` clamps; zero length is skipped; a 64 KB
  guard per line.
- **Key**: the volume UUID plus the whole entry text. Rotation, deletion and
  partial copies cannot double it, and two real plays cannot share timestamp,
  elapsed and length to the millisecond.
- **Resolving** (D7): strip the learned prefix; find the device track in the
  catalog by NFC, case-folded relative path; its `DeviceAlbumIdentity`, slot
  (disc or 1, track number) and folded title must agree with library tracks
  in the whole `index`, never `browsedIndex`. Several: keep those within 2 s
  of the logged length. Still several: the journal hint may pick one of them.
  Otherwise ambiguous. The slot logic is lifted out of the duplicates matcher
  into a shared helper, not written twice.
- **Counting**: `PlayThreshold.isPlayed` and `isSkipped`, the rule in-app
  plays and Last.fm already share. PodBox's own skip rule is not used.
- **Time**: `PlayerClock` with the Mac's zone at that moment. Unset clock: D25.
- **Saving**: apply to `ListeningStore`, save it, then save the ledger. A
  crash between the two can double one batch, which is visible; the other
  order would lose plays silently. If the ledger save throws, imports for
  that device are refused until restart.
- **UX** (D6): Import Plays (device context menu, Preferences ▸ Devices, and
  a "38 NEW PLAYS · IMPORT" line on DEVICES when a UUID-matched PodBox is
  mounted) opens the preview: "38 plays and 9 skips for 31 tracks; 2 could
  not be matched", with the lists, Import and Cancel. Undo Last Import
  reverses the last batch. A `scan` busy job while reading.
- **Scrobbler log**: same ledger (key is the whole line), matched by folded
  artist, album and title to exactly one library track. `L` is a play, `S` a
  skip. The two logs are never written together, so they cannot double.
- **3b, Last.fm** (D8): a per-device switch, off. Only imported, matched
  plays with a real date, at most 14 days old, not in the ledger's scrobbled
  set. Each send shows the count and waits for a yes. Disabled, with a
  caption, when `play log` is `last.fm`.
- **3b, ratings** (D9): when `database_changelog.txt` is newer than the last
  read. Play counts in it are shown, never added.

Tests: `PlaybackLogParserTests` (the device's 224 bytes verbatim; a colon in
a path; CRLF; bad numbers; unterminated tail; rotation order),
`ScrobblerLogParserTests`, `PlayerClockTests` (the Zebra entry; both DST
edges; unset), `DevicePlayResolverTests` (NFC against NFD for "Gdańsk"; case;
duration tie-break; hint only among accepted candidates; a hint pointing at a
track the tags reject is ignored), `DevicePlayImportTests` (twice equals
once; rotated plus live counts once; unmatched not recorded; undo restores
counts, month bucket and last played), `ListeningStatsTests` additions,
`DeviceScrobblePlannerTests` (14 days, 50 per request, already sent),
`RockboxChangelogParserTests` and `DeviceRatingMergeTests` once M9 has
supplied the fixture.

Owner's checks: M6 before the first real import; M9 before ratings.

### Phase 4: playlists, lyrics, names and layout

```swift
// Services/PodBox/PodBoxPlaylist.swift
public enum PodBoxPlaylistWriter {
    /// BOM, one "<prefix>/<relative path>" per line, "\n" endings, nothing else.
    public static func render(relativePaths: [String], prefix: String) -> Data
    public static func fileName(for playlistName: String, taken: Set<String>) -> String?   // FATName; "Name (CrateDigger)" when a foreign file holds the name
}
public enum PodBoxPlaylistReader { public static func paths(in data: Data) -> [String] }   // BOM or codepage fallback; "#" skipped
public enum DevicePlaylistPlanner {
    public static func plan(kept: [KeptPlaylist], libraryTracks: [String: [LoadedTrack]], catalog: [LoadedTrack],
                            firmware: DeviceFirmware, existing: [String], journal: DeviceWriteJournal)
        -> (operations: [DeviceFileOperation], missingByPlaylist: [String: Int])
}
// Services/PodBox/LyricsSidecar.swift
public enum LyricsSidecar {
    public static func syncedText(sidecar: Data?, tagText: String?) -> String?   // nil when there are no [mm:ss.xx] stamps; UTF-16 transcoded
    public static func render(_ lrc: String) -> (data: Data, truncated: Bool)     // UTF-8; 256 bytes a line; 32 KiB in all
}
// Services/PodBox/PodBoxLayout.swift
public enum RockboxLayoutPreset: String, Codable, CaseIterable, Sendable {
    case podBoxRecommended, artistAlbum, custom
    public var template: FolderTemplateConfig?     // [albumArtist, year, album] with [slash, space]
}
public enum PodBoxFolderYear { public static func parse(_ folderName: String) -> Int? }     // tagcache.c:3142
public enum PodBoxDiscFolder { public static func isDiscFolder(_ name: String) -> Bool }     // strutil.c:336
// PodBoxPreferences gains: keptPlaylists: [KeptPlaylist], copiesSyncedLyrics: Bool, fillsCompilationAlbumArtist: Bool
```

- **Playlists out**: the owner ticks playlists and crates per device
  (Preferences ▸ Devices ▸ Playlists on the iPod; "Send to iPod as Playlist"
  on a playlist or crate, which sends its missing tracks through the normal
  review first). Written as extras in any user-started session and by Write
  Playlists Now. Library track to device file uses the phase 3 resolver in
  reverse. Tracks not on the device are left out and counted. A playlist the
  journal does not own (the player's, or ours edited on the iPod) is never
  overwritten. Unticking removes ours only.
- **Playlists in**: the player's own files are listed under the device;
  Import to Library makes a CrateDigger playlist, reporting unmatched lines.
- **Lyrics**: per track, a `.lrc` or `.lrc8` beside the library file, else
  LRC-stamped text in its lyrics tags or `SYLT` (through
  `MetadataProbeService`). Written beside the device file as part of the
  transfer's extras, journal-owned, deleted with its audio on a Replace only
  when its hash still matches. A foreign `.lrc` already there is left; the
  player tries `.lrc` first anyway.
- **FAT names in the transfer planner**: `FATName.component` replaces the
  bare sanitiser for device destinations on `msdos` and `exfat` volumes, for
  new files only. The duplicates matcher works on tags, so nothing already on
  the device is seen as new because its name would now differ.
- **Layout preset** (D5): a picker in Preferences ▸ Devices seeds the
  template. Notes at review time: a planned folder the player would read
  with the wrong year; a copied disc folder it will not recognise. A test
  pins that a missing year gives `Teen Dream`, not ` Teen Dream`, and that
  the artist folder's art key equals the tag's.
- **Compilations** (D15): in convert mode, a track with no album artist gets
  the album's reconciled `albumFolderKeys` bucket written into the converted
  copy only.

Tests: `PodBoxPlaylistWriterTests` (the device's `Pl.m3u8` sample round
trips byte for byte), `PodBoxPlaylistReaderTests`,
`DevicePlaylistPlannerTests` (no prefix gives no operations; foreign file
refused and renamed; missing tracks counted), `LyricsSidecarTests`,
`PodBoxFolderYearTests` (`2010 Teen Dream` gives 2010; `1106 Blue Weekend`
and `20101 Album` give nil), `PodBoxDiscFolderTests`, planner tests for the
preset and for FAT names.

Owner's checks: M7 before playlists, M8 before lyrics, M2 informs the names.

### Phase 5: conventions and the rest

Each item is independent and ships by itself.

- **Review notes**: `PodBoxAdvisor.batchNotes(tracks:firmware:) -> [PodBoxNote]`
  with kinds `compilationSplits`, `audiobookNoAuthor`,
  `audiobookRetagLosesPlace`, `podcastGenreNearMiss`, `podcastNoOrder`,
  `textTooLong`, `sortTagsIgnored`, `hiResOnIpodVideo`, `videoStream`. One
  line in the duplicates review sheet's summary ("5 notes for PodBox") that
  opens a list. Never a dialog per note.
- **Spoken word** (D16): `PodBoxContentKind.classify(genre:)` by the exact
  lists in §2.4; optional routing to `Audiobooks/<Author>/<Book>/` and
  `Podcasts/<Show>/` for new albums; the image beside a single-file book.
- **`/Artwork/Covers`** (D14, M11): `centralCover` role, inside the shared
  budget, only for profiles with no album folders.
- **Hide / Show Folder** : an empty `database.ignore` or `database.unignore`
  in a device folder, by explicit action; removed only when journal-owned.
- **`known_artists.txt`** (D17, M13): offered only when `featured artists`
  is on. A block between two marker comments, rewritten only when its
  current bytes hash to what CrateDigger last wrote, the rest of the file
  byte-identical, a backup in the journal. `FeaturedArtistCredits.guests(inTitle:artist:)`
  mirrors the credit grammar in `featured-artists-guide.md`;
  `KnownArtistsFile.merged(existing:managed:)` is pure.
- **PodBox Files**: a read-only list in Preferences ▸ Devices of the
  owner-editable files (present or not, a first-line check for
  `tagnavi_custom.config`), each with Reveal in Finder.
- **Keyed picture sources** (D1): fanart.tv, Discogs, TheAudioDB, each with
  the owner's own key.
- **LRCLIB** (D11): opt-in, synced only, cached on the Mac.
- **Art status**: the record counts in the headers of `no_art_artists.dat`
  and `no_art_albums.dat` ("PodBox: 12 artists without a picture").
- **Firmware line**: a link to PodBox's releases page.

## Constraints

- Decidable logic lives in Core with XCTests; the view model only wires.
  CLAUDE.md: view-model glue is where bugs concentrate.
- The duplicates work is the base: PodBox steps run after its copies,
  deletions, covers and `patchDeviceCatalog`, and its review sheet is where
  notes appear. Nothing here changes its matching or its decisions.
- Offline queue: PodBox steps run at SYNC, after the queue drains, the first
  moment the device and its firmware are known.
- Firmware is probed at every mount and never trusted from a saved value. The
  owner's iPod went from RockPod to PodBox on the day of the brief.
- Anything that writes the library index (`library.cdartists`,
  `library.cddeviceplays`, listening stats) starts with
  `guard !refuseWhileLibraryDisconnected()`, and both new files join
  `LibraryIndexFiles`.
- No new path-mover duty: nothing here stores a library path that must be
  repointed. The journal's hint is checked against tags before use.
- Busy Signals: every walk, transfer step and import stamps `beginBusyJob`
  and `endBusyJob`. No new job kind.
- Sheets present from `LibraryPresentations`, so they work in the compact
  player. New menu commands are classified in `CompactCommandPolicy`.
- No new third-party code. PodBox's GPL source is never vendored; the name
  fold is a reimplementation proven by output vectors.
- No user details in any request to an outside service.
- Release line: 2.3.x beta work on `v2.3`. Phase 1 can ship in the next beta
  alone.

## Left to the builder

- File and type names where this document's are awkward in place; the
  journal's on-disk form; how the ledger stores keys (whole text or a hash).
- How the next-step lines and the Eject action fit the existing summary
  alert, and the wording of every caption, cell and note.
- The layout of the Artist Pictures sheet and the import preview, each
  subject to the owner's approval from a real capture.
- Whether `finishDeviceSession` takes URLs or the duplicates plan's own
  result type once that exists.
- The exact config key for Scan on Eject (read it from
  `default-config.cfg`); until confirmed, the tip's wording already covers
  both cases.
- Executor details that the FAT sandbox decides (S1 to S6). If stripping
  attributes already prevents twins, the per-file twin check stays anyway.
- Whether phase 2b's background job runs at launch or only from the sheet.

## Open questions for the owner

None of these blocks phase 1.

1. **Your `Music/<Category>/<Artist>/<YYYY Album>` layout.** Where do
   Brasil, Classics, Modern and the rest come from: crates, genres, or by
   hand? Until you say, gaps land in the folders already there and new albums
   follow the profile's template.
2. **Cleanup after every transfer** is on with no switch in phase 1 (it
   removes only proven Mac metadata in the folders just written, and keeps a
   copy). Do you want a switch?
3. **Artist pictures.** Is `/Artwork/People` the right default, or do you
   prefer `folder.jpg` in each artist folder? Is the "accept without asking"
   rule (D2) too strict or too loose once you have seen a first run?
4. **Picture sources with keys.** Do you have, or want to register, a
   fanart.tv, Discogs or TheAudioDB key?
5. **Importing plays.** Preview every time (the default), or "import without
   asking" for this iPod once you trust it?
6. **Last.fm.** Do you want iPod plays scrobbled at all? Do you use another
   uploader for the iPod?
7. **Ratings.** Do you rate on the iPod, and will you run Export
   Modifications for M9?
8. **Lyrics.** Does your library hold `.lrc` files or lyrics in tags? Do you
   want the LRCLIB lookup?
9. **Playlists.** Which playlists and crates should live on the iPod?
10. **Audiobooks and podcasts.** Do you keep any on the iPod? If not,
    phase 5's shelves can wait.
11. **PodBox's text files.** Featured Artists is off on your iPod. Do you
    want `known_artists.txt` managed at all? Would you rather edit `trim.txt`
    and the custom menus inside CrateDigger than in a text editor (D17 says
    no for now)?
12. **Layout preset.** Should your existing profile switch to `Album Artist
    / YYYY Album` for new albums, and do you plan to turn Year From Folder on?
13. **Compilations.** May converted copies get "Various Artists" as album
    artist when they have none?
14. **Other players.** Do you have a stock Rockbox or an iPod Classic
    (`ipod6g`) to check against? Neither was inspected.
15. **`.rockbox_backup` and `.backup`** from today's upgrade are left
    untouched and still take space. Do you want CrateDigger to mention them?
