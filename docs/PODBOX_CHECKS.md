# PodBox: checks to run on the real iPod

These are the checks the PodBox design asks you to run yourself, on your own
iPod, before CrateDigger is allowed to do each thing for real. No agent has
run any of them, and none ever will: the build only ever touched temporary
folders and a disk image.

Each check says what to do, what result means go, what means stop, and how
to undo it. The rule behind all of them: **a feature stays off until its
check says go.** Where CrateDigger has a switch for it, the switch is off
now and stays off until you turn it on.

The design behind this list is
`docs/superpowers/specs/2026-11-11-podbox-integration-design.md`
("Manual checks on the real iPod" and "Safety"). The code is on the branch
`feat/podbox`.

## Before you start

- Build the branch (`swift build`) and have the iPod connected only when a
  check says so.
- Do the checks in the order below. Some depend on an earlier one.
- Keep CrateDigger's journal folder, `~/Library/Application Support/CrateDigger/DeviceJournal/`.
  It holds a copy of everything CrateDigger replaced or deleted on the iPod,
  and it is how you undo most things.
- Two things are different about the iPod from a normal drive. macOS stores
  extra information for some files in small hidden files whose names start
  with `._` ("Mac files" in the app). Finder and many apps hide them. In
  Terminal, `ls -la` on a folder shows them. PodBox reads each one as a
  broken music file, which is the whole reason for the cleanup.
- Make a backup copy of the iPod's music folder to the Mac first if you can.
  It is not required by any check, but it makes every "undo" below trivial.

---

## Part 1: the checks that gate what is built now

### M1. Read-only dry run

**Gates:** everything below. **Changes the iPod:** nothing.

