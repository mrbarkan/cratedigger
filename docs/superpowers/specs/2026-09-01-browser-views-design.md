# Browser views: any category in any column — Design

**Date:** 2026-09-01
**Branch:** v2 (beta line)
**Scope:** the browser's three fixed layouts become per-source views of one
to three columns, each showing any category, cascading left to right.

---

## Why this exists

The browser is hard-wired to the index tree. `BrowserLayout` is three cases
(`Artist · Album · Track`, `Album · Track`, `Track`), all subsets of
Artist → Album → Track in that order; `BrowserState` has three named
selection slots; `BrowserPane` has three typed panes. One saved layout
serves every crate and one serves every playlist.

The ask: 1-, 2- and 3-column views, every column showing whichever category
the user picks (Artist, Album Artist, Album, Genre, Year, Decade, Format,
Rating, Track), a view can end on an album or an artist rather than a track
list, and each crate opens in its own view.

### What the survey found

**Every facet is already in the data.** `AudioTrack` carries artist, album,
year and format; `ConversionMetadata` carries album artist and genre;
`ListeningStats` carries rating. Nothing new is read from disk.

**The index does not need to change.** A column showing genres is a grouping
of the tracks that survive the columns to its left. Artist and Album columns
are the same grouping, resolved back to the index's real `Artist`/`Album`
objects so rows keep their art, version groups and booklets. The tree stays
Artist → Album → Track and is used as a lookup, not as the shape of the
browser.

**Selection has ~120 call sites across 11 files**, nearly all through the
three named APIs (`selectedArtistID`, `selectedAlbumIDs`, `selectArtist`…).
`browserLayout` has 16 across 5. The design keeps every one of those names
working as a forward over the generic state, the way Phase 0 kept the
`@Published` names when the state moved to Core.

**"What the selection means" is already funnelled.** `selectedTracksForCrateAdd()`
and `resolvedSelectionTracks()` are what every batch action reads. Redefining
those two over the cascade is what keeps add-to-crate, convert, tag, rate and
transfer working without a per-feature audit.

## Non-goals

- No column widths, no drag-to-reorder columns, no per-column row styles
  beyond the three that exist plus one plain row.
- No named, saved presets. A crate has its view; that is the whole model.
- No listening facets beyond rating (play count, last played buckets):
  Phase 2's smart crates own listening rules.
- No custom-tag facets, no composer, no label.
- No change to `LibraryIndex.build`, to `TrackStore`, or to what a crate is.

---

## Part A: the model

### A1. Facets

```swift
/// A category a browser column can show.
public enum BrowserFacet: String, Codable, CaseIterable, Sendable {
    case artist, albumArtist, album, genre, year, decade, format, rating, track
}
```

Each facet knows how to key and title a track. Keys are what selection and
persistence store; titles are what rows draw.

| Facet | Key | Title | Source |
|---|---|---|---|
| artist | `Artist.id` | `Artist.name` | the index artist containing the track |
| albumArtist | folded name | tag, blank → `Unknown Album Artist` | `metadata.albumArtist ?? track.artist` |
| album | `Album.id` | `Album.title` | the index album (top-level or version) containing the track |
| genre | folded tag | tag, blank → `No Genre` | `metadata.genre` |
| year | `"1977"` | `1977`, missing → `Unknown Year` | `track.year` |
| decade | `"1970"` | `1970s`, missing → `Unknown Decade` | `track.year / 10 * 10` |
| format | folded name | `FLAC`, `DSD64` | `track.formatName ?? pathExtension.uppercased()` |
| rating | `"0"`…`"5"` | `★★★★☆`, 0 → `Unrated` | `ListeningStats.rating`, missing → 0 |
| track | `track.id.uuidString` | `track.title` | the track |

Folding is `BrowserFilter`'s: case- and diacritic-insensitive, so "rock" and
"Rock" are one row.

Rating comes from outside the index. The cascade takes a `FacetContext`
carrying `ratingByPath: [String: Int]`; the view model fills it from
`ListeningStore`. Everything else reads the track.

### A2. Views

```swift
/// One to three facets, left to right.
public struct BrowserView: Codable, Equatable, Sendable {
    public var facets: [BrowserFacet]
    public init(_ facets: [BrowserFacet])
    /// Nil when valid, else why not.
    public var problem: Problem?
    public enum Problem: Equatable { case empty, tooWide, duplicate(BrowserFacet), trackNotLast }
    public static let classic = BrowserView([.artist, .album, .track])
    public static let table = BrowserView([.track])
    /// What `BrowserLayout` used to mean.
    public init(legacy: BrowserLayout)
}
```

