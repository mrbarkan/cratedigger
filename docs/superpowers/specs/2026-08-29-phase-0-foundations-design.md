# 2.0 Phase 0: the foundations — Design

**Date:** 2026-08-29
**Branch:** v2 (beta line)
**Scope:** the two pieces the roadmap calls Phase 0. Neither is user-facing on
its own; everything in Phases 1 to 4 depends on one or both.

---

## Why this exists

The roadmap's Phase 0 is two sentences:

> Listening data moves into the shared track store: play count, skip count,
> last played, date added, rating.
>
> At the same time, browser state (selection, sort, and the filtering that
> Phase 1 introduces) moves out of the view model and into the tested core
> library.

Both are unglamorous and both unblock the rest. Phase 2's smart crates cannot
have a "never played" or "rated four stars and up" rule without the first.
Phase 1's search field has nowhere clean to live without the second.

### What the survey found

Two things that make this smaller than it reads, and one that makes it bigger.

**Sort logic is already in Core.** `LibraryIndex.sortedTracks(_:by:ascending:)`,
`sortedAlbums`, and `sortedArtists` are public static pure functions
(`LibraryIndex.swift:358, 416, 452`), and the sort field enums are Core types
too. Only the *state* — which field, which direction — lives in the view model
(`LibraryViewModel.swift:497-513`). "Move sort to Core" means moving six stored
properties, not writing a sorting engine.

**Selection logic is already pure.** `LibraryViewModel+MultiSelect.swift` is 177
lines of ID arithmetic over `Artist`, `Album` and `LoadedTrack`, all of which
are Core types. Its `import AppKit` is unused. It moves as-is.

**The view model is bigger than documented.** CLAUDE.md says ~2600 lines. It is
4175. Selection is referenced 121 times across 10 files and sort 65 times across
5. That reference count is what shapes Part B below.

## Non-goals

- No search field, no filtering behaviour. `BrowserState` gets the seam Phase 1
  fills; Phase 1 fills it.
- No smart crates, no stats view, no library-health panel.
- No move of `browserLayout`, `trackColumns`, the pane-collapse flags, or
  `showSortControls`. Those are window chrome, not browser state, and including
  them widens the diff for nothing.
- No change to what a crate is, how the `TrackStore` encodes, or how artwork is
  keyed.

---

## Part A: listening data

### A1. The model

```swift
/// What CrateDigger knows about your relationship with a track, as opposed to
/// what it knows about the file.
public struct ListeningStats: Codable, Sendable, Equatable {
    public var playCount: Int
    public var skipCount: Int
    public var lastPlayed: Date?
    public var dateAdded: Date
    /// 0 means unrated, which is distinct from "rated zero". 1...5 otherwise.
    public var rating: Int
}
```

`rating: Int` with 0-as-unrated rather than `Int?` because it is compared and
sorted constantly and an optional would put a `??` at every one of those sites.
The zero case is documented on the property.

### A2. Where it lives

A new `ListeningStore`, keyed by standardized file path, saved as
`library.cdplays` beside `library.cdtracks` in the crates index folder. Same
shape as `TrackStore`: one JSON file, canonical output (sorted keys, sorted
records) so an unchanged file re-serializes byte-identical and delta-based
backup can dedup it, and the same `isDirty` skip so a save with nothing to write
does not happen at all.

**Why not a field on `LoadedTrack` in the existing store**, which is what the
roadmap sentence literally says. Two reasons, both about not losing data:

1. `TrackStore.upsert(_:)` replaces the whole record for a path
   (`TrackStore.swift:106`). The tag-write, relink, rescan and organiser paths
   all reconstruct a `LoadedTrack` and upsert it. Every one of them would have
   to remember to carry stats forward, and the failure mode of forgetting is
   silently zeroing somebody's play counts — the kind of bug nobody notices for
   months and nobody can undo.
2. `library.cdtracks` is deliberately byte-canonical so that an unchanged
   library does not re-write on save. A play count is the most frequently
   changing value in the app. Putting it in that file means every play dirties
   the index that the canonicalisation exists to keep clean.

Separate storage keeps the roadmap's actual intent — shared, crate-independent,
per-library, living with the crates — while making the wipe impossible rather
than merely unlikely.

### A3. What counts as a play