1. Quit CrateDigger. Build the debug app (`swift build`).
2. In Terminal, from the repo folder:
   `CRATEDIGGER_PODBOX_DRYRUN=/Volumes/IPOD .build/debug/CrateDiggerApp`
   (use your iPod's real mount name if it is not IPOD). It prints a report
   and exits. It opens nothing for writing.
3. Read the report.

**Go:** it says PodBox, library layout 5, target `ipodvideo`, build date
2026-11-08, player path prefix `/<HDD0>`; the cleanup plan lists a number of
Mac files close to the number of `._` lines the iPod itself shows in its
unreadable-files list; the last line says `0 files would be written`.

**Stop:** anything else, or any file on the iPod showing a new date. Do not
run anything further and tell whoever is building this what the report said.

**Undo:** nothing to undo.

### M2. How names are stored (read-only)

**Gates:** non-ASCII artist pictures (M5 with an accented name), and later
the path rules for playlists. **Changes the iPod:** nothing.

1. In the M1 report, find the "names" section. Look at the raw bytes it
   shows for the `Gdansk` folder with the accent (`Gda` followed by n with an
   acute accent, then `sk`), and at the list of names under `Music` that
   contain `? * " < > |` or end in a dot.
2. Note whether accents are stored as one character (NFC) or as a letter
   plus a separate accent (NFD).

**Go:** the report tells you which form is used, and you have the list of odd
names.

**Stop (partly):** names stored as letter plus accent (NFD). Artist picture
file names are written to match the player, so repeat M5 below with an artist
whose name has an accent before trusting accented names. Everything else
carries on.

**Undo:** nothing to undo.

### M3. Look at three of the Mac files (read-only)

**Gates:** M4, the cleanup. **Changes the iPod:** nothing.

1. In the M1 report, pick three of the listed `._` files.
2. In Terminal, for each: `xxd -l 8 "/Volumes/IPOD/<path of the file>"`.
3. Read the report's size table.

**Go:** all three start `00 05 16 07 00 02 00 00`; every candidate is 128 KB
or smaller; nothing listed lies under `.rockbox`, `.rockbox_backup`,
`.backup` or `iPod_Control`.

**Stop:** any miss. The cleanup stays unused. Tell whoever is building this
which file and what it held.

**Undo:** nothing to undo.

### M4. The first cleanup (this one deletes, with a backup)

**Gates:** the cleanup after each transfer, and any whole-volume cleanup.
**Changes the iPod:** removes `._` files only, and keeps a copy of each on
the Mac first.

1. Browse the iPod in CrateDigger (Sources, the device). Right-click **one
   album folder** and choose **Clean Up Mac Files in This Folder...**.
2. Read the confirmation. It gives the count ("N Mac metadata files found.
   M other files are left alone."). Confirm.
3. In Terminal, run `ls -la` on that folder. The `._` files should be gone
   and every real file still there.
4. Eject the iPod, let it rescan (or choose Update Database in its
   Maintenance menu), reconnect it. Play a track from that album.
5. Check the iPod's unreadable-files list no longer names that folder.
6. Look in `~/Library/Application Support/CrateDigger/DeviceJournal/<profile id>/backups/`.
   There should be a folder per cleanup holding a copy of each removed file.
7. Only then run **Clean Up Mac Files...** for the whole iPod (the device's
   context menu, or Preferences > Devices).

**Go:** the album plays; its `._` files are gone and nothing else is; the
unreadable list no longer names it; the backups exist.

**Stop:** anything else missing, or the album no longer plays. Copy the files
back from `backups/<session>/` (same relative path), and do not use the
cleanup again.

**Undo:** copy the files from the backup folder back to the same paths on the
iPod. They are only Mac metadata, so the iPod works without them either way.

**Then, if you want it:** turn on **Clean up after each transfer** in
Preferences > Devices for this iPod. It is off until you do, and it only
tidies the folders a transfer just wrote into. Preventing new `._` files
needs no switch: CrateDigger never makes them in the first place when it
writes through its new route.

### T1. The first transfer through the new route

**Why this is on the list:** every transfer to a device now goes through one
guarded route (policy, journal, a temporary file then a rename, no Mac
metadata). The tests prove it on a disk image made like the iPod's. This is
the first time it meets the real iPod. **Changes the iPod:** adds one album.

1. Pick a small album that is **not** already on the iPod, and no more than
   a few tracks.
2. Send it the way you normally do (copy or convert, to the iPod profile).
   If the "Already on" sheet appears, that is expected only for an album that
   is already there, so cancel and pick another.
3. When it finishes, read the summary. It ends with the steps to do on the
   iPod, and has an **Eject** key.
4. In Terminal, run `ls -la` on the new album's folder. There should be the
   audio files and `cover.jpg` if you use folder art, and **no** `._` files
   and no `.cdtmp` files.
5. Eject with the key. On the iPod, follow the steps the summary gave
   (normally the iPod picks up new music when it restarts; if the album does
   not show, Settings > Library > Maintenance > Update Database).
6. Play the album. Check the cover shows.
7. Look at `~/Library/Application Support/CrateDigger/DeviceJournal/<profile id>/journal.jsonl`.
   It should have one line per file written.

**Go:** the album is complete, plays, has no `._` or `.cdtmp` files, and the
iPod's unreadable list does not name it.

**Stop:** a missing or short file, a `.cdtmp` left behind, a `._` file next to
a new file, or the iPod not seeing the album after Update Database.

**Undo:** delete the album folder from the iPod in Finder. CrateDigger never
replaced anything in this check, so there is nothing to restore.

**Also worth trying once, with care:** an album by an artist whose name ends
in a dot (for example `R.E.M.`). CrateDigger writes it as `R.E.M` on the iPod
(FAT cannot keep a trailing dot). If you already have an `R.E.M.` folder on
the iPod, new files for that existing folder will be refused with a message,
not written. See "Known limits" below.

### M5. The first artist picture

**Gates:** artist pictures after a transfer, and the `/Artwork/People`
folder. **Changes the iPod:** adds one picture file (and removes it if you
undo).

Pictures are off until you turn them on. This check uses the Artist Pictures
sheet, so CrateDigger does only what you press.

1. Pick **one** artist on the iPod whose name has `&`, an accent, or a leading
   "The" (the three cases the name matching is built for). Make sure the iPod
   shows no picture for them now.
2. In Preferences > Devices, select the iPod. Set **Artist pictures** to
   **In /Artwork/People**. Leave **Find missing artist pictures
   automatically** off, and leave **Verified on this iPod (M5)** off.
3. Choose **Artist Pictures...**. Find that artist. If the row has no picture,
   choose **Choose File...** and pick a picture of your own (this sends
   nothing over the network). Or press **Find Missing** if you are happy for
   CrateDigger to send the artist's name to Deezer, MusicBrainz, Wikidata and
   Wikimedia Commons. Accept the picture for that artist only.
4. Press **Apply**. Eject the iPod.
5. On the iPod: Settings > Library > Maintenance > **Update Art Cache**, then
   open that artist. Before you run Update Art Cache, look at the artist once
   and note whether the picture is already there (that is check M12).
6. Back on the Mac, in Terminal run `ls -la /Volumes/IPOD/Artwork/People`.

**Go:** the picture shows on the iPod for that artist; there is no `._` file
in `/Artwork/People`; the file name looks like the artist's name in plain
letters and digits. Then, and only then, turn on **Verified on this iPod
(M5)** in Preferences > Devices. That lets pictures be written after a
transfer.

**Stop:** no picture shows, or something odd shows for another artist, or a
`._` file is in the folder. Remove `/Artwork/People/<name>.jpg` (or use the
remove button for added pictures in Preferences > Devices, which keeps a copy on the Mac), run Update Art Cache
again, and leave the switch off.

**Undo:** in Preferences > Devices there is a remove button for pictures
CrateDigger added. It removes only files CrateDigger wrote and nobody has
changed since, keeps a copy on the Mac, and leaves your own pictures alone.
Or delete the one file by hand and run Update Art Cache.

**If the iPod already shows pictures for most artists** (from your own
files), that is expected: CrateDigger never writes a picture for an artist
the iPod already finds one for. A message such as "the catalog does not match
the device, rescan first" means CrateDigger's list of the iPod's music is out
of date. Rescan the iPod in CrateDigger and try again.

### M12. Did the iPod redraw by itself?

**Changes the iPod:** nothing. Do this inside M5.

After M5 step 4, and before you run Update Art Cache, look at
`.rockbox/library/cache/art/stamps.dat`'s date (`ls -l` on it; do not open or
edit it) before and after the eject. Note the result.

**Either answer is fine.** It only decides whether the on-screen reminder
says "run Update Art Cache" or "PodBox will do it".

---

## Part 2: the checks for things not built yet

These match later phases of the design. Nothing in the app uses them today,
so there is nothing to run now. They are here so the list is complete.

| # | Opens | Changes the iPod | What to do | Go | Stop and undo |
|---|---|---|---|---|---|
| M6 | Play import | Nothing (use a scratch copy of the crates folder, `CRATEDIGGER_CRATES_DIR`) | Run Import Plays and stop at the preview | The two "Zebra" entries map to the library's Zebra, dated 2026-11-11 22:25 local, 29 s and 33 s of 292 s, neither counted as a play | Any other track, time or count: import stays off |
| M7 | Playlists | Two named files | Write `CD Test A.m3u8` (with the `/<HDD0>` prefix) and `CD Test B.m3u8` (paths starting `/Music`), eject, open both on the iPod | A plays (B playing only widens later support) | A does not play: delete both files; playlists stay off |
| M8 | Lyrics | One named file | Send one track with a synced lyric, play it, open the lyrics screen | Lines show in time, accents correct | Delete `<stem>.lrc8`; lyrics stay off |
| M9 | Ratings | The player writes one file | Rate three tracks on the iPod, run Settings > Library > Maintenance > Export Modifications, copy `/.rockbox/database_changelog.txt` to the Mac | First line is `## Changelog version 1`; it becomes a test fixture | A different format: ratings wait for a parser written from the real file |
| M10 | Recommending Re-embed on PodBox | One named folder | Convert one album with art Re-embedded into `Music/_CrateDigger Test/`, eject, rescan | The album is in the library with a colour cover, and an `.m4b` keeps its chapters | Tracks missing or grey art: delete the folder; the note says "set the iPod to Image Files" instead |
| M11 | `/Artwork/Covers` | One named file | For one album in a flat test profile, write `/Artwork/Covers/<Artist> - <Album>.jpg`, Update Art Cache | That cover shows for that album only | Delete the file; the feature is not built further |
| M13 | Featured artists (known artists file) | One named file | Turn Featured Artists on, let CrateDigger write the file with one guest name, restart the iPod | The name stays whole in the Artists list | Delete `/.rockbox/library/user/known_artists.txt`; the feature stays off |

---

## Known limits and things you should know

These came out of the build and review, and some need a decision from you.

- **Folders that end in a dot.** FAT drops a trailing dot, so CrateDigger
  refuses to write anywhere whose name ends in one. New albums are written
  with the dot removed (`R.E.M` for `R.E.M.`). A folder that already ends in a
  dot on the iPod (an old `R.E.M.` folder) is refused: filling gaps in it,
  Replace and covers there fail with a message, and nothing is written. Your
  call: rename the folder on the iPod by hand, or accept it.
- **Not everything goes through the new route yet.** Transfers, SYNC, covers,
  the cleanup and artist pictures do. These do **not**, and still write the
  way they did before: an ordinary conversion or CD rip whose output folder
  is the iPod, a Record Divider export to it, and, on an iPod you are
  browsing in the library, Edit Tags, embedding or stripping art, Move to
  Trash and saving an artwork manifest. They were not changed. If you use
  them on the iPod, check for `._` files afterwards, and run Clean Up Mac
  Files. Your call whether to route them too.
- **Library folders the scanner cannot read.** Audio hidden by a FAT
  attribute is not seen by CrateDigger's scan, so such a folder can make the
  picture planner refuse with a message naming the folder. Clear the attribute
  or leave that folder alone.
- **Custom folder layouts keep "Unknown Year".** Only the new PodBox layout
  drops it for albums with no year. Existing layouts are left as they were so
  an album already on the iPod is not written a second time.
- **Network use.** Artist pictures can contact Deezer, MusicBrainz, Wikidata
  and Wikimedia Commons. Only the artist's name goes out (plus ids those
  services return). It identifies itself as
  `CrateDigger/<version> (https://cratedigger.mrbarkan.com)`, the same for
  every install, which names the site's domain. Nothing is sent unless you
  turn on "Find missing artist pictures automatically" or press **Find
  Missing**.
- **MusicBrainz limit now shared.** Artwork search, FIX TAGS, DEEP SCAN, CD
  lookup and artist pictures now all wait at one shared gate (about one
  request a second), so running two together is a little slower, not blocked.
- **What happened to your Mac during the build.** One agent launched the
  debug app without isolating it for about three minutes. The effects, as far
  as checked: your app preferences file was modified, the offline copy of your
  library index was refreshed (normal launch housekeeping), and the saved
  device catalogs were deleted by this build's one-time reset (the next time
  you browse each device it rescans; that reset would have happened on the
  first launch of this build anyway). A read-only look found no file changed
  on the iPod. A later, isolated launch also wrote and then deleted a
  scratch preferences file and restarted the system preferences daemon.
- **Not exercised by any test.** The app's glue for Find Missing, Apply and
  Remove in the Artist Pictures sheet was never run, by rule (it needs a
  device and the network). T1 and M5 are where it runs for the first time.