Three rules, no more: one to three facets, no facet twice, and Track only
last (nothing cascades out of a track). `BrowserLayout` stays in Core only
as the decoder for the two legacy preference keys (D3); nothing new reads it.

### A3. Column content

```swift
public struct FacetValue: Identifiable, Equatable, Sendable {
    public let id: String       // the facet key
    public let title: String
    public let count: Int       // tracks under it, after the cascade
}

public enum ColumnContent: Equatable, Sendable {
    case artists([Artist])
    case albums([Album])
    case tracks([LoadedTrack])
    case values([FacetValue])
    public var ids: [String]    // in display order, for shift-ranges and arrows
}
```

---

## Part B: the cascade

### B1. Population

```swift
public enum BrowserCascade {
    /// One `ColumnContent` per facet in the view. Column k shows facet k's
    /// values among the tracks surviving columns 0..<k.
    public static func columns(view: BrowserView,
                               in index: LibraryIndex,
                               selection: BrowserState,
                               sorts: BrowserSorts,
                               context: FacetContext) -> [ColumnContent]

    /// The tracks that survive every column's anchor, with the multi-selection
    /// applied in the column that owns one. This is what "the selection"
    /// resolves to (see C3).
    public static func selectedTracks(view: BrowserView,
                                      in index: LibraryIndex,
                                      selection: BrowserState,
                                      context: FacetContext) -> [LoadedTrack]
}

/// The four sort pairs the cascade orders columns by: the three that exist
/// today plus one for value columns.
public struct BrowserSorts: Equatable, Sendable {
    public var artist: BrowserSort<ArtistSortField>
    public var album: BrowserSort<AlbumSortField>
    public var track: BrowserSort<TrackSortField>
    public var value: BrowserSort<ValueSortField>     // .title | .count
}
```

Rules:

1. Column 0's population is `index.allTracks` (the browsed index, so search
   applies for free).
