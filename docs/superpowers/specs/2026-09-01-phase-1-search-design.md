# 2.0 Phase 1: find anything — Design

**Date:** 2026-09-01
**Branch:** v2 (beta line)
**Scope:** the roadmap's Phase 1 (library search and the SEARCH display
screen), plus one theming request that rode along: a transport lamp token
so the silicone caps stop borrowing the accent.

---

## Why this exists

The roadmap's Phase 1 is three sentences:

> One field, one keystroke to reach it, results as you type. It searches
> artist, album, track title, file path and format across the crate you are
> in, with a mode that widens to every crate you own. The index it searches
> is already built and already in memory, so this should feel instant rather
> than merely fast.
>
> Sortable browser columns land here too. And because the console deserves
> it, SEARCH becomes a view on the OLED display, the way CNVRT and SCAN
> already are.

Phase 0 left the seam: `BrowserState` ends with an empty `// MARK: - Phase 1
seam` and a comment saying search lands there. This spec fills it.

### What the survey found

**Sortable columns already shipped.** `TrackTableHeader` gives the flat Track
layout click-to-sort headers with a direction arrow, and `ColumnSortControl`
gives the Artist and Album columns a sort menu. That roadmap line is done;
Phase 1 is search and the screen.

**The browser's lists all funnel through one place.** `visibleArtists`,
`allAlbumsSorted` and `flatTracksSorted` are cached in
`recomputeSortedCollections()` (`LibraryViewModel.swift:1363`), and
`visibleAlbums` / `visibleTracks` derive from `selectedArtist` /
`selectedAlbum`, which resolve against `index`. Filtering has a natural choke
point rather than a column-by-column retrofit.

**`index` has ~75 readers across 18 files.** Queue building, conversion
planning, artwork batches, missing-file relinking, the OLED's SCAN cells, the
sidebar counts. Making `index` itself the filtered view would mean auditing
every one for "should a live search narrow this". The design below does not
move the truth; it adds a second, browser-facing index beside it.

**"Every crate you own" already exists as a source.** `localAll` (All
Records) is the deduplicated union of every crate (`selectSource`,
`LibraryViewModel.swift:1486`). Widening the search is a source switch, not
a second index.

**The keyboard plumbing already defers to text fields.** Both the app's
`keyDown` monitor (`setupKeyboardShortcutsMonitor`) and the browser's arrow
navigation (`isEditingText()` in `+ArrowNav`) step aside while an
`NSTextField` is first responder, and `AppDelegate`'s Space monitor does the
same. A search field costs nothing there.

## Non-goals

- No fuzzy or phonetic matching, no field-prefixed queries (`artist:miles`),
  no search history, no saved searches. Smart crates are Phase 2.
- No search over the sources sidebar. The roadmap sentence mentions it, but
  a crate list is short and it would need its own filtered sidebar.
- No type-to-search from the browser (a printable key jumping focus to the
  field). Single-key shortcuts already own those keys
  (`prefs.keyboardShortcuts`).
- No change to what `index` means. Everything that reads it today keeps
  reading the whole source.
- No search over radio streams. `RadioListView` already has
  `filteredStreams`; the bar hides on a radio source.

---

## Part A: the filter, in Core

### A1. The model

`BrowserState`'s seam becomes one stored property backed by one value type,
both in `BrowserState.swift`:

```swift
/// What the browser is hiding and how far it is looking.
public struct BrowserFilter: Sendable, Equatable {
    public enum Scope: String, Sendable, Equatable {
        /// The source you are in.
        case source
        /// Every crate you own: All Records.
        case everywhere
    }

    public var query: String = ""
    public var scope: Scope = .source

    public init(query: String = "", scope: Scope = .source)

    /// False for an empty or all-whitespace query. An inactive filter is the
    /// identity: nothing is pruned, nothing is copied.
    public var isActive: Bool
}

public struct BrowserState {
    // ...
    public var filter = BrowserFilter()
}
```

