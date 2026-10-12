# Native Stock iPod support: design

- **Date:** 2026-10-12
- **Line:** 2.4. Branch `v2.4` was cut from `v2.3` at 2.3.0 RC 1 (build 109).
- **Status:** design. Nothing implemented yet.
- **Test hardware (owner):** iPod 1G, 2G, 3G, 4G (incl. Photo/Color), 5G, 5.5G, iPod classic 7G, and two iPod minis.

## 1. What and why

CrateDigger already sends music to **Rockbox** iPods and plain USB storage by copying folders. A **stock** iPod (Apple firmware) ignores folders. It plays only what its own database lists: `iPod_Control/iTunes/iTunesDB`, pointing at files with short opaque names under `iPod_Control/Music/F00…F49`.

Since Catalina, the only Apple route left is Finder sync, which takes over the whole device. 2.4 makes CrateDigger write that database itself: add tracks, playlists and artwork, read the iPod's own plays and ratings back into listening history, and never put the music already on the device at risk.

Today a stock iPod is detected as generic storage (`DeviceProfileSuggesterTests.testStockIPodWithoutRockboxIsGeneric` pins this). It browses as empty, because `iPod_Control` is hidden and its files are obfuscated. Copying folders onto it does nothing visible on the iPod.

### Goals

1. Detect a stock iPod, identify its exact model, and create a **Stock iPod** device profile with defaults right for that model.
2. Browse what is on it, read from the database (not the filesystem), connected or offline.
3. Send albums, tracks and playlists to it through the existing TRANSFER TO / sync-queue / SYNC flow, converted to formats the model plays.
4. Write cover art the model can show.
5. Bring back what happened on the iPod: plays, last played, skips and ratings into `ListeningStore`, and On-The-Go playlists into CrateDigger playlists.
6. Remove tracks from the iPod.
7. **Never corrupt the device.** Every write is backed up, atomic, verified, and recoverable.

### Non-goals (2.4)

- **Other models:** iPod nano (any generation), shuffle, touch. nano 5G needs hash72, nano 6G/7G need hashAB, and shuffles use different databases.
- **Other media:** video, podcasts, audiobooks as their own media types, photos (the Photo Database), smart playlists, Genius.
- **iTunes integration:** editing `iTunesPrefs` or the iTunes library link. CrateDigger reads it to warn, nothing more.
- **Two-way sync** of tag edits made elsewhere. CrateDigger's library is the source of truth for anything CrateDigger put on the device.

## 2. Supported models

Model detection follows libgpod's tables: the model number from `SysInfo`, and the serial-number suffix from `SysInfoExtended`.

| Model (libgpod gen.) | DB checksum | Cover art written | ALAC | Gapless fields honoured | Connects to this Mac (macOS 27) |
|---|---|---|---|---|---|
| 1G, 2G | none | none (mono) | no; **MP3/WAV/AIFF only, no AAC** | no | **No.** FireWire-only, and macOS 26 removed FireWire |
| 3G | none | none | yes (after the 2004 update) | no | yes, through the USB dock cable |
| 4G mono, mini 1G/2G | none | none | yes (mini 1G disputed, see §11) | no | yes |
| 4G Photo/Color | none | 56² and 140², RGB565 LE | yes | no | yes |
| 5G | none | 100² and 200², RGB565 LE | yes | disputed (test) | yes |
| 5.5G | none | 100² and 200² | yes | yes | yes |
| classic 2007/2008/2009 ("7G" = 2008 120 GB or 2009 160 GB) | **hash58** | 56², 128² ×2, 320², RGB565 LE, sparse | yes | yes | yes |

**1G and 2G:** the code supports them (no checksum, no art, MP3 only), but they can't be tested on current macOS. Mark them **"untested"** in Settings. Anyone on macOS 15 or earlier with FireWire can still use them.

**Safe output for every model:** at most 16-bit, 48 kHz.

**Default conversion per model:**

