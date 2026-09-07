# 2.0 Phases 2 and 3: crates that fill themselves, and library health — Design

**Date:** 2026-09-02
**Branch:** v2 (beta line)
**Scope:** the roadmap's Phase 2 (smart crates) and Phase 3 (the library
health panel), designed together because Phase 3's rows *are* Phase 2's
crates. One engine, one file format, one editor, two surfaces.

---

## Why this exists

The roadmap's Phase 2 is three sentences:

> A smart crate is a rule set instead of a list of paths. It sits in the same
> sidebar, in the same place, behaving the same way, so there is no second
> concept to learn. It just stays current on its own.

and Phase 3 is two:

> Phase 3 gathers them into one panel that opens with a straight answer.
> Every row is a smart crate. Click it, see exactly what it means, fix it in
> batch.

That last line is why these ship together. Built apart, the rule engine gets
designed twice: once for crates, once for whatever the panel's rows turn out
to be. Built together, the panel is five built-in rule sets and a fix button.

### What the survey found

Three things that make this smaller than it reads.

**Every field a rule needs is already in memory.** `AudioTrack` carries title,
artist, album, duration, format, bitrate, sample rate, year, track and disc
numbers, and the artwork hash. `ConversionMetadata` carries album artist,
genre, compilation and comment. `ListeningStore` carries play count, skip
count, last played, date added and rating, keyed by path. Phase 0 delivered
the interesting half of the roadmap's rule list; nothing here needs a new
scanner.

**Three of the five health checks already have engines.**
`LibraryCleanupService.findDeadTracks(in:)` finds files that moved.
`LibraryCleanupService.findDuplicates(...)` groups probable duplicates, with
its own normalization and a best-of-group choice. The artwork audit behind
`LibraryCleanupView` finds albums with no cover. Phase 3 is largely a home
for these, not new detection.

**Phase 3 half-exists, in the wrong place.** `LibraryCleanupView` is a sheet
behind a CLEANUP key in the inspector chrome, carrying missing tracks,
duplicates and the artwork audit. It is exactly the scattering the roadmap
complains about: real capability nobody finds.

And one that makes it bigger. **Two of the rule fields cannot be evaluated
from memory.** Whether a file still exists is a stat per track; whether a
track is a probable duplicate is a normalization and grouping pass over the
whole library. Neither can run on every index change. Part A's context and
Part B's two tiers exist for exactly this.

## Non-goals

- **No nested rule groups.** One match mode over a flat list. Nesting is where
  the editor becomes an outline view and the evaluator becomes a tree walk,
  and no rule in the roadmap's list needs it.
- **No limits or ordering rules.** "Top twenty by play count" is a different
  feature: it needs a sort inside the crate and a tie-break policy. Later, if
  asked for.
- **No crate membership as a rule field.** "In the Jazz crate and rated four
  and up" is attractive and is not in the roadmap. It also introduces a
  dependency between crates, and therefore a cycle question. Later.
- **No automatic fixing.** Every FIX opens the existing review flow. Nothing
  writes a tag or trashes a file without confirmation, which is how these
  engines already behave.
- **No rules over remote, CD, playlist or device sources.** Smart crates read
  the local library, the same scope search settled on.
- **No live folder watching.** A smart crate is current with respect to what
  CrateDigger has scanned, not with respect to the disk.

---

## Part A: the rule engine, in Core

### A1. The model

```swift
public struct SmartCrate: Codable, Sendable, Equatable {
    public var name: String
    public var match: MatchMode
    public var rules: [SmartRule]
}

public enum MatchMode: String, Codable, Sendable { case all, any }

public struct SmartRule: Codable, Sendable, Equatable {
    public var field: RuleField
    public var op: RuleOperator
    public var value: RuleValue
}
```

`RuleValue` is an enum over the four value shapes a rule can carry: `text`,
`number`, `date`, `days`, `flag`. Encoding it as a single-key object keeps a
hand-edited file readable and keeps decode honest about type.

An empty `rules` array matches nothing, not everything. A crate with no rules
is a crate you have not finished writing, and a sidebar row that silently
means "your whole library" is a worse answer than one that means "nothing
yet".

### A2. Fields and operators