Session-only. The sort pairs persist through the view model's forwarding
setters; the filter deliberately does not. A search is about what you are
looking at right now.

### A2. Matching

One public predicate, so the view model can apply the same rule to a
playlist's unsorted order (see B4) without a second definition:

```swift
extension BrowserFilter {
    /// Every token of the query must appear in at least one field.
    public func matches(_ track: LoadedTrack) -> Bool
    /// Album-level match: title or album artist.
    public func matches(album: Album) -> Bool
    /// Artist-level match: name.
    public func matches(artist: Artist) -> Bool
}
```

Rules:

- **Normalization.** Both sides go through
  `folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)`.
  `bjork` finds Björk; `MILES` finds Miles.
- **Tokens.** The query splits on whitespace. Every token must hit at least
  one field (AND across tokens, OR across fields). `mil blue` finds Miles
  Davis' *Kind of Blue*; `flac live` finds live FLACs.
- **Track fields**, exactly the roadmap's five, with "artist" read
  generously: `title`, `artist`, `metadata.albumArtist`, `album`, the file
  path, and the format (`formatName ?? pathExtension`). Album artist is in so
  `various` finds compilations; the path is in so a folder name or a file
  name finds its contents.
- **Album fields:** `title`, `artistName`. **Artist field:** `name`.

### A3. Pruning

```swift
extension LibraryIndex {
    /// The same index with everything the filter hides removed. An inactive
    /// filter returns `self`.
    public func filtered(by filter: BrowserFilter) -> LibraryIndex
}
```

The rules, which are what the tests pin:

1. A **track** survives if `matches(_:)` is true.
2. An **album** whose own title or album artist matches keeps **all** its
   tracks. Searching "kind of blue" gives you the record, not zero tracks.
   Otherwise it survives only if some track does, carrying just those.
3. An **artist** whose name matches keeps all albums, whole. Otherwise it
   survives on its surviving albums.
4. **Version groups.** A grouped release (`versions != nil`) applies rule 2
   to itself and to each member in `versions`. The release survives if its
   own title/artist matches (kept whole, members and all), or if any member
   or any of its own `tracks` survives. Its `tracks` are pruned by rule 1
   like any album's, so a release whose primary pressing has no hit but whose
   Gold CD does shows with an empty top-level track list and one expandable
   member. That is honest, and it is what the flat layout would show anyway.
5. `allTracks` is the original `allTracks` narrowed to the tracks present
   anywhere in the pruned tree (top-level albums and version members), in
   the original order. `albumCount` counts surviving top-level albums.
   `totalSizeBytes` is **carried over unchanged**: `build` gets it from
   `computeTotalSizeBytes`, which stats every file, and nothing
   browser-facing reads it (the SCAN screen reads `index`). The property's
   doc comment says so, so nobody trusts it on a pruned index.
6. An inactive filter returns `self`, by identity. No copy, no cost.

Pruning is struct filtering over an index that is already in memory. It
never stats a file, never reads a folder, never touches `LibraryIndexDiskCache`.

### A4. Re-anchoring

The selection anchors can point at things the filter just hid. Today
`selectSource` heals this inline (three assignments at
`LibraryViewModel.swift:1529`). That logic moves into Core so the filter can
reuse it and it gets a test:

```swift
extension BrowserState {
    /// Point every anchor at something the index actually contains: an
    /// anchor that is still present stays; one that is not moves to the
    /// first artist / its first album / its first track. Clears the
    /// multi-selection sets, because a hidden selection is one that can be
    /// acted on without being seen.
    public mutating func reanchor(in index: LibraryIndex)
}
```

"Present" is checked the way the browser resolves anchors: an artist by
`artist(id:)`, an album by `albumOrVersion(id:)` (a version member can be
the anchor), a track by membership in `allTracks`. On an empty index every
anchor goes nil.

`selectSource` calls it where the three assignments and the
`clearMultiSelection()` were. The filter setter calls it after every
recompute. When the filter clears, the anchors stay wherever the search left
them: you land on what you found, which is the point of searching.

### A5. Performance

