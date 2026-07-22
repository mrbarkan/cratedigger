# Artwork inspector & gallery: fixes and batch cover search

**Status:** approved design, not yet planned
**Target:** `beta/1.1.0-theming` (build bump); a subset cherry-picked to `main` for 1.0.3

Six items from a UI pass over the ART inspector tab and the gallery browser.
Three are root-cause repairs to things that already half-exist; three are new
affordances. Grouped here because they touch the same two files.

## Item 1 — Device-safe toggle moves onto SAVE

### Problem

`ArtworkInspectorView.swift:98-109` renders a checkbox row for
`@AppStorage("embedDeviceCompatibleArt")`. It is a **global** preference
(plain `UserDefaults`, not `PreferencesStore`) sitting in a per-album
inspector, reading as if it were album state. It costs a full row in a
cramped pane, and its only effect is on one step of a *different* control's
action.

Its consumers are exhaustively three lines, all in that one file:
declaration (`:18`), the `Toggle` (`:99`), and the `deviceCompatible:`
argument to `embedCoverIntoTracksInBackground` (`:324`). Downstream it is
read only at `LibraryViewModel.swift:2098`.

### Design

Delete the row. SAVE becomes a menu-with-primary-action:

```swift
Menu {
    Toggle("Device-safe artwork (600px baseline JPEG)", isOn: $deviceCompatibleArt)
} primaryAction: {
    saveChanges()
}
```

Click saves; the chevron reveals the toggle. The setting sits adjacent to the
only action it modifies. The `@AppStorage` key is unchanged, so an existing
user's choice carries across the upgrade untouched.

**Implementation risk:** `KeyButton` is a bespoke Carbon control and `Menu`
may not accept its styling cleanly. Fallback: a chevron hit-zone inside the
existing `KeyButton` that presents an `NSMenu`. If neither reads well, report
back rather than shipping a control that fights the chassis.

Rejected: Preferences → Artwork (correct home for a global, but strands the
setting three windows away from the button it governs); the Search Album
Artwork sheet (that sheet never embeds anything — the toggle would have no
effect from there).

## Item 2 — SAVE: say what it does, and fix three bugs

### What it currently does

`saveChanges()` (`ArtworkInspectorView.swift:306-331`):

1. `try? manifest.save(to: albumFolder)` — writes `.cratedigger-art.json`.
2. `model.refreshLibrary()`.
3. `model.embedCoverIntoTracksInBackground(for:deviceCompatible:)` — rewrites
   **every track file on the album** to embed the cover.
4. `appAlert = .info(title: "Artwork saved", …)`.

Adding artwork already writes `cover.jpg` and the manifest immediately
(`attachLocalArtwork` / `downloadAndImportArtwork` → `applyImportedArtwork`),
which is why the cover appears before you press anything. So SAVE means
"persist my role/format edits **and** bake the cover into the audio files."
That second half is invisible in the UI.

### Design

Add `.help("Saves artwork roles and format, and embeds the cover into every
track on the album.")` to the SAVE control.

Then three genuine bugs on this path:

**2.1 — Stale disk cache.** `saveChanges` calls `refreshLibrary()`, which
rebuilds indexes but never invalidates `indexDiskCache` for the edited
folder. `applyImportedArtwork` (`LibraryViewModel.swift:2133-2136`) *does*
invalidate, and is the correct template. Consequence: the rebuild reuses
stale per-folder booklet/`mediaFormat` info for the folder just edited — so
a FORMAT change from Auto to Vinyl can fail to take until a full rescan.
Fix: invalidate the album folder in `saveChanges` before `refreshLibrary()`.

**2.2 — Silent write failure.** `try? manifest.save(to:)` (`:314`) swallows
the error, then `:325` reports "Artwork saved" unconditionally. A read-only
or full volume reports success and loses the edit. Violates *Fail Fast &
Loud*. Fix: `do/catch`, surface `appAlert = .error` naming the folder, and
leave `isDirty` **true** so the edit is not silently discarded.

