# Album Version Groups ("Versions")

Date: 2026-06-26
Branch: main (feature branch to be created)

## Problem

The library has no concept of an album existing in more than one form. An album's
identity is the key `(album-artist, album-title, year)` — `OutputPathPlanner.albumFolderKey(for:)`,
consumed by `LibraryIndex.build(from:)`. Format and source are not part of that key, so a
user who keeps several pressings of the same record (e.g. Daft Punk — *Discovery* as MP3,
a Japanese FLAC, and an Apple Lossless CD rip) gets one of two bad outcomes:

- **Identical tags →** the three collapse into one *Discovery* album whose track list shows
  every song three times — looks like a duplicate-riddled album.
- **Differing year/title tags →** they split into separate, unlabelled *Discovery* rows by
  accident.

Worse, `LibraryCleanupService.findDuplicates` groups purely by `"artist - title"`, ignoring
album and format. It actively flags the FLAC/ALAC/MP3 copies of each song as duplicates and
nominates the others for the Trash — the app nudges the user to delete exactly the versions
they want to keep.

Users legitimately want to keep multiple pressings — CD, Vinyl, Gold CD, Remaster, Deluxe,
region imports — as distinct, organised entries.

## Goals

1. Let a user keep multiple **versions (pressings)** of one release as distinct entries,
   never flattened into a single track list.
2. Group them under a single **release** in the browser, shown as an expandable parent row
   with one sub-row per pressing (the "Option B" presentation).
3. Sort the release by a **canonical original release year** the user sets, independent of
   each pressing's tagged year (so a 1975 album sorts in 1975 even if the only pressings on
   disk are tagged 2011 and 2016).
4. Make duplicate-detection **version-aware** so it never proposes deleting across pressings
   of the same group.
5. Do all of this **non-destructively** — no retagging or moving the user's files.

## Non-goals (v1)

- **Automatic grouping.** Names like `Discovery - JP` or `Discovery 12" Vinyl`, and
  byte-different masterings with identical tags (Gold CD vs. CD), cannot be matched
  reliably. Grouping is **manual**. (A future, separate enhancement may *suggest* groups the
  user confirms — out of scope here.)
- Grouping non-local sources (Remote/Subsonic, CD, Playlist, Radio). **Local albums only.**
- A version *switcher* on a single collapsed row ("Option A"). The chosen presentation is
  the expandable group ("Option B"). The data model below is forward-compatible with adding
  a switcher later.

## Decisions (resolved during brainstorming)

- **Presentation:** Option B — expandable parent release row → pressing sub-rows.
- **Grouping is manual:** multi-select albums → right-click → **Group Albums**.
- **A group is a first-class object** carrying its own name, artist, original year, and a
  designated primary pressing.
- **Version labels:** auto-derived format/quality badge (`FLAC · 96 kHz`, `ALAC`, `MP3 · 320`)
  **plus** an editable free-text edition label (`Gold CD`, `JP Vinyl`, `2011 Remaster`),
  pre-seeded from the pressing's folder/album title.
- **Grouping flow:** a quick confirm **sheet** at group time to set name / original year /
  primary, all pre-filled — the natural place to capture the original year, which no file
  knows.
- **Crates store pressings, not groups:** adding a sub-row adds *that* pressing; adding the
  parent adds the *primary* pressing.
- **Storage is app-global** (`PreferencesStore`), like `StreamStore`.

## Current architecture (verified)

- `OutputPathPlanner.albumFolderKey(for:) -> AlbumFolderKey` (`artistBucket`, `album`,
  `year`) is the single grouping key; `LibraryIndex.build(from:)` buckets tracks by it and
  builds `Artist → Album → Track`. `Album.id = "<artistID>::<albumTitleID>::<year>"`.
- `Album` (Core, `Models/Album.swift`) is `Identifiable, Sendable, Equatable`; already
  carries `mediaFormat: MediaFormat?` (CD/Vinyl/Digital, from the folder `ArtworkManifest`).