On-the-fly normalization first. At 14k tracks a keystroke is roughly 14k × 6
`folding` calls plus the substring searches, then a sort of the survivors
only (prune before sort, so the sort pays for what is left). The plan
measures one keystroke against the 14k library before the field ships. If a
keystroke exceeds ~50 ms, the upgrade is a per-index haystack cache (one
pre-folded string per track, built once in `index`'s `didSet`), not a
debounce. A debounce makes the tuner sweep lie about how fast the app is.

---

## Part B: the seam in the view model

The behaviour lives in a new `LibraryViewModel+Search.swift`. The main file
gains two cached properties and a handful of one-line reader changes (B2);
it does not gain behaviour.

### B1. `browsedIndex`

```swift
/// What the browser is showing: `index` with the search applied. Equal to
/// `index` (by identity, no copy) while nothing is typed. The truth stays
/// in `index`; this is the view of it.
@Published private(set) var browsedIndex: LibraryIndex = .empty
```

Recomputed at the top of `recomputeSortedCollections()`, which already runs
on every `index` change and every sort change:

```swift
private func recomputeSortedCollections() {
    browsedIndex = index.filtered(by: browser.filter)
    visibleArtists = LibraryIndex.sortedArtists(browsedIndex.artists, ...)
    allAlbumsSorted = LibraryIndex.sortedAlbums(browsedIndex.allAlbums, ...)
    flatTracksSorted = LibraryIndex.sortedTracks(browsedIndex.allTracks, ...)
    browsedPlaylistTracks = playlistTracks.filter { browser.filter.matches($0) }   // see B4
}
```

### B2. Readers that move to `browsedIndex`

Exactly these, every one of them browser-facing:

| Reader | Where | Why |
|---|---|---|
| `visibleArtists`, `allAlbumsSorted`, `flatTracksSorted` | `recomputeSortedCollections()` | the lists themselves |
| `selectedArtist`, `selectedAlbum` | `LibraryViewModel.swift:1325-1333` | drill-down follows the pruned tree, and the `?? .first` fallbacks land on a survivor |
| `selectAllArtists/Albums/Tracks` | `+MultiSelect.swift:59-65` | ⌘A must select what you can see, not what you cannot |
| `ArtistPane` trailing count | `BrowserPane.swift:114` | the column says how many rows it has |
| `shouldShowEmptyState` | `BrowserPane.swift:56` | see C5 |
| `browserTrailing`, `browserSubtitle` | `MainShell.swift:239, 258` | the browser well describes the browser |

### B3. Readers that stay on `index`

Everything else, deliberately. Two worth naming because they look like they
should move and must not:

- **`sourcesTrailing` / `sourcesCollapsedSubtitle`** (`MainShell.swift:109,
  233`) count the *crate's* artists. The sidebar describes the source.
- **`ScanPane`'s cells** (`OLEDDisplay.swift:1084`) describe the library. The
  SEARCH screen has its own counts (D3).

Playback needs nothing: `browsingTracks` already derives from
`flatTracks` / `visibleTracks`, so a filtered row activates into the
filtered list. `queue(containing:)` is untouched.

### B4. Playlist order

`flatTracks` returns `playlistTracks` (the M3U's own order, unpruned) when a
playlist is unsorted. One cached `browsedPlaylistTracks`, filtered with the
same `matches(_:)` in B1, and `flatTracks` reads it instead. `playlistTracks`
is assigned outside the index path (`selectPlaylist`,
`LibraryViewModel.swift:2200`), so its `didSet` refreshes the cache too.
Without this a playlist would ignore the search until you clicked a sort
header.

### B5. The forwarding properties

Same shape as the sort pairs: computed forwards onto `browser.filter`, with
the work in the setter so a `didSet` on `browser` never re-sorts the library
on a click.

```swift
var searchQuery: String {
    get { browser.filter.query }
    set {
        guard newValue != browser.filter.query else { return }
        browser.filter.query = newValue
        recomputeSortedCollections()
        browser.reanchor(in: browsedIndex)
        if browser.filter.isActive { showSearchScreen() }   // D2
        else { searchCleared() }                            // B6, D2
    }
}
```

### B6. Scope

```swift
/// Where the user was before widening, so narrowing puts them back.
private var sourceBeforeSearch: LibrarySource?

func setSearchScope(_ scope: BrowserFilter.Scope)
```

- **Widening** (`.source` → `.everywhere`): capture `currentSource` and the
  query in locals, call `selectSource(.localAll)`, and only then set
  `sourceBeforeSearch` and put the filter back. The order matters: the
  source switch resets the filter *and* drops `sourceBeforeSearch` (B7), so
  both are written after it, not before. The sidebar highlights All Records.
  Nothing is hidden about where you are.
- **Narrowing** (`.everywhere` → `.source`): capture the query, call
  `selectSource(sourceBeforeSearch)`, restore the query with scope `.source`,
  forget the origin.
- **Clearing the query while widened** narrows first, so Escape takes you
  home.
- The control is only offered on local sources, and is hidden in All Records
  itself (there is nowhere wider to go). A CD, playlist, device or remote
  library still filters in place; they are just another index.

### B7. What clears a search

- A **source switch** the user makes (`selectSource` with `sourceChanged`):
  the filter resets to `BrowserFilter()` (query and scope both) and
  `sourceBeforeSearch` is dropped. The scope switch in B6 goes through the
  same call and restores the filter afterwards.
- **Go to Current Song** (`revealNowPlaying`) when the playing track is not in
  `browsedIndex`: clear the query, then reveal. Revealing into a filtered-out
  row would do nothing, and silently doing nothing is the failure mode that
  method's comment already refuses.
- **Escape** in the field (C3).

### B8. The collapsed browser

`revealNowPlaying` already expands a collapsed browser because "collapsed,
the browser has nowhere to show the reveal". `requestSearchFocus()` does the
same before focusing the field: `browserCollapsed = false`.

---

## Part C: the field

### C1. Placement

`BrowserSearchBar`, in `Main/Browser/`. It lives in **`MainShell`'s browser
well**, above the `RadioListView` / `ArtworkGalleryView` / `BrowserPane`
switch (`MainShell.swift:140-146`), not inside `BrowserPane`. Two reasons:

- The gallery reads `allAlbumsSorted`, so it is already filtered by B1 for
  free. Putting the bar above the switch means the gallery is searchable
  without a second field.
- The bar is hidden on a radio source, and the well is where that decision
  is already made (`isRadioMode`).

Always visible, not summoned. A search field you cannot see is one you
forget the app has. A recessed Carbon well strip, one row tall, with a
magnifier glyph leading, the query, and the scope control trailing.

### C2. Focus

- **Command-F.** New `Find` item in the Edit menu after Select All
  (`AppDelegate.swift:895`), action `focusSearch(_:)` →
  `MainWindowController.focusSearch()` → `model.requestSearchFocus()`.
  `validateMenuItem` returns false on a radio source.
- `requestSearchFocus()` expands the browser (B8), remembers the display
  (D2), switches it to SEARCH, and bumps `searchFocusTick`. The view watches
  the tick with `onChange` and sets its `@FocusState`, the same pattern as
  `revealTick` → `ColumnList.scrollTarget`.
- The view reports focus back with one published bool,
  `searchFieldFocused`, so the display can decide when to leave (D2).

### C3. Keys inside the field

- **Escape** (`.onExitCommand`): clear the query, resign focus. Clearing
  runs B5 and therefore B6's narrowing and D2's display return.
- **Return**: nothing. Considered "play the first match" and skipped: the
  browser is one Down-arrow away and already knows how to play.
- Everything else is the system text field: cursor, selection, paste,
  undo, dictation.

### C4. Scope control

A two-position Carbon toggle at the trailing edge reading `CRATE` / `ALL`,
bound to `setSearchScope`. Shown only when `isLocalSource` and
`currentSource != .localAll`. Tooltip: "Search this crate only, or every
crate you own."

### C5. Empty states

`shouldShowEmptyState` today means "no library loaded" and offers OPEN
FOLDER. With a filter matching nothing, the columns would just go blank.
Two states, decided from `browsedIndex` and the filter:

- `index.allTracks.isEmpty` → the existing `BrowserEmptyState`, unchanged.
- `index` non-empty, `browsedIndex.allTracks.isEmpty`, filter active → a
  quieter `NoMatchesState`: the glyph, `No matches for "…"`, and a
  `CLEAR SEARCH` key. No OPEN FOLDER; the library is fine.

Both belong to the list browser. The gallery shows an empty grid on no
matches; the display's `NO MATCH` line (D3) covers it.

### C6. Counts

`browserTrailing` reads `12 OF 400 RECORDS` while a filter is active and
`400 RECORDS` otherwise. The column counts (`ArtistPane` trailing) already
say how many rows each column has once they read `browsedIndex`.

---

## Part D: the SEARCH screen

### D1. The case

`OLEDView` gains `case search`, `label: "Search"`. Every exhaustive switch
over `OLEDView` grows a line: `DisplayContext` (the pane),
`DisplayModeButton.currentLabel` (`"SRCH"`), `OLEDView.accent(_:)`.
`DisplayRail` gains an `ann("SRCH", …)` after DEV; the plan checks the rail
still fits at the minimum window width before ON AIR, since that row is
fixed-spaced.

**Not in `DisplayModeButton.cycle`, not in the View menu.** Both are hand
lists (`cycle`, `displayedViews` at `AppDelegate.swift:903`) of the four
screens you choose; SYNC and CD are summoned by their jobs and SEARCH is
summoned by Command-F or by typing. A chosen SEARCH screen with nothing
typed is a screen that says READY at you.

### D2. When it shows, when it leaves

```swift
/// The screen the display was on when search took it over.
private var oledViewBeforeSearch: OLEDView?
```

- `requestSearchFocus()` and the first character typed both call
  `showSearchScreen()`: if `oledView != .search`, remember it and switch.
- `searchCleared()` (B5) and losing focus with an empty query both call
  `hideSearchScreen()`: **only if the display is still on `.search`**,
  restore the remembered view (`.nowPlaying` if there is none), then forget
  it either way. The guard matters: if you pressed DISPLAY mid-search to
  look at CNVRT, leaving the field must not yank the screen back to where
  it was before the search. Typing then deleting back to empty while
  focused keeps the screen; the display reads READY until you leave.
- **Never persisted.** `oledView`'s `didSet` writes `savedOLEDView`; it
  skips `.search`, so a relaunch never opens on an empty search screen.

### D3. The pane

`SearchPane` in `OLEDDisplay.swift`, on `OLEDPaneScaffold` like the others:

- **Headline:** the query in the display face, or `READY` when empty. Sub
  line: `SEARCHING THIS CRATE` / `SEARCHING ALL RECORDS`, or `NO MATCH` when
  the filter is active and `browsedIndex` is empty.
- **Readout:** a `ScanBar` in a new `.sweep(Color)` style: the existing
  `indigoSweep` motion (a short capsule gliding back and forth on repeat)
  drawn in `lampSearch`, shown while the query is non-empty; the bare well
  when it is empty. That is the tuner. No fake latency: the filter is
  synchronous, so the sweep is the "tuned" state, not a progress bar.
- **Cells:** `ART` / `ALB` / `TRK` counts from `browsedIndex`, and `SCOPE`
  reading `CRATE` or `ALL`.

### D4. The lamp

`lampSearchOverride: Color?` with `lampSearch: Color { lampSearchOverride ?? cyanGlow }`.
Every other accent already belongs to a lamp (sun, orange, cyan, indigo,
red, orangeHi); `cyanGlow` is free and reads as a tuner's cold light. Wired
the same three places as the other six: `CarbonTheme.init` via
`optionalColor("lampSearch", …)`, `monochromeGlass` clears it, and
`ThemeTokenCatalog`'s Display Lamps group gets a `SRCH Lamp` swatch reading
`\.lampSearch`.

---

## Part E: the transport lamp token

### E1. What it is

The LED behind every `SiliconeCap` that lights: the play/pause dome, shuffle,
repeat, the mini player's dome and toggles, and the welcome tour's demo cap.
Today `SiliconeCap` reads `orangeHi` / `orange` / `orangeLo` for its lit
gradient and `orange` for the outer bloom (`SiliconeCap.swift:30-32, 55`).
Retint the accent and the transport moves with the POSITION bar, the meters
and the sort arrows, whether or not that was the idea. The `lamp*Override`
and `selection*` tokens exist for precisely this split; this is one more.

### E2. The token

```swift
/// The LED behind the transport caps. One hue: a real LED behind rubber is
/// one colour at three depths, which is what the cap's opacity ramp does.
/// Unset it follows the accent trio exactly, so nothing shipped changes.
public var transportLampOverride: Color?
public var transportLampHi: Color { transportLampOverride ?? orangeHi }
public var transportLamp:   Color { transportLampOverride ?? orange }
public var transportLampLo: Color { transportLampOverride ?? orangeLo }
```

`SiliconeCap` reads the three computed properties for its gradient stops and
`transportLamp` for the bloom. Unset, every pixel is identical to today.
Set, the ramp is one hue at the existing 0.92 / 0.74 / 0.46 opacities.

Read in `CarbonTheme.init` with `optionalColor("transportLamp", …)`. **Not**
added to `monochromeGlass`: the caps are on the chassis, not the glass.

### E3. The editor

One swatch in `ThemeTokenCatalog`, Buttons & Knobs group:

> key `transportLamp`, label `Transport Lamp`, note "The LED behind the
> play, shuffle and repeat caps, in the footer and the mini player. Unset it
> follows the Accent.", read `\.transportLamp`.

---

## Part F: testing

**Core, `BrowserFilterTests`:**

- Empty and whitespace queries are inactive; `filtered(by:)` returns the
  same index.
- Case and diacritic folding on both sides.
- Token AND across fields: `mil blue` matches, `mil green` does not.
- Each of the six track fields matches alone: title, artist, album artist,
  album, path (a folder name that appears in no tag), format.
- Album-level match keeps every track; track-level match keeps only hits.
- Artist-level match keeps every album whole.
- A version group survives on a member hit with a pruned top-level list; a
  release-title hit keeps every member whole; no hits anywhere removes the
  release.
- `albumCount` is recomputed; `totalSizeBytes` is carried over.
- `allTracks` includes a version member's surviving tracks and preserves
  the original order.

**Core, `BrowserStateTests` (extended):**

- `reanchor(in:)` keeps a present anchor (including an album anchor that is
  a version member), moves a missing one to the first artist / album /
  track, clears all three multi-selection sets, and sets every anchor to
  nil on an empty index.

**App, `DisplayLampTokenTests` (extended):**

- `transportLamp*` unset equals the accent trio; set, all three equal the
  set colour and differ from the accent.
- `lampSearch` unset equals `cyanGlow`; set overrides; `monochromeGlass`
  collapses it; both keys are reachable from the editor catalog.

**Manual, in the plan:** a keystroke timed against the 14k library (A5),
the display rail at minimum window width (D1), and the widen / narrow /
Escape round trip landing back in the origin crate (B6).

Views and the view model stay untested, as ever. Everything decidable is in
Core with a test.

---

## Holes found while checking the design, and what closed them

The user asked for these to be looked for. Each one is a place the first
draft would have shipped a bug.

1. **⌘A selected hidden tracks.** `selectAllTracks()` reads `index.allTracks`.
   Moved to `browsedIndex` (B2).
2. **A playlist ignored the search** until sorted, because its own order
   bypasses `flatTracksSorted`. `browsedPlaylistTracks` (B4).
3. **No artist row lit after filtering.** The anchor pointed at a hidden
   artist, the drill-down fell back to the first survivor, and nothing was
   highlighted. `reanchor(in:)` (A4), which also retires the inline copy in
   `selectSource`.
4. **A hidden multi-selection could be acted on.** Convert Selection after
   narrowing would have converted rows you could not see. `reanchor` clears
   the sets (A4).
5. **The gallery would have had no search bar** if the bar lived in
   `BrowserPane`. Moved up to the well (C1); the gallery filters for free.
6. **A no-match search showed blank columns**, or worse, the OPEN FOLDER
   empty state. `NoMatchesState` (C5).
7. **A relaunch could open on an empty SEARCH screen.** `oledView` is
   persisted on every change; `.search` is skipped (D2).
8. **The display had nowhere to go back to.** Conversion returns to NOW, not
   to where you were; search remembers (D2).
9. **Widening lost the query.** `selectSource` resets the filter on a source
   change (B7), so the scope switch restores it after the call (B6).
10. **Go to Current Song did nothing** if the playing track was filtered out.
    It clears the search first (B7).
11. **Counts lied.** The browser well said `400 RECORDS` over 12 rows; the
    Artist column said `48` over 3. Both read `browsedIndex` now (B2, C6),
    while the sidebar and SCAN screen deliberately do not (B3).
12. **The collapsed browser had nowhere to show the field.** Command-F
    expands it, as reveal already does (B8).

## Opportunities taken, and two left

- **Batch actions on results, free.** Search `flac`, ⌘A, Convert with scope
  Selection converts every FLAC in the crate. Nothing was built for this; it
  falls out of B2 plus `ConversionBatchScope.selection`.
- **The gallery is searchable**, free, from C1.
- **`selectSource`'s inline healing becomes a tested Core function.** Three
  lines shorter in the view model, one more thing with a test.
- **`N OF M RECORDS`** in the well tells you how much the search hid.
- Left: **Return plays the first match** (C3) and **type-to-search from the
  browser** (non-goals). Both are one line away once wanted; neither earns
  its surprise today.

---

## Files

**Core**
- `Models/BrowserState.swift` — `BrowserFilter`, `filter`, `reanchor(in:)`.
- `Services/LibraryIndex.swift` — `filtered(by:)`.

**App**
- `UI/Carbon/Library/LibraryViewModel+Search.swift` — new: forwards, scope,
  focus request, display switching, `searchCleared`.
- `UI/Carbon/Library/LibraryViewModel.swift` — `browsedIndex`,
  `browsedPlaylistTracks`, `recomputeSortedCollections`, `selectedArtist` /
  `selectedAlbum`, `selectSource` (reanchor + clear), `revealNowPlaying`,
  `oledView` `didSet`, `flatTracks`.
- `UI/Carbon/Library/LibraryViewModel+MultiSelect.swift` — three select-alls.
- `UI/Carbon/Main/Browser/BrowserSearchBar.swift` — new.
- `UI/Carbon/Main/Browser/BrowserPane.swift` — empty states, artist count.
- `UI/Carbon/Main/MainShell.swift` — bar placement, counts.
- `UI/Carbon/Header/OLEDDisplay.swift` — `SearchPane`, rail annunciator.
- `UI/Carbon/Header/DisplayModeButton.swift` — label, accent.
- `UI/Carbon/Controls/SiliconeCap.swift` — transport lamp.
- `UI/Theme/CarbonTheme.swift` — `lampSearchOverride`, `transportLampOverride`.
- `UI/Theme/ThemeTokenCatalog.swift` — two swatches.
- `UI/MainWindowController.swift`, `AppDelegate.swift` — Find menu item.
- `CLAUDE.md` — `BrowserFilter`, `browsedIndex`, the seam is filled.

**Tests**
- `Tests/CrateDiggerCoreTests/BrowserFilterTests.swift` — new.
- `Tests/CrateDiggerCoreTests/BrowserStateTests.swift` — `reanchor`.
- `Tests/CrateDiggerAppTests/DisplayLampTokenTests.swift` — both tokens.