2. Column *k*'s population is column *k−1*'s population narrowed to the
   tracks whose facet-(k−1) key is in column *k−1*'s **effective selection**:
   the multi-selection set if that column owns one, else its anchor, else
   (no anchor) nothing narrows. A column with nothing selected passes
   everything through, so a fresh view is never empty.

   One exception, for version groups. An **Album** column narrows by
   containment, not key equality: a track survives if
   `index.albumOrVersion(id:)` for any selected id contains it. A track's
   own album *key* (what `reveal` and the row's identity use) is its
   top-level album; a version member's row has the member's id, and
   selecting it narrows to that pressing alone. Without this a member row
   could never be the selection, which is the version-group feature.
3. An **Artist** or **Album** column resolves its population to index objects:
   every `Artist` (or top-level `Album`, or version member for a member hit)
   that contains at least one surviving track, in index order, then sorted
   by the artist/album sort pair. The objects are the index's own, whole:
   an album row is the album, whatever survived inside it.
4. A **Track** column is the surviving tracks, sorted by the track sort pair.
   With an Album column immediately to its left, disc headers apply as today.
5. A **value** column is the distinct keys with counts, sorted by the value
   sort pair (title or count).

So `Genre: Rock · Album: X · Track` lists only X's rock tracks. That is the
cascade meaning, and it is what makes `Genre · Track` a useful view.

### B2. Cost and caching

One pass over the surviving population per column. A click in column *k*
recomputes columns `> k` only; a sort change recomputes its column only; a
`browsedIndex` change recomputes everything. Cached in the view model as
`browserColumns: [ColumnContent]`, the way `visibleArtists` is cached today
and for the same reason (the spinning-disc animation must not re-derive).

---

## Part C: selection

### C1. State

`BrowserState` generalizes. The three anchors and three sets become:

```swift
public var anchors: [String?]            // one per column, keyed by facet key
public var multiSelection: MultiSelection?   // at most one column owns a set
public struct MultiSelection: Equatable, Sendable {
    public var column: Int
    public var ids: Set<String>
}
```

The invariant is unchanged and now stated once: you are picking things in
one column, never a mixture. The old names are computed forwards:

- `selectedArtistID` reads the anchor of the Artist column if the view has
  one, else the artist of the anchored album or track. Its setter writes the
  Artist column's anchor when there is one and is otherwise a no-op with a
  debug assertion, so a stale caller is found in development rather than
  silently ignored.
- `selectedArtistIDs` is `multiSelection.ids` when the owning column's facet
  is `.artist`, else empty. Same for albums and tracks.
- `focusedColumn` becomes `Int`; `BrowserColumn` goes. The three App-side
  readers (`+ArrowNav`, `BrowserPane`, the view model) move to indices.

### C2. Clicks

`select(column: Int, id: String, command: Bool, shift: Bool, ordered: [String])`
replaces the three typed methods; they stay as forwards that find their
column by facet. Rules, all as today per column:

- plain click: anchor = id, `multiSelection = (column, [id])`;
- ⌘-click: toggle id in the set (moving the set to this column if it was
  elsewhere), anchor = id;
- ⇧-click: range from the anchor over `ordered`;
- any click in column *k* re-derives every anchor to its right: each moves
  to the first row of its new population, so the leaf always shows something.

`reveal(track:in:view:)` is the outside-in click: it sets **every** column's
anchor from the track's facet keys. It is what "Go to Current Song", the
gallery and the condensed browser use, replacing today's `revealAlbum`
and the `flat:` parameter (which existed to set an artist anchor no column
had set).

`selectAll(column:)` selects the column's whole population.

`reanchor(in:)` keeps its contract: every anchor onto something its column
contains, the set cleared.

### C3. What the selection means

One definition, in Core, replacing the three-branch resolver:

> The selection is the tracks surviving the whole cascade with the
> multi-selection applied. A single click resolves to the leaf's anchored
> item's tracks: a track to itself, an album to its surviving tracks, a genre
> to its tracks.

`selectedTracksForCrateAdd()` and `resolvedSelectionTracks()` become one-line
forwards. The single-selection subtlety survives: `resolvedSelectionTracks()`
still returns the one anchored track when the leaf is a Track column and
nothing is multi-selected, so rating one track does not rate the album.

**`browsingTracks`** (what playback starts from) becomes: the Track column's
content if the view has one, else the selection's tracks. Double-clicking an
album in `Artist · Album` plays the album.

---

## Part D: the view model

### D1. State

- `browserView: BrowserView`, published, replacing `browserLayout`. Setter
  validates (a bad view is a programmer error, asserted) and recomputes.
- `browserColumns: [ColumnContent]`, cached (B2).
- `focusedColumn: Int`.
- Sorts: the three existing pairs plus `valueSort: BrowserSort<ValueSortField>`
  (`.title`, `.count`), persisted like the others.

### D2. Compat surface

Redefined over the cascade, so nothing outside the browser moves:

| Name | Meaning now |
|---|---|
| `visibleArtists` | the Artist column's content, else the artists of `browsedIndex` |
| `visibleAlbums` | the Album column's content, else the anchored artist's albums |
| `visibleTracks` | the Track column's content, else the selection's tracks |
| `allAlbumsSorted` | unchanged: every album in `browsedIndex`, sorted (the gallery) |
| `flatTracks` | the Track column's content when the view is `[track]` |
| `browsingTracks` | C3 |
| `selectedArtist` / `selectedAlbum` / `selectedTrack` | resolved from anchors as in C1 |

`syncAlbumSelectionToTrack` goes: `selectedAlbum` derives from the anchored
track by definition when there is no Album column.

### D3. Per-source views

```swift
extension LibrarySource {
    /// Stable across launches: "all", "prep", "crate:<name>", "playlist:<name>",
    /// "cd:<path>", "device:<path>", "offline:<uuid>", "remote", "radio".
    var persistenceKey: String
}
```

`PreferencesStore.savedBrowserViews: [String: BrowserView]` (a JSON blob, the
`CustomEQPreset` pattern). `selectSource` reads the source's view; setting
`browserView` writes it under the current key.

The fallback *is* the migration, so there is no seeding pass and no
enumeration of crates: a key with no saved view falls back to the legacy
layout converted (`savedPlaylistBrowserLayout` for a playlist,
`savedBrowserLayout` otherwise), and only if that is unset too to `.table`
for a playlist and `.classic` for everything else. A user who had set
`Album · Track` sees `Album · Track` in every crate until they change one,
which is exactly what they had.

Radio has no browser and stores nothing.

### D4. Keyboard

`navColumns` is `0..<browserView.facets.count`. ←/→ move focus, ↑/↓ move the
focused column's anchor through its content's `ids`. `moveGallerySelection`
is unchanged.

---

## Part E: UI

### E1. Panes

`BrowserPane` renders `ForEach(browserView.facets.indices)`:

- `.artist` → `ArtistPane(column:)`, `.album` → `AlbumPane(column:)`,
  `.track` → `TrackPane(column:)`. Existing rows, art, version-group
  disclosure, disc headers, drag payloads and context menus, now reading
  `browserColumns[column]` instead of `visibleAlbums` / `flat`.
- anything else → `FacetPane(column:)`: `ColumnList` of `FacetRow`s (lead
  mark, title, count), selectable the same way, draggable as its tracks,
  right-click = queue / add to crate / transfer / show in Finder for its
  tracks.

The Track column shows the sortable `TrackTableHeader` (and the
`trackColumns` table) only when it is the sole column, as today; beside
other columns it is the narrow list. Playlist reordering keys on "view is
`[track]` and the playlist is unsorted", which is what `flat` meant.

### E2. Column headers

`ColumnList`'s title becomes a menu when given `facets` and `onPick`: every
`BrowserFacet` listed, the current one checked, choices that would break a
rule (a duplicate, Track anywhere but last) disabled. Picking swaps that
column's facet in place and re-derives anchors from column 0.

### E3. Column count

The header's layout key becomes the count: `1 · 2 · 3`. Adding a column
inserts the first facet from the preference order **Track, Album, Artist,
Genre, Year, Decade, Format, Album Artist, Rating** that the view does not
already contain; Track goes at the end, anything else goes before a trailing
Track column. So `[artist]` → `[artist, track]` → `[artist, album, track]`,
and `[genre, track]` → `[genre, album, track]`. Removing drops the last
column. Both are `BrowserView` methods (`adding()`, `droppingLast()`), pure
and tested, and both go through its validation.

### E4. Everything else

Search is untouched: the cascade reads `browsedIndex`. The sidebar's
per-crate match counts are untouched. `BrowserCondensed` reads
`selectedArtist`/`selectedAlbum`/`visibleTracks` and keeps working through
D2. The gallery reads `allAlbumsSorted` and selects through `reveal`.

---

## Part F: testing

**Core, `BrowserFacetTests`:** every facet's key and title, including decade
bucketing, missing year, blank genre, unrated, the format fallback to the
extension, and folded keys merging "rock" with "Rock".

**Core, `BrowserViewTests`:** the three rules; `classic`/`table`; `legacy:`
mapping of all three `BrowserLayout` cases; the E3 append rule.

**Core, `BrowserCascadeTests`:** on a small library — column 0 is the whole
index; narrowing by anchor and by multi-selection; an Album column returns
the index's own objects (identity, not rebuilt); a version member hit keeps
the release; the Track column narrowed under `Genre · Album`; counts on
value rows; a column with nothing selected passes everything through;
`selectedTracks` for a single click at each kind of leaf and for a
multi-selection.

**Core, `BrowserStateTests`:** the existing 20 stay green through the
forwards, plus: a click re-derives anchors to the right; the set moves
columns on ⌘-click elsewhere; `reveal` sets every anchor; `reanchor` with
the generic state; `selectAll(column:)`.

**App:** `persistenceKey` is unique and stable for every `LibrarySource`
case; the legacy seed maps `.full`/`.albumTrack`/`.track` to the right views.

Views stay untested. Everything decidable is in Core.

---

## Order of work

Five tasks, each leaving the suite green and the app working:

1. **Core model:** `BrowserFacet`, `BrowserView`, `FacetValue`,
   `ColumnContent`, `FacetContext`, tests.
2. **Core cascade:** `BrowserCascade.columns` and `selectedTracks`, tests.
3. **Core selection:** `BrowserState` generalized with the forwards; the
   existing tests kept, new ones added. Nothing in App changes yet.
4. **View model:** `browserView`, `browserColumns`, the compat surface (D2),
   per-source persistence and migration (D3), keyboard (D4). The three
   existing panes read `browserColumns`; the app looks the same.
5. **UI:** `FacetPane`, header menus, the count key, `flat` removed.

Then docs: CLAUDE.md's browser section and `BrowserLayout` references.

## Files

**Core, new:** `Models/BrowserFacet.swift`, `Models/BrowserView.swift`,
`Services/BrowserCascade.swift`.
**Core, modified:** `Models/BrowserState.swift`, `Models/BrowserLayout.swift`
(legacy shim), `Services/PreferencesStore.swift`.
**App, new:** `Main/Browser/FacetPane.swift`, `Main/Browser/Rows/FacetRow.swift`.
**App, modified:** `LibraryViewModel.swift`, `+MultiSelect`, `+ArrowNav`,
`+Search` (no change expected; listed to be checked), `BrowserPane.swift`,
`ColumnList.swift`, `MainShell.swift`, `BrowserCondensed.swift`,
`ArtworkGalleryView.swift`, `BrowserContextMenu.swift`, `CLAUDE.md`.
**Tests, new:** `BrowserFacetTests`, `BrowserViewTests`, `BrowserCascadeTests`.
**Tests, modified:** `BrowserStateTests`, `SearchSourceSwitchTests` (or a new
`LibrarySourceKeyTests`).