There is already a definition of "listened to it properly" in the app: the
Last.fm scrobble threshold at `LibraryViewModel.swift:2912` — four minutes or
half the duration, whichever is shorter, and at least thirty seconds. It is
correct and it is battle-tested.

It becomes one named Core function:

```swift
public enum PlayThreshold {
    /// Last.fm's rule, and now ours: a play is half the track or four minutes,
    /// whichever comes first, and never under thirty seconds.
    public static func isPlayed(elapsed: Double, duration: Double) -> Bool
}
```

The scrobbler and the play counter both call it, so "a play" has exactly one
definition in the codebase and it is unit-tested rather than inlined in a view
model. This is a refactor of existing behaviour, not a new rule: the scrobble
threshold must not change.

A **skip** is the mirror image: `onCurrentIndexChange` fires (or the user
presses next) while `isPlayed` is still false for the outgoing track. The
existing `lastScrobbledTrackID` guard already prevents double counting and is
already reset per track at `LibraryViewModel.swift:2963`.

Explicitly not counted: streams (radio never scrobbles today and will not count
plays either), and a track the user seeks past without hearing — the threshold
is measured on *elapsed listening*, not playhead position, which is why
`playbackStartTimestamp` exists.

### A4. dateAdded

Stamped when a path first enters the `ListeningStore`, which happens at scan
time. Not the file's creation date: "added" means added to this library, and a
2003 rip added last Tuesday should sort as last Tuesday.

Backfill for existing libraries: on first load of a library with no
`library.cdplays`, every known path gets a `dateAdded` of the track store file's
own modification date, with a `ponytail:` comment naming the ceiling. It is a
guess, but it is a defensible one, and the alternative — every track in a
15,000-track library claiming to have been added the day the user upgraded — is
worse and makes "added this month" useless for a year.

### A5. Rating needs a writer

A field nothing can set is dead weight, so Phase 0 includes the minimum that
makes rating real: a five-star control in the inspector and ⌘1–⌘5 in the
Playback menu (⌘0 clears). Multi-selection rates the whole selection. That is
the whole of the rating UI in this phase; anything more waits for Phase 3.

**Correction (shipped):** the shortcuts are Command-Option-0 through
Command-Option-5, not the ⌘0-⌘5 above. Plain ⌘1 to ⌘4 already belong to the
View menu's OLED display switcher, so the design's choice would have stolen
four existing shortcuts. See commit `1c07f36`.

**Correction (shipped):** rating is gated on a real selection
(`LibraryViewModel.hasRatableSelection`) in both the menu and the inspector
stars. `resolvedSelectionTracks()` falls back to the first visible track, which
would have let one keystroke write a rating into an unbacked store with nothing
actually selected.

### A6. Keeping the key correct

Stats are keyed by path, so anything that changes a track's path must repoint
them. The app already has exactly these choke points and they already do this
work for the `TrackStore`:

- `updateTrackURLInIndex(oldURL:newTrack:)` — `LibraryViewModel.swift:3885`
- `updateTrackURLsInIndex(_:)` — `LibraryViewModel.swift:3901`
- `moveLibrary()` — `:3937`
- `consolidateLibrary()` — `:4115`

Each gains one line. A path that disappears keeps its stats until the track is
removed from the store; orphan pruning happens on the same pass that drops dead
track-store keys.

---

## Part B: browser state into Core

### B1. The type

```swift
/// Everything the browser is currently showing you and how: what is picked,
/// what order it is in, and (from Phase 1) what is filtered out.
public struct BrowserState: Sendable, Equatable {
    // Anchors — the "last clicked" in each column, which drives drill-down.
    public var selectedArtistID: String?
    public var selectedAlbumID: String?
    public var selectedTrackID: UUID?

    // Multi-selection. Mutually exclusive by construction: you are picking
    // whole artists, or whole records, or individual tracks.
    public var selectedArtistIDs: Set<String>
    public var selectedAlbumIDs: Set<String>
    public var selectedTrackIDs: Set<UUID>

    public var trackSort: BrowserSort<TrackSortField>
    public var albumSort: BrowserSort<AlbumSortField>
    public var artistSort: BrowserSort<ArtistSortField>

    public var focusedColumn: BrowserColumn
}
```