**2.3 — Non-deterministic cover pick.** `embedCoverIntoTracksInBackground`
(`LibraryViewModel.swift:2080`) selects the cover with
`manifest.roles.first(where: { $0.value == .cover })?.key` — `roles` is a
`[String: ArtworkRole]` **dictionary**, so with two `.cover`-roled files
which one gets embedded varies between runs. Fix: sort the matching filenames
by `localizedStandardCompare` and take the first. Every candidate is already
`.cover`-roled, so Item 2a's role ordering is irrelevant among them — which
keeps this fix independent of 2a, and that matters: 2.3 ships to 1.0.3 and
2a does not.

## Item 2a — Role ordering in the ART grid

### Problem

The grid does not sort by role at all — `loadManifest()`
(`ArtworkInspectorView.swift:303`) sorts by raw `lastPathComponent` ASCII
compare, so `back.jpg` precedes `cover.jpg` (visible in the screenshot that
opened this). The role `Picker`'s own menu order (`:146-153`) is a third
arbitrary order matching neither the grid nor `ArtworkRole.allCases`.

### Design

Add a `sortOrder: Int` to `ArtworkRole` in
`Sources/CrateDiggerCore/Models/ArtworkManifest.swift`:

```
Main Cover → Alt Cover → Back → Disc/Vinyl → Inlay → Booklet Page → Auto → Ignore
```

Unclassified (`.auto`) and hidden (`.ignore`) sink to the bottom, where they
read as "needs attention". The grid sorts by `(role.sortOrder, filename via
localizedStandardCompare)` — the localized compare so `booklet_2` precedes
`booklet_10`. The `Picker` menu is reordered to match, so the list you pick
from and the grid you look at agree.

**`AlbumArtCatalog.pages` is deliberately not touched.** It has its own order
(Cover → Alt → Booklet → Inlay → Tray → Disc → Back) because it drives the
booklet *reader* — a reading flow, not an editing grid. Two orders is correct
here; unifying them would break page navigation to satisfy a symmetry nobody
asked for.

### Testing (Core, XCTest)

Roles shuffled → sorted → assert the exact expected sequence, including
`booklet_2` before `booklet_10`.

## Item 2b — Remove artwork

### Problem

No delete path exists anywhere — no UI, no method, no `removeItem`/
`trashItem` for artwork files. `ArtworkRole.ignore` is the only "hide it"
mechanism and it only affects `AlbumArtCatalog` classification; the grid
still lists ignored files forever.

### Design

A ✕ badge on thumbnail hover. On click:

1. Confirmation alert naming the file (`Remove "back.jpg"?` / "The file moves
   to the Trash.").
2. Hash the file bytes (needed for step 5), then `FileManager.trashItem` —
   **not** `removeItem`. Recoverable; deleting someone's scanned booklet with
   no undo earns a bug report.
3. Drop the filename's entries from all three manifest maps — `roles`,
   `discSides`, `discNumbers` — else orphans accumulate.
4. Save the manifest (with 2.2's real error handling).
5. `ArtworkStore.remove(hash:)` — **new**, a one-liner deleting
   `Thumbnails/<hash>`. The store currently has only `clear()`.
6. Invalidate `indexDiskCache` for the folder; reload the grid.

**Deliberately skipped:** per-key eviction from `ArtworkService.thumbnailCache`
and `dataCache`. Those are `NSCache`s keyed `hash-WxH` / `hash-tN` and NSCache
cannot enumerate keys, so per-key eviction means tracking keys by hand. Once
the cover is gone the index rebuild clears the album's `artworkHash`, so
nothing references the entry — it is dead weight in a cache that already
evicts under pressure. This matches the approved thumbnail-cache spec:
"No reference-counting GC — thumbs are small enough that stale ones don't
matter."

**Known sharp edge (not fixed here):** the grid's folder scan
(`ArtworkInspectorView.swift:288`) covers a *narrower* directory set than
`AlbumArtCatalog.gatherImageURLs`, so a file visible to the viewer may be
invisible to the grid and therefore un-deletable. Out of scope; noted because
it will look like a delete bug when someone hits it.

## Item 3 — Gallery selection highlight

### Problem — the real one

`EmptyMediaCase.swift:21` gives the jewel case an aspect ratio of
`1 + spineFraction` = **1.13:1** — the hinge spine adds width outside the
square lid, faithful to the real object. `GalleryAlbumCoverView` then forces
it into `.frame(width: 120, height: 120).clipped()`
(`ArtworkGalleryView.swift:607`). A 1.13:1 box `.fit` into a 120×120 slot
renders **120 × 106**, centred — leaving ~7pt of dead space above and below.

The highlight (`:161-169`) is a `RoundedRectangle(cornerRadius: 4)` stroked
on the *tile* bounds. Real covers are square and fill the tile, so the frame
hugs them. Empty boxes do not, so the frame floats off the artwork. The
highlight was never mismatched — the box is letterboxed inside it.

### Design

Replace the selected frame + orange glow with an **orange underline** between
tile and title, retaining the glow for the neon read. The 1pt hairline border
(`Color.black.opacity(0.12)`) stays on all tiles — it defines cover edges
against the dark chassis and is not part of the selection language.

An underline never has to hug the art, so the geometry problem stops
mattering.

**Accepted residual:** the letterbox itself remains. Empty boxes will sit ~7pt
above their underline while real covers sit flush. Underlines still align
across a row, which is the dominant read. Squaring the box is a one-line
change to `EmptyMediaCase.swift:21` if the gap proves visible in use —
deliberately deferred until seen on screen rather than fixed on spec.

The tile must render `model.isAlbumSelected(album.id)`, not
`model.selectedAlbumID` — see Item 5.

## Item 4 — Playing Now

### Design

A footer-transport button plus **View → "Go to Current Song" ⌘L** (the
shortcut Music.app uses for exactly this, so it is muscle memory for free).
Gated in `validateMenuItem` on `nowPlayingTrack != nil`.

New `LibraryViewModel.revealNowPlaying()`:

1. `nowPlayingTrack` (`LibraryViewModel.swift:920`) → `album(containing:)`
   (`:927`).
2. Set `selectedArtistID` / `selectedAlbumID` / `selectedTrackID`; clear the
   multi-select sets so the reveal is an unambiguous single selection.
3. **No-op if the album is not in the current source's index.** The playing
   track may live in another crate; silently switching sources under the user
   is worse than doing nothing.

The Inspector follows `selectedAlbum` already. The browser list already
scroll-targets via `ColumnList`'s `scrollTarget`. The **gallery does not**:
its `proxy.scrollTo` is inside `.onAppear` only (`ArtworkGalleryView.swift:52-56`),
so once the grid is on screen no selection change ever scrolls it. Add the
`.onChange(of: model.selectedAlbumID)` pattern `ColumnList.swift:51-63`
already uses. This same fix is what makes Item 5's arrow nav scroll.

`album(containing:)` is a linear scan over every artist × album. It is
already shared by the spinning disc and mini player, and this fires on a
keypress, not per frame — reused as-is.

## Item 5 — Gallery keyboard navigation and ⌘A

### Problem — four root causes, not four missing features

1. `ArtworkGalleryView.swift:83-86` defines a local `selectAlbum(_:)` that
   **shadows** the model's modifier-aware
   `selectAlbum(_:command:shift:ordered:flat:)`. It sets only the anchor,
   never touches `selectedAlbumIDs`, and never clears the other sets. So
   ⌘-click and ⇧-click do nothing in the gallery today.
2. The tile renders `model.selectedAlbumID == album.id` (`:157`), ignoring
   `selectedAlbumIDs` / `isAlbumSelected`. **Multi-selection is already
   invisible in the gallery** — and its context menu already offers
   "Select All" (`selectAllAlbums()`), setting state the gallery never draws.
3. `selectAllInSource()` (`LibraryViewModel+MultiSelect.swift:97-102`)
   switches on `browserLayout`. Gallery is an orthogonal *bool*
   (`showArtworkGallery`), not a `BrowserLayout` case, so ⌘A in gallery mode
   selects whatever the hidden list browser was showing.
4. `handleBrowserArrowNav` (`LibraryViewModel+ArrowNav.swift:31`) is
   column-based and gallery-unaware. No row-wise movement exists anywhere.

### Design

1. Delete the local `selectAlbum`; call
   `model.selectAlbum(album, command:shift:ordered: allAlbums, flat: true)`.
2. Tile renders `model.isAlbumSelected(album.id)`.
3. `selectAllInSource()` checks `showArtworkGallery` first → `selectAllAlbums()`.
   ⌘A is otherwise already wired: `AppDelegate.swift:491` →
   `CarbonHostingController.selectAll` (`:22-24`) → `selectAllInSource()`.
4. A gallery branch at the top of `handleBrowserArrowNav`, when
   `showArtworkGallery`: ←/→ = ±1, ↑/↓ = ±`columnsPerRow` over
   `allAlbumsSorted`, clamped to bounds. Existing guards hold — bare arrows
   only, `isBrowserKeyContext()` only.

**Column count.** The grid is `.adaptive(minimum: 120, maximum: 160)`, which
resolves at layout time and never reports `n`. Rather than re-deriving
SwiftUI's floor math and hoping it stays in sync, own it: `GeometryReader` →
compute `n` → `n × GridItem(.flexible(), spacing: 18)`, publishing `n` to the
view model. If we need to know `n`, we should be the ones deciding it. Cells
keep their fixed `.frame(width: 120)` and centre within flexible columns.

Not in scope: ⇧-arrow to extend selection (the nav guard rejects all
modifiers by design), Return-to-open.

## Item 5b — Search and Add Album Covers

### Problem

For users who want covers everywhere without curating each one: select albums
with no art, have the app pick the best match and write a device-ready cover.
Detailed manual search stays available afterwards.

### What already exists

- `RemoteArtworkService.fetchArtwork(artist:album:)` (`:51`) — iTunes album
  search, Levenshtein scoring weighted **2× on album title**, 1200px upgrade,
  disk-cached. This *is* the "best match according to metadata" matcher.
- `LibraryViewModel.fetchRemoteArtwork(for:)` (`:1862`) — per-album wrapper
  with `albumsFetchingArtwork` progress state, and **zero callers**. Dead code.
- `ArtworkService.prepareCompatibleArtwork(asset:profile:maxDimension:)` (`:195`).
- `albumsFetchingArtwork` / `isFetchingArtwork` (`:296`, `:1858`) — no UI
  consumer yet.

iTunes is chosen over MusicBrainz/CAA: it is digital-media by nature (which is
what "format digital media" asks for), single-hop, not rate-limited the way
MusicBrainz is, and the scorer already exists and is tuned.

### Design

Context menu on gallery selection → "Search & Add Covers". New
`LibraryViewModel.searchAndAddCovers(for albums: [Album])`:

1. **Filter to albums with no art**: `artworkHash == nil &&
   booklet?.frontCoverURL == nil` (the same predicate
   `GalleryAlbumCoverView.loadKey` uses to decide it has nothing to draw).
   Albums that already have a cover are skipped silently — a careless ⌘A must
   never overwrite curated art.
2. Per album, max 4 concurrent (matching the embed path's cap):
   `fetchArtwork` → `prepareCompatibleArtwork(profile: .generic,
   maxDimension: 600)` → write `cover.jpg` to the album folder → set
   `manifest.roles["cover.jpg"] = .cover` → save manifest.
   600px on the longest edge, so the result is device-ready as written.
3. Progress: insert/remove `albumsFetchingArtwork` per album; the gallery tile
   gains a spinner overlay driven by `isFetchingArtwork` (its first consumer).
4. **Rebuild indexes once, at the end** — not per album.
   `applyImportedArtwork` rebuilds all three indexes (`localIndex`,
   `prepCrateTracks`, `index`) on every call; doing that 100× on the main
   actor would freeze the app at 14k tracks. Batch accumulates assets and
   applies one rebuild. This is the perf-critical part of the item.
5. Report: `appAlert = .info("Added 12 covers", "6 albums had no match.")`.

Writing `cover.jpg` to the folder — rather than `applyFetchedArtwork`'s
in-memory-only `.remote` hash — is deliberate: the approved artwork spec
requires art to live next to the music so deleting an album folder deletes
everything real.

**Version groups.** `Album.versions` is non-nil for grouped releases, whose
member pressings each have their own folder. Batch recurses into `versions`
when present, else treats the album as its own folder. A group's own id has
no folder to write to.

**Scout-rule deletion:** remove `fetchRemoteArtwork` — dead code this
supersedes. `albumsFetchingArtwork` / `isFetchingArtwork` are kept and finally
get a consumer.

Not consolidated here: `ArtworkGalleryView.swift:510-548` hand-rolls a *third*
iTunes search for its manual per-album picker. It is a different interaction
(user picks from candidates) and works. Noted as debt, not touched.

## Error handling

- Manifest write failure: alert naming the folder, `isDirty` stays true (2.2).
- `trashItem` failure: alert, manifest untouched, grid unchanged.
- Batch cover fetch: per-album failures are counted, never alerted
  individually — one alert at the end. A no-match is an expected outcome, not
  an error.
- `revealNowPlaying` with the album outside the current source: no-op.

## Testing

**Core (XCTest):**
- `ArtworkRole` sort order, including `booklet_2` before `booklet_10`.
- `ArtworkStore.remove(hash:)`: put → remove → `data(for:)` returns nil;
  removing an absent hash does not throw.

**Not unit-tested** (`LibraryViewModel` / SwiftUI, untestable per the existing
architecture): the SAVE menu, underline, arrow nav, reveal, batch orchestration.
These need GUI verification — see below.

## GUI verification checklist

1. ART tab: SAVE menu holds the toggle; the checkbox row is gone; setting persists.
2. Grid order: Main Cover first, then Back, Disc, booklets.
3. ✕ on a thumbnail → confirm → file in Trash, gone from grid, manifest clean.
4. Gallery: orange underline on selected; empty boxes and real covers agree.
5. ⌘A selects all albums and **every** tile shows it.
6. Arrows move by 1 horizontally, by a row vertically; the grid scrolls to follow.
7. ⌘L and the footer button jump to the playing album in both panes.
8. Select several coverless albums → Search & Add Covers → spinners, then covers;
   already-covered albums in the selection are untouched.

## Release plan

Work lands on `beta/1.1.0-theming`; version stays 1.1.0, build bumps.

Proposed 1.0.3 cherry-picks — genuine fixes only:

- Item 2.1, 2.2, 2.3 (SAVE bugs)
- Item 3 (gallery highlight)
- Item 5 causes 1–3 (multi-select invisible, ⌘A)

Beta-only (features, not fixes): Items 1, 2a, 2b, 4, 5 cause 4 (arrow nav), 5b.

## Out of scope

- Unifying `AlbumArtCatalog.pages` ordering with the grid (different jobs).
- Reconciling the grid's folder scan with `AlbumArtCatalog.gatherImageURLs`.
- Consolidating the third inline iTunes search in `ArtworkGalleryView`.
- Squaring `EmptyMediaCase` (deferred pending Item 3 on screen).
- Per-key `NSCache` eviction for removed artwork.
- ⇧-arrow range selection in the gallery.