| Model | Default |
|---|---|
| 1G/2G | MP3 V0 / 256 CBR |
| 3G and later | AAC 256 |
| 4G and later | ALAC 16/44.1, offered as the lossless choice |

All of these use the existing `ExternalDeviceTransferSettings` / `.ipodLegacySafe` path, which already writes mp4 atoms and ID3v2.3.

## 3. User experience

1. **Plug in.** `DeviceProfileSuggester` sees `iPod_Control/iTunes/iTunesDB` and no `.rockbox`, and suggests **Stock iPod**. The profile records:
   - the model ("iPod classic 160 GB, 2009")
   - its capabilities
   - the volume UUID
   - for the classic, the FireWire GUID
   
   The icon comes from `IPodCatalog` for that model.
2. **First connection.** CrateDigger reads the database and offers to **back it up**. A backup is also taken before every write; this first one is the "as iTunes left it" copy.
   - If `iTunesPrefs` says the iPod is linked to an iTunes or Music library with automatic sync, the DEV screen warns once: CrateDigger will add to what's there, but syncing it with Finder later may erase everything CrateDigger added.
3. **Browse.**
   - The sidebar Devices row works as now. Selecting it shows the iPod's contents from its database: artists, albums and tracks, with their real files under `iPod_Control/Music`, so they play in CrateDigger.
   - Offline, the cached catalog shows, as it already does.
   - Tracks CrateDigger did not put there (from iTunes) are shown and kept. They can be removed, but they can't be edited.
4. **Send.**
   - TRANSFER TO / the sync queue / SYNC work as today: queue while unplugged, pre-convert, SYNC when connected.
   - There is no folder template and no "music folder" for a stock iPod. Those fields hide in Settings, and the DEV ticker shows the model and DB state instead.
5. **Sync result.** The summary says what was added, removed, skipped (already on the iPod) and failed, plus plays and ratings imported.
6. **Bring back.**
   - On connect, before any write, CrateDigger reads `Play Counts` and `OTGPlaylistInfo`.
   - Plays and ratings merge into listening history for the matching library tracks.
   - On-The-Go lists become playlists named "On-The-Go (<iPod name>, <date>)".
   - This happens automatically. The count appears in the next sync summary, and also on the DEV screen as soon as it's read.