`BrowserSort<Field>` is a two-field `(field, ascending)` pair, so the three
sorts share one type instead of six loose properties. Named `BrowserSort` rather
than the obvious `SortOrder` because Foundation already has a `SortOrder`, and a
Core type shadowing it would be a trap for the next person.

The mutation rules move from `LibraryViewModel+MultiSelect.swift` onto this type
as pure methods: `selectArtist(_:command:shift:ordered:)`, `selectAlbum`,
`selectTrack`, `clearMultiSelection`, and the `is…Selected` predicates. The
mutual-exclusivity invariant becomes something the type enforces rather than
something three call sites happen to agree on, and it becomes testable.

`BrowserColumn` moves to Core alongside it. It is currently an internal enum in
`LibraryViewModel+ArrowNav.swift:5` and becomes public; the arrow-navigation
extension keeps working against it unchanged.

### B2. How the view model keeps its shape

`LibraryViewModel` holds one `@Published var browser: BrowserState` and keeps
**every existing property name as a computed forward**:

```swift
var trackSortField: TrackSortField {
    get { browser.trackSort.field }
    set {
        browser.trackSort.field = newValue
        prefs.savedTrackSortField = newValue.rawValue
        recomputeSortedCollections()
    }
}
```

This is the load-bearing decision of Part B. It means:

- The 121 selection and 65 sort call sites **do not change at all**. The diff
  concentrates in the view model plus the new Core files, which is what makes a
  change of this size reviewable.
- `$model.trackSortField` keeps working in `BrowserPane.swift:116, 169, 289`. A
  computed var with a setter is still a `ReferenceWritableKeyPath`, which is
  what SwiftUI's `$` projection needs.
- Mutating a struct held in a `@Published` fires `objectWillChange`, so the
  computed getters re-read and views update exactly as before.

The per-property setters are also why we are not putting a `didSet` on `browser`
itself: a single observer on the whole struct cannot tell a sort change from a
selection change, so every mouse click in the browser would re-sort the entire
library. The forwarding setters keep `recomputeSortedCollections()` firing on
exactly the six properties that already trigger it today.

### B3. Persistence

Unchanged. The six sort properties already persist to `PreferencesStore`
(`savedTrackSortField` and friends) and continue to, from the forwarding
setters. Selection is not persisted today and is not being made persistent here.

---

## Risks and how they are handled

**Silent selection regressions.** Selection is the most-touched state in the
app and has no test coverage today. Mitigated by extracting it to a pure type
*with* tests as part of the move — the mutual-exclusivity and shift-range rules
get their first tests ever — and by not touching call sites, so any regression
is in one file rather than ten.

**Re-sorting on every click.** Called out above; the forwarding setters are the
guard. A test asserts that mutating a selection does not invalidate the sorted
collections.

**Stats lost on a path change.** The four choke points in A6 are enumerated and
each gets a test that a rename preserves the count.

**Scrobble behaviour drifting during the threshold refactor.** `PlayThreshold`
must be a pure extraction. Tests assert the exact existing boundaries (30s
floor, 4-minute cap, half-duration rule) before the call site is switched over.

---

## Testing

New Core suites:

- `ListeningStatsTests` — encode/decode round trip, unrated vs zero rating.
- `ListeningStoreTests` — canonical byte-identical output, dirty-skip, repoint
  on path change, orphan pruning, backfill on a store with no plays file.
- `PlayThresholdTests` — the boundaries, pinned to today's behaviour.
- `BrowserStateTests` — mutual exclusivity across the three columns, ⇧-range
  selection, ⌘-toggle, anchor drill-down, sort round trip.

`LibraryViewModel` remains largely untested, as today. The point of the phase is
that the parts worth testing stop living there.

---

## Order of work

1. `PlayThreshold` extracted and tested; scrobbler switched to it. No behaviour
   change, so it lands first and independently.
2. `ListeningStats` + `ListeningStore` + tests. Store wired into the view model,
   nothing recording yet.
3. Recording plays and skips off the existing playback callbacks. Backfill and
   repointing.
4. Rating: inspector control and menu commands.
5. `BrowserState` + tests, `+MultiSelect` logic moved onto it.
6. View model converted to forwarding properties. `+MultiSelect` becomes thin
   delegation.
7. CLAUDE.md updated: the new Core types, and the corrected view model size.

Steps 1 to 4 and 5 to 6 are independently verifiable; the suite must be green at
each numbered step, not just at the end.
