# Offline library: design

2026-09-16. Target: next feature release. Built on `feature/offline-library`.

## What

A library whose index lives on an external drive stays visible while the
drive is out. CrateDigger keeps a copy of the index on this Mac and, when the
drive is not connected, shows the library from that copy: every crate, album,
cover, play count and rating, dimmed, with a clear "disconnected" message.
Nothing can be changed until the drive is back, and reconnecting switches to
the live library on its own.

## The problem it fixes

With the drive ejected, launching said "No library loaded". Worse than
confusing: `cratesDirectoryURL` could not resolve the crates folder bookmark,
fell back to `Application Support/CrateDigger/Crates` without a word, and
`refreshAvailableCrates` found no crates there and wrote a fresh, empty
Personal Crate. Anything saved that session (a rating, a crate change) went
into that stand-in. One such stand-in was found on the author's Mac, dated
21 July, holding `[]` in both files. It is left alone: nothing here deletes
user files, and the app no longer reads that folder while a crates folder is
chosen.

Reconnecting did not bring the library back either: only a crates folder
change reloaded the crate list.

## Decisions

- **Browse only while disconnected.** The copy can never disagree with the
  real index, so there is nothing to merge.
- **The copy is refreshed at launch, at quit and when the drive is about to
  eject.** One step in three places. A drive pulled out without ejecting
  leaves the copy as of the last launch or quit, which only affects what is
  shown offline.
- **Covers need nothing new.** Thumbnails already live in
  `Application Support/CrateDigger/Thumbnails`, and index files carry only
  artwork hashes.
- **Size:** the author's index is 15 crates, an 11 MB `library.cdtracks` and a
  1.7 MB `library.cdplays`, well under a second to copy.

## Pieces

### Core: `LibraryLocation` (`Models/LibraryLocation.swift`)

`notChosen`, `available(URL)` or `disconnected(volumeName:folder:)`, from
whether a bookmark is saved, what it resolved to, the folder recorded with the
local copy, and which volumes are mounted. The library is disconnected only
when its folder is under `/Volumes/<name>` and that drive is not mounted, so
it holds whichever way bookmark resolution behaves for a missing drive (nil or
the old path; a probe could not settle which). A folder on the internal disk
keeps today's behaviour. Nothing known at all is `disconnected(nil, nil)`,
which is also what a deleted folder looks like, so the wording for it points
to both ways out.

`/Volumes` is `root:wheel 755`, so a user process cannot leave a fake
`/Volumes/<name>` folder behind: its existence means the drive is mounted.

### Core: `LibraryIndexFiles` and `LibraryIndexCopy` (`Services/LibraryIndexCopy.swift`)

- `LibraryIndexFiles` is the list of index file types (`cdcrate`,
  `cdtracks`, `cdplays`). `moveIndexFiles` and the copy both read it, where the
  list used to live inside `moveIndexFiles` behind a warning comment.
- `LibraryIndexCopy` lives at `Application Support/CrateDigger/LibraryCopy`
  with a `copy.json` record (source path, time). A write builds a whole new
  copy in a hidden sibling folder and swaps it in only when complete, so a
  copy interrupted part-way leaves the previous one untouched.

### App: `LibraryViewModel+LibraryLocation.swift`

- `libraryLocation` is stored, decided at the start of
  `refreshAvailableCrates()` (which every folder change already runs through)
  and on every mount, unmount and rename. `cratesDirectoryURL` reads it
  instead of resolving the bookmark on each call: the live folder, the copy
  when disconnected (never created), or the Application Support default when
  no folder was chosen.
- While disconnected, `refreshAvailableCrates` skips legacy migration, the
  play-history backfill and creating Personal Crate. With no copy yet it lists
  no crates.
- `refreshLibraryIndexCopyInBackground()` at launch and on reconnect,
  `refreshLibraryIndexCopyNow()` at quit (`applicationWillTerminate`), and
  `copyLibraryIndexBeforeUnmount` synchronously inside the
  `willUnmountNotification` observer, because a hop to the main actor could
  run after the drive is gone. A debug run with `CRATEDIGGER_CRATES_DIR` never
  writes the copy.
- `libraryVolumesChanged()` runs before `recomputeOfflineVolumes` on mount,
  unmount and rename and switches between the live folder and the copy when
  the location changed.

### Read-only while disconnected

`refuseWhileLibraryDisconnected()` shows the OLED notice
`MUSIC IS DISCONNECTED` (or `LIBRARY FOLDER NOT FOUND`) and returns true.

| Refused | Where |
|---|---|
| Index writes (backstop) | `persistTrackStore`, `saveCrateTracks` |
| Crate files | `createCrate`, `deleteCrate`, `renameCrate`, `moveIndexFiles` |
| Audio file changes | `updateTrackMetadata`, `updateTracksMetadata` (FIX TAGS), `embedCoverIntoTracksInBackground`, `stripEmbeddedArtworkInBackground`, `applyFetchedArtwork`, `searchAndAddCovers`, `splitAlbumFolder`, `moveAlbumFiles`, `automaticallyReorganizeLibrary`, `importTracksIntoCrate`, `addURLsToCrate` (before its scan, so a Finder drop is refused before the wait), `relinkMissingTrack`, `relinkMissingTracksFromFolder`, `moveLibrary`, `consolidateLibrary` |
| Ratings | `rateSelection` |
| Plays and skips (silent) | `recordPlayIfThresholdMet`, `recordSkipForOutgoingTrack`, `persistListeningStore` |

Still allowed: browsing and searching the copy, playing any reachable file,
Last.fm scrobbles, Prep Crate imports (in memory only), Back Up Library and
crate export (read only), and the CD, radio, device and remote sources. Menu
items stay enabled; the notice explains each refusal.

### On screen

- OLED library pane: headline `MUSIC DISCONNECTED` (or `LIBRARY NOT FOUND`),
  subtitle `Showing your last saved library · Changes paused`, or
  `Connect the drive to see your library` with no copy.
- `LibraryDisconnectedBar` over the browser, styled like `DiscIdentityBar`:
  `“MUSIC” is disconnected` / `Showing your library as of <date>. Changes are
  paused until it’s back.`
- Empty browser with no copy: `Library drive disconnected` / `Your library is
  on “MUSIC”, which isn’t connected. Connect it and CrateDigger picks it up
  automatically.` No OPEN FOLDER button. With no drive name: `Library folder
  not found` / `CrateDigger can’t find your library folder. Connect its drive,
  or choose the folder again in Preferences.`
- Preferences, Crates Index help text: no longer tells people to keep the
  index on a local disk.

## Tests

- `LibraryLocationTests`: no folder chosen, internal disk, mounted drive,
  resolved folder on an unmounted drive, fallback to the last known folder
  (unmounted and mounted), resolved wins over last known, nothing known,
  volume name parsing.
- `LibraryIndexCopyTests`: copies only index files and records the source,
  keeps contents, drops crates deleted since, a failed copy (unreadable file)
  and a missing source both leave the previous copy intact with no staging
  folder left behind, no copy has no record, the record names the drive, the
  index file list.

By hand: launch with the drive ejected (with and without a copy), eject
mid-session, force-unmount without ejecting, reconnect, try a rating, a crate
add and a tag save while disconnected, and confirm nothing new appears in
`Application Support/CrateDigger/Crates`.

## Out of scope

Editing offline and merging, deleting the old stand-in folder, greying out
menu items, network shares (bookmark resolution may try to mount one at
launch, unchanged), and carrying the CD Shelf's `CDShelf/` folder in the copy
(add it to `LibraryIndexFiles`' consumers when the shelf lands).