7. **Remove.** "Remove from iPod" on a track or album in the device browser queues a deletion for the next SYNC.
8. **Eject.** The sidebar eject (or SYNC's completion) runs a clean eject. The firmware only re-reads the database after one, so the DEV screen says "Eject before unplugging".

## 4. Architecture

```
Core (new, Sources/CrateDiggerCore/Services/StockIPod/)
  IPodModel / IPodModelCatalog   model number + serial suffix → generation, capabilities
  IPodIdentity                   SysInfo, SysInfoExtended, FireWire GUID (via a provider)
  ITunesDB                       in-memory model: tracks, playlists, header, unknown bytes
  ITunesDBReader / Writer        binary codec (mhbd/mhsd/mhlt/mhit/mhod/mhlp/mhyp/mhip/mhla/mhia…)
  Hash58                         HMAC-SHA1 signature for classic databases
  ArtworkDB + IthmbRenderer      cover formats per model, RGB565 LE frames
  PlayCountsReader, OTGReader    device → host data
  StockIPodLibrary               transaction: read → merge → stage → copy → build → sign → commit → verify
  StockIPodWriter: DeviceWriter  the device strategy the sync loop calls
Core (changed)
  ExternalDeviceKind.stockIPod, traits (usesDatabase, supportsFolderLayout, …)
  DeviceProfileSuggester, PreferencesStore (lossy profile decode), ListeningStore (merge API)
  DeviceTrackManifest            dbid ↔ library path, per profile
App (glue)
  +DeviceSync / +ExternalDeviceTransfer route database kinds through DeviceWriter
  selectDevice builds the index from StockIPodWriter.existingTracks()
  DevicesPreferencesView, DevicesPane (DEV), IPod icons, sidebar
```

### 4.1 The `DeviceWriter` seam

Today, "materialize on the device" is spread over three loops: the copy queue, the SYNC loop, and `runConversion` with a device destination. Each assumes the device is a folder tree. 2.4 introduces one Core protocol:

```swift
protocol DeviceWriter {
    func prepare(mountRoot: URL) throws -> DevicePlan          // read state, merge device→host data
    func existingTracks() throws -> [LoadedTrack]              // for browsing
    func apply(_ changes: DeviceChangeSet,                     // adds (staged files + metadata), removals
               progress: @Sendable (DeviceWriteProgress) -> Void,
               isCancelled: @Sendable () -> Bool) throws -> DeviceWriteReport
}
```

- **`FolderDeviceWriter`** wraps today's behaviour exactly: copy or ffmpeg to the planned relative path, "exists" means skip. That keeps Rockbox, generic storage and direct-file players byte-identical.
- **`StockIPodWriter`** implements the transaction in §5.
- The SYNC loop body in `+DeviceSync.syncQueuedTransfers` becomes a call to the profile's writer. Preflight, artwork hydration, checkpointing, progress and summary stay as they are.

**For database kinds, conversion always goes through staging.** Stock iPods never take the `pendingDeviceConversion → runConversion` hand-off, which assumes a destination folder plus collision, version-folder and template prompts. TRANSFER TO on a mounted stock iPod stages and then runs SYNC immediately. `DeviceSyncQueueEntry.destinationRelativePath` keeps meaning "where it is in staging". An optional field marks entries whose device location is assigned by the writer.

### 4.2 Identity and capabilities

**`IPodModelCatalog`** is a Swift table built from public model-number lists: model number, capacity, generation, colour screen, cover formats, ALAC, gapless, checksum type, F-folder count. It is tested against the model numbers of the user's devices.

**`IPodIdentity`:**

1. `iPod_Control/Device/SysInfo`: `ModelNumStr` (strip the leading letter), `FirewireGuid`, if present. It may be missing or partial.
2. **FireWire GUID (classic only):** from the USB device's serial number (`kUSBSerialNumberString` on the Apple-vendor `IOUSBHostDevice` whose descendant IOMedia carries the volume's BSD name). This is behind a `FireWireGUIDProviding` protocol so tests can fake it.
3. `SysInfoExtended`, if a previous tool wrote it: `DBVersion`, serial, `ImageSpecifications`, `AudioCodecs`. This is optional. 2.4 does **not** issue SCSI INQUIRY itself, because macOS permissions for that are unverified. It's a later option if the catalog proves insufficient.

**If a classic's GUID can't be found, refuse to write.** An unsigned classic database makes the iPod look empty. Never ship one.

### 4.3 iTunesDB model and codec

**Round-trip first.** The reader parses every chunk into the model and keeps **unknown header bytes and unknown mhod types verbatim**. The writer re-emits them. Tracks iTunes wrote keep everything CrateDigger doesn't understand.

**Writer layout:** libgpod's, which has worked on hardware for over a decade:

- version 0x30
- header sizes mhbd 0xF4, mhit 0x248, mhod 0x18, mhyp 0x6C, mhip 0x4C
- mhsd order 1, 3, 2, 4, 8, 6, 10, 5
- mhbd+0x0C = 1. A 2009 classic rejects 2.

**A second, legacy shape** is kept for older firmware: mhsd 1 and 2 only, iTunes-4-era headers. It's selected per generation **only if hardware testing shows the modern shape fails** on 3G, 4G or mini. Test both shapes on the user's devices before committing to one.

**Tracks:**