Each field declares a kind, and the evaluator reads a typed optional off the
track and applies the operator to it. One table rather than an operator enum
per field.

| Kind | Fields | Operators |
|---|---|---|
| text | title, artist, album artist, album, genre, comment, file path | is, is not, contains, does not contain, begins with, ends with, is empty, is not empty |
| number | year, bitrate, sample rate, duration, play count, skip count, rating, track number | is, is not, is at least, is at most, is empty |
| date | last played, date added | is before, is after, in the last N days, not in the last N days, is empty |
| choice | format | is, is not |
| flag | has artwork, file exists, is duplicate | is true, is false |

`has artwork` reads the track's own artwork hash and falls back to its
album's, so a track in an album with a folder cover counts as covered. That is
what makes "no cover art" resolve to the same albums the artwork audit
reports, rather than to every track that happens to carry no embedded image.

`RuleField.kind` and `RuleFieldKind.operators` are what the editor reads to
populate its menus, so a new field is one case and one row in this table
rather than an edit in the editor's view code.

Two deliberate choices in that table:

- **`is empty` is a number and date operator, not only a text one.** "No year"
  and "never played" are the two most useful rules in the roadmap's list, and
  both are absence, not zero. A track with no year must not match `year is 0`.
- **Rating is a number, not a flag.** "Rated four stars and up" is
  `rating is at least 4`; "unrated" is `rating is empty`. `ListeningStats`
  stores unrated as zero, so the evaluator maps zero to absent for this field
  and nowhere else.

### A3. The context

The expensive facts are computed once per pass, and only when some rule asks
for them.

```swift
public struct RuleContext: Sendable {
    let statsByPath: [String: ListeningStats]
    let metadataByTrack: [UUID: ConversionMetadata]
    let missingPaths: Set<String>?      // nil when no rule reads `fileExists`
    let duplicatePaths: Set<String>?    // nil when no rule reads `isDuplicate`
    let now: Date
}
```

`RuleContext.requirements(for:)` returns which of the two expensive lookups a
set of crates needs, so the caller builds each at most once across every crate
being evaluated, and skips both entirely in the common case where nobody asks.

`now` is injected rather than read inside the evaluator. "Played in the last
thirty days" is otherwise untestable without freezing the clock globally.

A `nil` lookup and an empty lookup mean different things: `nil` is "nobody
asked, do not evaluate this field", and a rule reading a `nil` lookup does not
match. That is the safe direction. The alternative, treating an uncomputed
lookup as "everything is fine", would show a duplicates crate as empty and
read as a fixed library.

### A4. Evaluation

```swift
public enum SmartCrateEvaluator {
    public static func members(of crate: SmartCrate,
                               in tracks: [LoadedTrack],
                               context: RuleContext) -> [LoadedTrack]

    public static func matches(_ track: LoadedTrack,
                               rule: SmartRule,
                               context: RuleContext) -> Bool
}
```

Pure and free of AppKit, like every other Core service. `members` preserves
the input order, so a smart crate arrives at the browser in the same order
`allTracks` is in and the browser's own sort takes it from there.

**Rules match tracks, always.** Where a count reads better as albums, the
caller counts distinct albums among the matched tracks. That keeps a crate
what a crate already is, a list of files, and avoids a second evaluator with
album semantics. "Albums with no cover" is therefore "tracks whose album has
no cover", which resolves to the same set of albums.

### A5. Performance

Each rule is a dictionary lookup and a comparison. At the library size in
front of us, a crate of five rules over six and a half thousand tracks is tens
of thousands of comparisons, which is well under a frame. The two expensive
lookups are the whole cost, and A3 is how they are avoided.

---

## Part B: crates that fill themselves

### B1. Storage

A smart crate is a `<name>.cdsmart` file in the crates index folder, JSON,
pretty-printed and key-sorted like an authored theme, sitting beside the
`.cdcrate` membership lists. Same folder, same backup, same sync.

It carries no track data at all, so it is small, diffable, and shareable in a
way a membership list is not: someone else's "FLAC I have never played"
crate means something on your library.

### B2. The sidebar

A new `LibrarySource` case, listed in the same section as your other crates,
in the same alphabetical order, with a small glyph as the only tell that it
fills itself. Selecting one evaluates it and hands the browser an index built
from the result, so everything downstream, convert, transfer, queue, reveal,
works unchanged.