- Per-track quality lives on `AudioTrack`: `formatName`, `bitrateKbps`, `sampleRateHz`.
- Multi-select already exists (`LibraryViewModel+MultiSelect.swift`):
  `selectedAlbumIDs: Set<String>`, `selectArtist/Album/Track`, `selectAllAlbums()`, etc.
  Album rows carry a right-click menu via `BrowserContextMenu.album(_:model:)`.
- The browser is custom rows (not SwiftUI `List`): `BrowserPane.swift` →
  `AlbumColumn`/`TrackColumn`, rows are `ColumnRow`. The Track column already renders an
  **expandable sub-row** pattern (`TrackListEntry.recordTrack` for Record Divider markers) —
  the disclosure precedent to reuse.
- Persistence precedent: `StreamStore` stores a small JSON blob in `PreferencesStore`
  (`prefs.streamSourcesData`). Sheets are AppKit `NSViewController`s presented via
  `presentAsSheet`, returning through an `onDecision` closure (e.g.
  `ConversionOptionsSheetController`).
- `LibraryCleanupService.findDuplicates(in:)` groups `allTracks` by lowercased
  `"artist - title"`; `isBetterTrack` ranks lossless > bitrate > sample-rate > size.

## Data model (Core)

### `AlbumGroup` (new, `Models/AlbumGroup.swift`)
`public struct AlbumGroup: Codable, Sendable, Hashable, Identifiable`:
- `id: String` — stable group id (UUID string, generated at creation).
- `name: String` — display title of the release (e.g. "Wish You Were Here").
- `artistID: String` — owning artist (groups never span artists in v1).
- `originalYear: Int?` — canonical sort year.
- `primaryRef: VersionRef` — which member is cover + default playback (matches one
  member's `ref`).
- `members: [VersionMember]` — the pressings, in user/display order.

`VersionMember`:
- `ref: VersionRef` — stable pointer to a pressing (see Identity).
- `editionLabel: String?` — user-editable edition ("Gold CD"); nil ⇒ show format only.

### Version identity (`VersionRef`)
A pressing is identified by its **`AlbumFolderKey`** (the existing grouping key). `VersionRef`
wraps the key's three components (`artistBucket`, `album`, `year`) so it is `Codable` and can
be persisted and matched back against a freshly-built index. `AlbumFolderKey` gains
`Codable` conformance (it is already `Hashable`).

Rationale: keying by the same identity the index uses keeps the join trivial and avoids a
parallel identity scheme. Trade-off recorded under Known limitations.

### `Album` additive fields (back-compatible, all optional)
`Album` gains:
- `versions: [Album]?` — `nil` for a plain album; for a **grouped release** it holds the
  member pressings (each a normal `Album`), ordered.
- `originalYear: Int?` — set on a grouped release; sorting uses `originalYear ?? year`.
- `editionLabel: String?` — set on a **member** pressing album; its edition text.
- `isVersionGroup: Bool { versions != nil }` (computed).

A grouped release's own `tracks` / `artworkHash` mirror the **primary** pressing, so existing
code that reads `album.tracks` (playback queue, inspector, crate add of the parent) keeps
working and resolves to the primary pressing.

## Persistence (`AlbumGroupStore`, new Core service)

- Mirrors `StreamStore`: `all() -> [AlbumGroup]`, `save(_: [AlbumGroup])`, backed by a new
  `PreferencesStore.albumGroupsData: Data?`. Corrupt/missing ⇒ empty.
- App-global (not per-crates-folder). Non-destructive: files are never touched.
- On load, the store is the source of truth; `LibraryIndex.build` consults it to fold groups.
- **Self-healing:** when folding, member refs that match no current album are dropped; a
  group left with < 2 live members is dissolved (its surviving member, if any, renders as a
  plain album). This keeps re-tag/rescan churn from leaving dangling groups.

## Library index integration

`LibraryIndex.build(from:)` gains a **post-pass** after albums are built:
1. Build plain albums exactly as today (keyed by `AlbumFolderKey`).
2. Load groups from `AlbumGroupStore`. For each group, collect the member albums by matching
   `VersionRef` → built album. Drop dead refs; skip groups with < 2 live members.
3. Replace those member albums in the artist's album list with one synthesised **release
   `Album`**: `versions = [members]`, `originalYear`, `name`, primary's tracks/art; carry each
   member's `editionLabel`.
4. Ungrouped albums are untouched.

`build` therefore needs access to the store. Inject it (`build(from:groups:)` with a default
of `AlbumGroupStore().all()`), so tests pass groups explicitly and Core stays pure.

`LibraryIndex.allAlbums` / `allTracks` semantics: `allTracks` stays the flat list of every
loaded track (unchanged — every pressing's tracks are real). `allAlbums` returns release
rows for grouped albums and plain rows otherwise; a helper `allVersionAlbums` flattens
releases back to pressings where needed (crate resolution, duplicate-finder).

## Browser UI (App, Option B)

- `AlbumColumn` renders a grouped release as a parent `ColumnRow` with a disclosure chevron
  and a "N versions" affordance; expanded, it lists member pressings as indented sub-rows,
  each showing the format/quality badge + edition label. Reuse the indentation/disclosure
  idiom from the Record Divider sub-tracks.
- Expansion state is view-local UI state keyed by group id (like `detailAlbumID` in the
  gallery), not persisted.
- Selecting a pressing sub-row sets the selected album to that pressing → Track column shows
  that pressing's tracks; the Inspector follows it. Selecting/activating the parent row uses
  the primary pressing.
- The **gallery** shows one cover per release (primary art) with a small "N versions" badge;
  opening it lists pressings. (Gallery parity can be a follow-up if it bloats v1 — see
  Phasing.)

### Format/quality badge derivation (Core helper)
A pure function `VersionLabel.formatBadge(for: Album) -> String` from the pressing's tracks
(`AudioTrack.formatName`, `sampleRateHz`, `bitrateKbps` — there is no bit-depth field):
lossless name + sample rate when available (`FLAC · 96 kHz`), else codec + bitrate
(`MP3 · 320`), plus `mediaFormat` when set (`· Vinyl`). Unit-tested.

## Grouping lifecycle (App)

`LibraryViewModel` owns an `AlbumGroupStore` and exposes:
- `canGroupSelection` — true when 2+ albums are selected within one artist and all local.
- `beginGroupAlbums()` — opens the confirm sheet pre-filled (name = shared/longest-common
  title; originalYear = min member year; primary = lossless-best member).
- `commitGroup(name:originalYear:primaryRef:editions:)` — writes the group, reloads index.
- `ungroup(_ release: Album)` and `editGroup(_ release: Album)` (reopens the sheet).
- `addToGroup(_ albums:)` / `removeFromGroup(_ pressing:)`.

`BrowserContextMenu`:
- **album menu** gains **Group Albums** (when `canGroupSelection`), shown as
  "Group N Albums…".
- **release parent** menu: **Edit Group…**, **Ungroup**, plus Add-to-Crate (primary) and
  Select All.
- **pressing sub-row** menu: per-pressing Add-to-Crate (that pressing), **Set as Primary**,
  **Edit Edition Label…**, **Remove from Group**, plus the usual track/album removal items.

`GroupAlbumsSheetController` (new AppKit sheet, `UI/Carbon/Sheets/`): fields for group name,
original year, a primary picker, and an editable edition label per member. Returns via
`onDecision`. Styled like existing Carbon sheets.

## Sorting

`LibraryIndex.sortedAlbums(..., by: .year, ...)` uses each album's **effective year** =
`originalYear ?? year`. Grouped releases therefore slot into the year ordering by their
canonical original year; ungrouped albums are unchanged. Within a release, members sort by
pressing year ascending, lossless first as tiebreak.

## Playback

- Activating a pressing sub-row plays that pressing (existing `playTrack` + `currentAlbumQueue`
  off the now-selected pressing).
- Activating the parent release plays the **primary** pressing.

## Crates interaction

- Drag/add of a **pressing** sub-row adds that pressing's tracks (`track::` items, unchanged).
- Drag/add of a **release** parent adds the **primary** pressing's tracks.
- Crates are unaware of groups — they store concrete track paths, so existing `.cdlib`
  behavior, path-rewrite-on-move, and removal all keep working.

## Duplicate-finder safety

`findDuplicates(in:)` becomes version-aware: two tracks are never grouped as duplicates when
their pressings belong to **different members of the same `AlbumGroup`**. Implementation:
build a `trackPath → groupID` map from grouped releases; when bucketing by `"artist - title"`,
split each bucket by group membership so cross-pressing copies don't collide. Real duplicates
*within* one pressing still surface. Add tests for: grouped versions excluded; true dupes
inside one pressing still found; ungrouped near-dupes still found.

## Architecture / file map

Core (unit-tested):
- `Models/AlbumGroup.swift` — `AlbumGroup`, `VersionMember`, `VersionRef`.
- `Models/Album.swift` — additive optional fields.
- `Services/OutputPathPlanner.swift` — `AlbumFolderKey: Codable`.
- `Services/AlbumGroupStore.swift` — persistence.
- `Services/LibraryIndex.swift` — group-folding post-pass; effective-year sort.
- `Services/VersionLabel.swift` — format/quality badge derivation.
- `Services/LibraryCleanupService.swift` — version-aware duplicate finder.
- `Services/PreferencesStore.swift` — `albumGroupsData`.

App:
- `LibraryViewModel` (+ a new `LibraryViewModel+Versions.swift` extension) — store ownership
  and grouping actions.
- `UI/Carbon/Sheets/GroupAlbumsSheetController.swift` — confirm/edit sheet.
- `UI/Carbon/Main/Browser/BrowserPane.swift` — release/parent + sub-row rendering.
- `UI/Carbon/Main/Browser/BrowserContextMenu.swift` — Group/Ungroup/Edit/primary items.

## Testing strategy

Core gets the coverage (the App/UI layer stays manually verified per project norms):
- `AlbumGroupStoreTests` — round-trip, corrupt data ⇒ empty, empty ⇒ nil.
- `LibraryIndexTests` (extend) — folding builds a release with N versions; dead-ref pruning;
  < 2 live members dissolves; effective-year sort places a release by original year;
  ungrouped albums unaffected.
- `VersionLabelTests` — badge strings for FLAC · 96 kHz, ALAC, MP3 · 320, + mediaFormat suffix.
- `LibraryCleanupServiceTests` (extend) — grouped versions excluded from duplicates; intra-
  pressing dupes still found; ungrouped near-dupes still found.

## Scope & phasing

- **Phase 1 (this spec):** data model, `AlbumGroupStore`, index folding, manual
  Group/Ungroup/Edit + sheet, Option B browser rendering, version labels, original-year sort,
  version-aware duplicate finder, crate behavior. Core fully tested.
- **Phase 2 (later, not now):** gallery parity for releases; confirm-able auto-suggested
  groups; Option A inline switcher on the collapsed row.

## Known limitations / edge cases

- **Re-tagging detaches a pressing.** Identity is `AlbumFolderKey` (artist/title/year); if the
  user changes a grouped pressing's album title or year, its ref no longer matches and the
  store self-heals by dropping it (re-add via *Add to Group*). Acceptable for v1; a more
  durable per-folder identity is a possible later hardening.
- **Single artist per group** in v1 (no "Various Artists" cross-artist releases).
- **A group needs ≥ 2 live members**; otherwise it dissolves to a plain album.
- Grouped releases are **local-only**; mixing in a Remote/CD pressing is out of scope.