- Required: a location mhod (`:iPod_Control:Music:Fnn:NAME.ext`, ASCII name, lowercase extension, under 112 bytes).
- Strings: title, artist, album, album artist, genre, composer and sort fields, UTF-16LE, each capped well under 512 characters (longer can boot-loop).
- Numbers:
  - track and disc numbers, year, length, bitrate, sample rate (<<16), size
  - rating (stars × 20), dates (Mac epoch, device-local)
  - mediatype 1, `mark_unplayed` 1
  - a random unique 64-bit `dbid`; `id` renumbered sequentially at write
- Album list (mhsd 4) and artist list (mhsd 8): built from the tracks, as libgpod does.

**Playlists:**

- The master playlist (hidden flag, first, containing every track) with mhod 52/53 sort indexes for title, artist, album, genre and composer. Without them browsing is slow.
- CrateDigger playlists and crates can be sent as iPod playlists.
- Existing playlists and smart playlists are preserved verbatim.

**Dates:** the timezone shift comes from `Device/Preferences` (the offset depends on the file size), falling back to the host timezone.

**Files:**

- Use the `Fnn` folders that already exist and never create more. Pick folders round-robin by fill, to spread files.
- Names are random 4–8 character ASCII.

### 4.4 Checksum (classic): Hash58

Implemented from the published algorithm, not by copying code. libgpod's `itdb_hash58.c` is BSD-style licensed anyway.

1. **Key:** for i = 0…3, L = lcm(guid[2i], guid[2i+1]) (1 if either is 0).
2. Append `SBOX[L>>8], INV_SBOX[L>>8], SBOX[L&0xFF], INV_SBOX[L&0xFF]` (the AES S-box and inverse S-box from FIPS-197). This gives 16 bytes, `y`.
3. key = SHA1(`67 23 FE 30 45 33 F8 90 99 21 07 C1 D0 12 B2 A1 07 81` ‖ y).
4. **Signature:** set mhbd+0x30 = 1. Zero db_id (0x18, 8 bytes), 0x32 (20 bytes) and the hash slot (0x58, 20 bytes). Take `HMAC<Insecure.SHA1>(key, whole file)`. Write the result at 0x58 and restore db_id and 0x32.
5. **It's the last mutation before the bytes hit disk.**

**Tests:** a fixed vector cross-checked against an independent implementation, run once in a scratch harness. iOpenPod (GPL) is used **only as a test oracle**, never shipped or copied.

### 4.5 Artwork

Only for models with colour screens.

- **Covers:**
  - Rendered from `ArtworkService` (embedded, then folder art) into each format's fixed frame: aspect-fit, centred, background filled, RGB565 little-endian, rows aligned.
  - Frames go into **new** `F<format>_<n>.ithmb` files. Never rearrange existing files in place: libgpod does, and it isn't crash-safe.
- **ArtworkDB:** mhfd → mhli/mhii/mhni, mhla, mhlf/mhif.
  - Classic: sparse. Tracks with identical art share one mhii, linked through `mhit+0x160`.
  - 4G Photo and 5G: one mhii per track, joined through `mhii.song_id = mhit.dbid`.
- **Every track with art:** `has_artwork = 1`, `artwork_count ≥ 1`, `artwork_size`.
- **Garbage collection:** unused ithmb files are deleted only after a successful commit. Old frames stay referenced by the old ArtworkDB until then.

### 4.6 Device → host data

**`Play Counts`** has one entry per mhit, in the order of the database the iPod last loaded. Read it **before** rewriting anything.

| Field | Merge rule |
|---|---|
| plays, skips | add |
| last played / skipped | keep the later date |
| rating | take the iPod's value when it differs from the database's rating. Newer firmware copies the DB rating, so don't treat 0 as "no change" |

- **Where it goes:** plays and ratings are written to the iPod's own database (so the iPod shows them), and to `ListeningStore`. The library path comes from `DeviceTrackManifest` (dbid → path).
- **New API:** `ListeningStore.mergeDeviceActivity(path:plays:lastPlayed:skips:rating:)`. `recordPlay` is +1 only. Plays land in `playsByMonth` under the last-played month: a documented approximation, since the iPod doesn't record individual play dates.
- **After a successful commit:** rename `Play Counts` → `Play Counts.bak`, as libgpod does.