`LibrarySource.isLocalLibrary` includes it, so a live search carries across
into a smart crate the way it carries between crates today.

### B3. Two tiers of freshness

- **Cheap crates**, whose rules touch only tags, specs and listening data,
  recompute with the index. Their sidebar counts are always live, including
  the match counts a live search puts there.
- **Deferred crates**, whose rules read file existence or duplicate
  membership, show their last known count and refresh when the background
  pass lands. The pass is the same one the health panel's SCAN runs.

The tier is derived from the rules, not stored, so editing a crate moves it
between tiers with no migration.

A count that has never been computed shows as a dash rather than zero. Zero is
an answer; a dash is the truth.

### B4. Editing

A sheet, opened on creation and from the row's context menu: the match toggle,
the rule rows, an add key, and a live count of what currently matches. The
count recomputes as you edit rather than on save, because a rule set you
cannot see the effect of is a rule set you have to save to test.

Deleting a smart crate deletes its file and nothing else. There is no track
data to orphan, which is the pleasant part of a crate that owns no paths.

---

## Part C: library health

### C1. HEALTH as a screen

A new `OLEDView` case with a lamp token of its own, following the pattern the
other six screens already use: a case in the view enum, an accent in
`OLEDView.accent(_:)`, a token in the catalog with a fallback, and an entry in
the display key's cycle and the View menu.

The display shows the five totals. They fit the existing five-cell data rail
exactly, which is the argument for five checks rather than four or nine.

Selecting HEALTH gives the main area to the panel and collapses the browser,
the way the conversion screen already treats the inspector.

### C2. The five checks

Each is a built-in `SmartCrate` value, not a special case in the panel's code.

| Row | Rule | Counted as | FIX opens |
|---|---|---|---|
| No cover art | has artwork is false | albums | batch artwork |
| Files that moved | file exists is false | tracks | the relink flow |
| Probable duplicates | is duplicate is true | groups | the duplicates review |
| No year | year is empty | albums | FIX TAGS |
| Untitled or untagged | title is empty **or** artist is empty | tracks | FIX TAGS |

Four of the five are single-rule crates matching `all`, which is the same as
matching `any` when there is one rule. The last is the exception and the
reason the match mode earns its place: it is two rules under `any`.

Duplicates is counted in groups rather than tracks because a group is the unit
you act on, and it is the one row whose count comes from the grouping engine
rather than from the size of the matched set.

### C3. The three keys

- **OPEN** browses the matched records in the main window, by handing the
  browser the same index a saved smart crate would.
- **KEEP** writes the row's rule set into the crates folder as a real smart
  crate, named for the row, and it appears in the sidebar like any other. The
  panel's rows are unaffected: this is a copy, not a move.
- **FIX** opens the engine in the table above, on the matched set. Nothing is
  written without the confirmation those flows already ask for.

### C4. What retires

`LibraryCleanupView` and the inspector's CLEANUP key go. Its missing-files
pane becomes the detail behind "files that moved", and its duplicates pane
becomes the detail behind "probable duplicates", both reached by OPEN. No
capability is lost, and there is one fewer corner of the app to know about.

---

## Testing

**Core, the bulk.** Every field and operator against a fixture library, both
match modes, and the three absences that are easy to get wrong: a missing
value, an empty string, and a zero that must not read as absent. The
clock-dependent operators run against an injected date. A separate test pins
that `RuleContext.requirements(for:)` asks for neither expensive lookup when
no rule needs one, and asks for each exactly once when several crates do,
because that property is what holds the sidebar's responsiveness up. The five
built-in checks are tested as values: given a fixture library, each selects
the set the row claims.

**App.** A round trip through the crates folder, and a source switch into a
smart crate leaving the browser in a sane state.

## Sequencing

Two implementation plans, in this order:

1. **Part A and Part B.** The engine, storage, the sidebar and the editor. It
   ships as a usable feature on its own: crates that fill themselves.
2. **Part C.** The screen, the panel and the fix routing, on top of an engine
   that is already tested and shipping.

Part C is where the retirement of the cleanup sheet happens, so nothing is
removed until its replacement is in front of the user.