**On-The-Go:** `OTGPlaylistInfo*` entries are 0-based mhlt indexes. Convert them into playlists before the write, then delete the base file.

### 4.7 Manifest

`DeviceTrackManifest`, stored in `Application Support/CrateDigger/DeviceManifests/<profile id>.json`, maps dbid ↔ library path ↔ source content fingerprint (size + mtime).

- It answers "is this library track already on the iPod".
- It maps the iPod's plays back to library tracks.
- Every path-changing mover (`updateTrackURLInIndex`, `updateTrackURLsInIndex`, `rewriteTrackPaths`, the import copy) must repoint it, beside `ListeningStore.repoint` and `streamStore.repointDownload`. See CLAUDE.md's "treat the list of movers as examples" rule.
- If the manifest is lost, CrateDigger re-matches by tags + duration, best effort.

## 5. The write transaction (StockIPodWriter.apply)

Strict order. Any failure before step 8 leaves the device exactly as it was, apart from orphan audio files, which the next run cleans up.

1. **Lock and read.** Parse iTunesDB (and ArtworkDB). Verify the checksum when the model needs one: a mismatch means iTunes or something else wrote it, so warn. Read Play Counts and OTG.
2. **Back up.** Copy iTunesDB, ArtworkDB, Play Counts and OTG files to `Application Support/CrateDigger/IPodBackups/<serial>/<timestamp>/`. Keep the last 10, plus the first-ever backup forever. This only exists if the read succeeded.
3. **Merge** device → host data into `ListeningStore` and playlists. Persist them, so they're never lost even if the write later fails.
4. **Copy audio.** Each staged file goes to its `Fnn/NAME.ext`. Under `.tmp` names first; rename after `F_FULLFSYNC`. Skip anything already present according to the manifest plus the DB.
5. **Build** the new database in memory: existing tracks (verbatim), plus additions, minus removals; playlists; sort indexes; album and artist lists.
6. **Artwork:** render new frames into new ithmb files and build the ArtworkDB in memory.
7. **Sign** (Hash58 for the classic) as the final mutation.
8. **Commit:**
   1. Write the ArtworkDB to a temp file, `F_FULLFSYNC`, then `rename()`.
   2. Same for iTunesDB.
   3. Rename Play Counts to `.bak` and delete the OTG base file.
   4. Delete the audio files of removed tracks and unused ithmb files.
9. **Verify.** Re-read the written iTunesDB from disk, re-parse it, and check the checksum and track count. On failure, restore the step-2 backup and report.
10. **Update the manifest and catalog.** Remind the user to eject.

**Cancellation** is honoured up to step 7. After step 8 begins, the commit runs to completion.

## 6. Profile persistence hazard (fix first, on v2.3)

`PreferencesStore.savedExternalDeviceProfiles` decodes `[ExternalDeviceProfile]` with `try?` into `[]`. A build that meets an unknown `kind` (`"stock_ipod"`) loses **every** profile, and the next save overwrites the list.

**Required before any build writes the new kind:**

1. **Decode lossily per element.** Unknown kinds are kept as raw JSON and written back untouched. Land this on **v2.3 before 2.3.0 GA**, so the installed base that 2.4 betas will share defaults with already tolerates it.
2. **Store stock-iPod profiles under a separate key** (`cratedigger.externalDevices.databaseProfiles`) in addition, so even a 2.2.x build never sees them.

## 7. Settings and UI changes

- **DevicesPreferencesView:**
  - A "Stock iPod" type, with the detected model shown read-only and capability chips (Art, ALAC, Gapless, Checksum).
  - Hide the music-folder and folder-template fields for it.
  - Add "Back up now" and "Restore a backup…" (lists the backups; restore requires the iPod connected and asks for confirmation).
- **DEV screen (`DevicesPane`):** a STOCK kind cell; model; tracks on device; free space; DB state ("OK", "Changed by iTunes", "Backup restored"); the plays waiting to import. Fix its `connected` matcher to use `ExternalDeviceProfile.match` (UUID), and fix the unmount fallback the same way.
- **Browser on a stock iPod:** "Remove from iPod". FIX ART is replaced by artwork being part of SYNC.
- **Copy:** user-facing text follows house rules (plain words, no em or en dashes).

## 8. Milestones

| # | Milestone | Ships in | Hardware to test on |
|---|---|---|---|
| M0 | Lossy profile decode + separate key (§6) | 2.3.0 GA (v2.3) | none |
| M1 | Read-only: detect, identify, parse iTunesDB/ArtworkDB, browse, play from device, Play Counts read (no write) | 2.4 beta 1 | 5.5G, 7G, mini |
| M2 | Write tracks + playlists, no checksum models; the transaction, backups, verify; manifest | 2.4 beta 2 | 5G, 5.5G, 4G, mini, 3G (shape test) |
| M3 | Hash58 + classic | 2.4 beta 3 | 7G |
| M4 | Artwork (4G Photo, 5G, classic) | 2.4 beta 4 | 4G Photo, 5G, 7G |
| M5 | Plays/ratings/OTG import into ListeningStore; removals; gapless fields (MP3 LAME header, AAC `iTunSMPB`) | 2.4 beta 5 / RC | all |

## 9. Testing

**Unit (Core, XCTest):**

- chunk codec round-trip, byte-identical, on synthetic databases, and on databases captured from the owner's iPods (fixtures reduced to synthetic tags before committing)
- a Hash58 vector
- the model catalog lookup
- the Play Counts and OTG parsers
- the ithmb renderer (pixel packing, stride, padding)
- the transaction ordering, using a fake filesystem/writer that fails at each step, proving the device is unchanged before step 8 and restored after a failed verify
- the manifest repoint
- the `ListeningStore` merge rules
- the lossy profile decode

**Hardware matrix:** per model, run the following, and record firmware version, DB shape used and result in `docs/STOCK_IPOD_TEST_MATRIX.md`:

1. add an album
2. add a playlist
3. play on the device
4. rate and play on the device
5. sync again (plays come back)
6. remove a track
7. artwork shows
8. eject/reconnect
9. restore a backup

**Never test on a device whose contents matter without a manual backup of `iPod_Control/iTunes` first.**

## 10. Licensing

The format knowledge comes from documentation and reading open implementations: the iPodLinux wiki, libgpod (LGPL; `itdb_hash58.c` BSD-style), iOpenPod (GPL-3) and gtkpod (GPL). **No code is copied.** The AES S-boxes come from FIPS-197, and the 18-byte hash constant is a protocol value. GPL tools may be run locally as test oracles but are never bundled.

## 11. Risks and open questions

1. **Does old firmware (3G, 4G, mini) accept libgpod's modern layout?** Untested anywhere we found. That's why the legacy shape exists (§4.3); settle it in M2.
2. **Gapless on the original 5G** is disputed. ALAC on the mini 1G is disputed. Test both.
3. **FireWire GUID from the USB serial** is documented for classics. The IOKit walk from the volume to the USB device needs verifying on the 7G.
4. **Classic 56×56 vs 55×55 frame (format 1061),** and the mhfd+0x10 value (2 vs 6). Verify on the 7G by reading an iTunes-written ArtworkDB first.
5. **Finder/Music behaviour** with a third-party database is community-reported. The warning (§3.2) is the mitigation.
6. **1G and 2G can't be tested on current macOS.** They ship as "untested".
7. **Play-date granularity:** the iPod gives a count and a last-played date only, so `playsByMonth` attribution is approximate.
8. **iPod in Disk Mode vs normal USB:** normal USB mounting works. Disk Mode isn't needed.
