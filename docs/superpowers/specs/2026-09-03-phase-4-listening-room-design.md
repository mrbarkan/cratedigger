# 2.0 Phase 4: the listening room — Design

**Date:** 2026-09-03
**Branch:** v2 (beta line)
**Scope:** the roadmap's Phase 4: resume where you left off, a STATS screen
on the OLED built on the Phase 0 listening data, and the last missing piece
of an editable queue (drag to reorder). This is the final feature phase
before 2.0 ships; smart crates and library health (Phases 2 and 3) are
deferred past 2.0.

---

## Why this exists

The roadmap's Phase 4 is three sentences:

> A queue you can actually edit: drag to reorder, play this next, see what
> is coming. Resume where you left off when you reopen the app. And a stats
> view on the glass, built on Phase 0 data, showing your most played records
> of the month and the year. Cheap to build, genuinely fun, and precisely
> the sort of thing an OLED panel on a piece of imaginary hardware should be
> doing.

It is also the phase that answers the roadmap's opening complaint: that
CrateDigger is a workshop you open for a job and close, not the app you open
on a Tuesday night because you want to hear something. An app that comes
back where you left it, and that can tell you what you have been listening
to, is one you leave open.

### What the survey found

**The queue is already built.** `LibraryViewModel+Queue.swift` has
`playNext`, `playLast`, `removeFromQueue`, `clearUpNext`, `moveInQueue` and
`playFromQueue`, all keeping `playback.queue` and `playbackQueue` in step.
`QueueInspectorView` is the QUEUE tab in the inspector: Up Next with a count
and total duration, CLEAR, per-row Play Now / Remove / Move up / Move down.
The Playback menu has Play Next (⌘N), Play Last and Clear Up Next. The only
roadmap word not yet true is *drag*.

**Nothing resumes.** `LibraryViewModel.init` restores the OLED view, shuffle,
repeat, DSD mode, volume and every sort, then calls `selectSource(.localAll)`
and stops. The transport starts empty every launch.

**The listening data cannot answer "this month".** `ListeningStats` holds a
lifetime `playCount`, a `skipCount`, one `lastPlayed`, `dateAdded` and
`rating`. There is no record of *when* each play happened, so "most played
this month" has nothing to read. Adding that record is the one model change
in this phase, and the one place it could go wrong: `library.cdplays` is
rewritten on every counted play, so whatever is added must not grow with
listening time.

**A paused load already fires the tick a deferred seek waits for.**
`PlaybackService.bindEngineCallbacks` sets `durationSeconds` in
`onItemReady` before deciding whether to auto-play, and `durationSeconds`'s
`didSet` calls `notifyTimeChange()`. Record Divider's
`applyPendingRecordSeekIfNeeded` (`+RecordDivider.swift:240`) already
consumes exactly that tick to seek once the file is ready. Resume can ride
the same mechanism.

**Every OLED screen is one `View` on one scaffold.** `OLEDPaneScaffold`
(headline, readout, ticker, cells) plus `NPTitles` and `OLEDCells` is the
whole kit; `SearchPane` (`OLEDDisplay.swift:1072`) is 80 lines on it. A
screen is a case in `OLEDView`, a pane in `DisplayContext`, a label in
`DisplayModeButton`, a lamp token, an entry in the DISPLAY cycle and the
View menu.

## Non-goals

- No per-artist or per-track stats pages, no listening streaks, no "on this
  day". One screen, three windows. Add when the one screen feels thin.
- No per-play timestamps. See "Play log" below for why a month histogram is
  the right resolution and a date log is not.
- No restoring the *browser* position (source, selection, scroll). The
  browser already restores its view per source; this phase restores the
  *transport*.
- No resuming a radio stream, a CD, or a remote (Subsonic) queue. Local
  files only; the others come back as they are today (nothing loaded).
- No changes to `PlayThreshold`, scrobbling, or how a play is counted.
- Smart crates and library health stay out of 2.0.

---

## Part 1: the play log

### The model change

`ListeningStats` gains one field:

```swift
/// Counted plays per calendar month, keyed "YYYY-MM" in the local calendar
/// at the moment the play was counted. Absent (empty) for anything never
/// played since this field shipped: `playCount` remains the lifetime total
/// and predates it, so the two are not expected to agree.
public var playsByMonth: [String: Int]
```

- `init(from:)` decodes it with `decodeIfPresent(...) ?? [:]`, so every
  `library.cdplays` written before this ships loads unchanged. Same rule the
  struct's own doc comment already states for new fields.
- `encode(to:)` becomes explicit and **omits the key when the dictionary is
  empty**. 14,000 unplayed tracks must not each grow by `"playsByMonth":{}`.
- `recordPlay(at:)` increments `playsByMonth[monthKey(date)]` alongside
  `playCount` and `lastPlayed`.
- `ListeningStats.monthKey(for: Date, calendar: Calendar = .current) ->
  String` is a static helper that formats `"%04d-%02d"` from the calendar's
  year and month components. `ListeningSummary` uses the same helper to
  build its window keys, so the two can never disagree on a boundary.
- `ListeningStore.merge` (the repoint path) sums the two dictionaries key by
  key. `playCount` keeps its `max` rule: the histogram is added on top of
  the existing merge, not in place of it.

### Why a month histogram and not a date log

The user's constraint on this phase is that nothing "sucks up resources or
builds up in time to a giant text file". A date log fails it; a histogram
passes it.

- **Growth is bounded by tracks × months, not by plays.** A track played
  forty times in September is one entry, `"2026-09": 40`. The worst case is
  every played track touched in every month, which is still linear in
  library size per year, and real listening is far below it. Fifty plays a
  day across a normal rotation is on the order of tens of KB per year.
  A date log at the same rate is ~450 KB per year, and `library.cdplays` is
  rewritten atomically on every counted play.
- **Month resolution is all the screen needs.** The three windows are
  calendar month, calendar year and all time. A year is twelve keys; all
  time is `playCount`. Nothing in this phase, or in the deferred smart-crate
  rules ("played this month", "never played"), needs finer.
- **Nothing to compact, ever.** There is no retention policy to write and no
  pruning task to forget.

The file stays canonical (`.sortedKeys`, ISO dates) and the dirty flag still
skips no-op saves. No new writes are added: the histogram rides the save
that a counted play already performs.

### The summary

New file `Sources/CrateDiggerCore/Services/ListeningSummary.swift`.

```swift
public enum ListeningWindow: String, Codable, CaseIterable, Sendable {
    case month, year, allTime

    /// The next window when the STATS period tag is clicked.
    public var next: ListeningWindow { ... }   // month → year → allTime → month

    /// The month keys the window covers, or nil for all time.
    public func monthKeys(now: Date, calendar: Calendar) -> Set<String>?

    /// "SEPTEMBER 2026", "2026", "ALL TIME".
    public func title(now: Date, calendar: Calendar) -> String
}

public struct ListeningSummary: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let name: String       // album title, artist bucket, or track title
        public let detail: String     // artist for an album/track, "" for an artist
        public let plays: Int
    }
    public let window: ListeningWindow
    public let plays: Int
    public let listenedSeconds: Double
    public let recordsTouched: Int
    public let tracksTouched: Int
    public let topRecord: Entry?
    public let topArtist: Entry?
    public let topTrack: Entry?

    public var isEmpty: Bool { plays == 0 }

    public static func compute(
        stats: [String: ListeningStats],
        window: ListeningWindow,
        now: Date = Date(),
        calendar: Calendar = .current,
        resolve: (String) -> LoadedTrack?
    ) -> ListeningSummary
}
```

Rules:

- **Plays in window** per track: for `.allTime`, `playCount`; otherwise the
  sum of `playsByMonth` over `window.monthKeys`. Tracks with zero plays in
  the window are skipped before `resolve` is called, so the pass touches
  only played tracks and never looks up an unplayed one.
- **Unresolvable paths** (a track the store no longer knows) still count
  toward `plays` and `tracksTouched` but not toward any top entry or
  `listenedSeconds`, since there is nothing to name and no duration to sum.
- **Record identity** is `OutputPathPlanner().albumFolderKey(for:)`, the same
  key `LibraryIndex.build` groups by (`LibraryIndex.swift:108`), so the
  screen's "top record" is the browser's album. **Artist identity** is that
  key's `artistBucket`. Track identity is the path.
- `listenedSeconds` is Σ plays × `track.durationSeconds`. An estimate, and
  labelled as one nowhere: hours listened is what the number means to a
  person, and a play is by definition most of the track.
- **Ties** break by name, ascending, so the result is deterministic and
  testable. Nothing fancier.
- Cost: one pass over the stats dictionary, one dictionary lookup per played
  track, three small accumulators. Milliseconds at 14k tracks; not something
  that needs a background task.

`ListeningStore` gains one reader for it:

```swift
/// Every track's stats, for a summary pass. A copy-on-write handle, not a
/// deep copy: nothing is duplicated until someone mutates it.
public var allStats: [String: ListeningStats] { byPath }
```

---

## Part 2: the STATS screen

### Wiring

- `OLEDView.stats`, `label` "Stats". Persisted through `savedOLEDView` like
  every screen except `search`.
- `DisplayModeButton.cycle` becomes `[.nowPlaying, .conversion, .scan,
  .devices, .stats]`; `currentLabel` returns `"STATS"`; `accent(_:)` returns
  `theme.lampStats`.
- View menu: `(.stats, "5")` appended to `displayedViews` in
  `AppDelegate.buildMenus`, so "Stats Display" is ⌘5.
- `DisplayContext`: `case .stats: StatsPane()`.

### The lamp token

`lampStatsOverride: Color?` on `CarbonTheme` beside its six siblings, with
`lampStats: Color { lampStatsOverride ?? sunHi }`. Sun (yellow) is the NOW
lamp; the stats screen is about what you have been playing, so its lamp is
the same family one step brighter, which reads as related without being the
same LED. If `sunHi` does not exist as a named accent, fall back to `sun`
and note the choice in the token's catalog note.

Follows the CLAUDE.md rule for per-part tokens: decoded in
`CarbonTheme.init` from key `"lampStats"`, listed in the override key path
array, a `ColorToken(key: "lampStats", label: "STAT Lamp", ...)` in
`ThemeTokenCatalog`'s lamp group, and a fallback test in
`DisplayLampTokenTests` in the shape of
`testSearchLampFollowsTheTealGlowUntilPinned`, plus its key added to
`testBothNewTokensAreReachableFromTheEditorCatalog`.

### The pane

`StatsPane` in `OLEDDisplay.swift`, on `OLEDPaneScaffold`, beside
`SearchPane`.

- **Headline** (`NPTitles`): top record's title; sub line
  `"<artist> · TOP RECORD · <window title>"`. With nothing played in the
  window: title `"NOTHING YET"` in the dimmed title colour the search pane
  uses at rest, sub line `"Play something · <window title>"`.
- **Readout**: the window's `plays` in the same 34pt thin display face the
  search pane uses for its match count, over a small period tag
  (`OLEDTag`) reading `MONTH` / `YEAR` / `ALL`. The tag is a `Button` with
  `.buttonStyle(.plain)`; clicking it calls `model.cycleStatsWindow()`.
  `carbonTip("Click to change the period")`.
- **Ticker**: empty, like search.
- **Cells** (`OLEDCells`): Top Artist (name / plays), Top Track (title /
  artist), Hours (`listenedSeconds / 3600`, one decimal under 10, whole
  above), Records (`recordsTouched` / "Played"), Tracks (`tracksTouched` /
  "Played"). A cell with nothing to show reads `"—"`, the pane's existing
  convention.
- Long names truncate with `lineLimit(1)` exactly as `NPTitles` already
  does; nothing wraps on the glass.

### View-model state

In a new `LibraryViewModel+Stats.swift` under `UI/Carbon/Library/`, so the
main file does not grow:

```swift
@Published var statsWindow: ListeningWindow      // persisted: prefs.savedStatsWindow
@Published private(set) var listeningSummary: ListeningSummary?
private var listeningSummaryIsStale = true       // stored in the main file's property block

func cycleStatsWindow()                          // statsWindow = statsWindow.next
func markListeningSummaryStale()                 // sets the flag; recomputes at once if the STATS screen is showing
func refreshListeningSummaryIfNeeded()           // no-op unless stale; compute and clear the flag
```

Recompute policy, so the pass never runs more than it has to:

- `markListeningSummaryStale()` is called from `recordPlayIfThresholdMet`
  after the store records the play, from `resetListeningStoreCache()`, and
  from the `statsWindow` setter. Nowhere else.
- `refreshListeningSummaryIfNeeded()` is called from the pane's `onAppear`
  (which covers both switching to the screen and relaunching into it, since
  `didSet` does not fire in `init`), and from `markListeningSummaryStale()`
  when `oledView == .stats` already. So: while the screen is showing, a
  counted play updates it; while it is not, nothing is computed until it
  is shown again. A shuffle-heavy evening on the NOW screen costs zero
  summary passes.
- `PreferencesStore.savedStatsWindow: String?` follows the `savedOLEDView`
  pattern; restored in `init` beside it, default `.month`.

---

## Part 3: resume where you left off

### The snapshot

New file `Sources/CrateDiggerCore/Models/PlaybackSnapshot.swift`.

```swift
/// What the transport was doing when the app last quit, enough to put it
/// back: the queue as file paths, which one was loaded, how far in, and
/// the source it was playing from.
public struct PlaybackSnapshot: Codable, Equatable, Sendable {
    /// Bounds the snapshot: the loaded track and up to this many after it.
    /// An "All Records" queue of 14k tracks is not something to serialise on
    /// every pause; 500 is more than anyone scrolls Up Next through.
    public static let maxUpNext = 500

    public var paths: [String]          // ListeningStore.key(for:) form; paths[currentIndex] is the loaded track
    public var currentIndex: Int
    public var positionSeconds: Double
    public var sourceKey: String        // LibrarySource.persistenceKey of playingSource

    /// Build from a live queue, dropping everything before the loaded track
    /// and everything past `maxUpNext` after it. Returns nil for an empty
    /// queue or an index outside it.
    public init?(paths: [String], currentIndex: Int, positionSeconds: Double, sourceKey: String)

    public struct Resolved: Equatable, Sendable {
        public let tracks: [LoadedTrack]
        public let currentIndex: Int
        public let positionSeconds: Double
        public let sourceKey: String
    }

    /// Match the saved paths against what the library knows now. Paths the
    /// store has forgotten are dropped and the index shifts to follow the
    /// loaded track; if the loaded track itself is gone, or its file is
    /// not on disk, there is nothing worth restoring and this returns nil.
    /// Other missing files stay in the queue: playback already skips past a
    /// file that fails to open, and dropping them silently here would make
    /// an unmounted drive look like a shorter queue.
    public func resolve(
        track: (String) -> LoadedTrack?,
        fileExists: (String) -> Bool
    ) -> Resolved?
}
```

The init truncates; `resolve` is the decidable value, and both are the
tested part. The view model does no list arithmetic of its own.

### Storage

`PreferencesStore.playbackSnapshotData: Data?` under key
`"cratedigger.playback.snapshot"`, the `streamSourcesData` pattern. App
global, not per crates folder: the snapshot names its `sourceKey`, and a
path the current folder's store does not know simply resolves away.

Bounded: 500 paths at roughly 100 bytes each is ~50 KB, the same order as
the stream list that already lives there. The encoder uses `.sortedKeys` and
the writer **compares the new bytes with the last written bytes and skips
the write when they match**, so pausing and unpausing the same track does
not touch `UserDefaults` twice.

### Saving

One method, `savePlaybackSnapshot()`, in a new
`LibraryViewModel+Resume.swift` under `UI/Carbon/Library/`. It:

1. Clears the snapshot (`playbackSnapshotData = nil`) and returns when there
   is nothing to come back to: `isStreamActive`, `playbackQueue.isEmpty`,
   `playbackCurrentIndex == nil`, or `playingSource` is `.cd`, `.remote`,
   `.device`, `.offlineDevice` or `.radio`.
2. Otherwise builds `PlaybackSnapshot(paths: playbackQueue.map {
   ListeningStore.key(for: $0.track.fileURL) }, currentIndex:
   playbackCurrentIndex, positionSeconds: playback.currentTimeSeconds,
   sourceKey: playingSource.persistenceKey)` and writes it through the
   compare-then-write rule above.

Called from:

- the `onCurrentIndexChange` binding, after `playbackCurrentIndex` is set;
- `handlePlaybackStateChange` on `.paused` and `.ended`;
- the end of every queue mutation in `+Queue.swift` (`enqueue`,
  `removeFromQueue`, `clearUpNext`, `moveInQueue`, `startQueue`,
  `playFromQueue`) and after each of the two `playback.load(` calls in
  `LibraryViewModel.swift` (four call sites in the app in total, all in
  those two files);
- `AppDelegate.applicationWillTerminate`, via
  `mainWindowController?.model.savePlaybackSnapshot()`. This is the one
  save whose position must be exact; the others are insurance against a
  crash or a force-quit and are cheap because of the byte compare.

Not called on the time tick. Position accuracy at quit is what matters,
and quit is a hook.

### Restoring

`restorePlaybackSnapshot()` in the same extension, called once at the end
of `init` after `selectSource(.localAll)` and before
`recomputeOfflineVolumes()`:

1. Decode `prefs.playbackSnapshotData`; nothing → return.
2. `snapshot.resolve(track: currentTrackStore().track(path:), fileExists:
   FileManager.default.fileExists(atPath:))`; nil → clear the stored
   snapshot and return. No alert: a missing file at launch is not
   something the user did, and the app has never opened with a modal.
3. `playbackQueue = resolved.tracks`; `playingSource` = the source whose
   `persistenceKey` equals `resolved.sourceKey` among `[.localAll,
   .prepCrate] + availableCrates.map(LibrarySource.localCrate)`, else
   `.localAll`. (`persistenceKey` has no inverse and does not need one for
   five shapes.)
4. `pendingSeekTrackID = tracks[currentIndex].track.id`,
   `pendingSeekSeconds = positionSeconds` (see below), then
   `playback.load(queue: tracks.map(Self.queueItem), startIndex:
   resolved.currentIndex, autoPlay: false)`.

The transport comes up paused on the track with its art on the NOW screen,
the queue in the QUEUE tab, and the position applied the moment the item is
ready. `oledView` is left at whatever `savedOLEDView` restored.

### The seek that waits

`pendingRecordSeekTrackID` / `pendingRecordSeekSeconds` and
`applyPendingRecordSeekIfNeeded()` are renamed `pendingSeekTrackID`,
`pendingSeekSeconds` and `applyPendingSeekIfNeeded()`, and move from
`+RecordDivider.swift` to `+Resume.swift`. Record Divider keeps calling
them; the doc comment says both callers. No behaviour change: the guard is
still "the target track is the one loaded and its duration is known", and
that is precisely the state a paused load lands in.

### What resume does not promise

- **Previous-track history before the loaded one is gone.** The snapshot
  starts at the loaded track. Pressing Previous after a relaunch restarts
  the track, as it does at the head of any queue.
- **Listening credit restarts.** `listenedSeconds` is reset on the index
  change the load fires, so a track resumed at 3:00 of 4:00 still needs its
  threshold of *further* listening to count. Fine: it was already counted
  before quitting if it had earned it, and `countedPlayKey` was reset too,
  so it can count again only by being listened to again.
- **Shuffle order is whatever the queue was.** `playbackQueue` is already
  the shuffled order when shuffle is on (`LibraryViewModel.swift:3403`);
  the snapshot saves that order and restores it as is.

---

## Part 4: drag to reorder

`QueueInspectorView.list` swaps `ScrollView { LazyVStack { ForEach ... } }`
for `List { ForEach ... .onMove(perform:) }` with `.listStyle(.plain)`,
`.scrollContentBackground(.hidden)`, `.listRowInsets(EdgeInsets())`,
`.listRowSeparator(.hidden)` and `.listRowBackground(Color.clear)` on the
rows, so the Carbon well shows through and `QueueRow` draws exactly as it
does now. The keys (up, down, remove) and the context menu stay.

```swift
.onMove { offsets, destination in
    guard let source = offsets.first else { return }
    let base = (model.playbackCurrentIndex ?? -1) + 1
    model.moveInQueue(from: base + source, to: base + destination)
}
```

`onMove`'s `destination` is a `List` insertion index in the *pre-move*
array, which is the same convention `moveInQueue` already documents and
implements (`clamped > source ? clamped - 1 : clamped`), so the mapping is
`base +`, nothing more. Multi-row drags are not offered (single anchor per
`offsets.first`); the queue has no multi-selection to drag.

`List` is preferred over `.draggable`/`.dropDestination` because it gives
the platform's own reorder gesture and drop indicator for one modifier;
the alternative is a custom drop target per row for the same result.

---

## Tests

All new logic that decides a value is in Core with a test, per CLAUDE.md.

**`ListeningStatsTests` / `ListeningStoreTests`** (existing files):
- A stats record without `playsByMonth` decodes with an empty histogram.
- A record with plays round-trips the histogram; a record with none does
  not write the key (assert on the encoded JSON string).
- `recordPlay(at:)` increments the right month key, and two plays in
  different months make two keys.
- `repoint` merging two rows sums their histograms key by key and still
  takes `max` of `playCount`.
- `monthKey(for:calendar:)` for a date on the last second of a month in a
  non-UTC calendar lands in that month, not the next.

**`ListeningSummaryTests`** (new):
- Month window sums only the current month's key; year window sums the
  twelve keys of the calendar year; all time reads `playCount` even when
  the histogram is empty.
- Top record groups two tracks of one album into one entry by
  `albumFolderKey`; top artist groups by `artistBucket`; ties break by name.
- An unresolvable path counts toward `plays` and `tracksTouched` and nothing
  else.
- `listenedSeconds` is Σ plays × duration.
- An empty window is `isEmpty` with every top entry nil.
- `ListeningWindow.next` cycles month → year → allTime → month;
  `title(now:calendar:)` gives "SEPTEMBER 2026" / "2026" / "ALL TIME".

**`PlaybackSnapshotTests`** (new):
- The init drops everything before `currentIndex` and truncates to
  `maxUpNext` after it; index becomes 0; nil for an empty queue or an
  out-of-range index.
- `resolve` drops forgotten paths before the loaded track and shifts the
  index; drops forgotten paths after it without moving the index; returns
  nil when the loaded track is forgotten or its file is absent; keeps a
  later track whose file is absent.
- Codable round trip.

**`CrateDiggerAppTests`** (existing files):
- `DisplayLampTokenTests`: `lampStats` follows its fallback until pinned;
  `lampStats` is in the catalog.
- A small `OLEDViewCycleTests`: the DISPLAY cycle and the View menu list
  contain `.stats` and not `.search`. (If the cycle stays `private static`,
  expose it as `static let cycle` internal; the test is worth the visibility.)

The view-model glue (`savePlaybackSnapshot`, the stale flag, the pane)
stays untested, as the rest of the view model is; it is thin by design
because the decidable parts were moved to Core.

---

## Files

Core:
- `Models/ListeningStats.swift` — `playsByMonth`, explicit `encode`,
  `monthKey(for:calendar:)`.
- `Services/ListeningStore.swift` — merge sums histograms; `allStats`.
- `Services/ListeningSummary.swift` — new: `ListeningWindow`,
  `ListeningSummary`.
- `Models/PlaybackSnapshot.swift` — new.
- `Services/PreferencesStore.swift` — `savedStatsWindow`,
  `playbackSnapshotData`.

App:
- `UI/Carbon/Library/LibraryViewModel.swift` — `OLEDView.stats`; the
  `oledView` `didSet` hook; `statsWindow` / `listeningSummary` /
  `listeningSummaryIsStale` stored properties; restore call in `init`;
  `savePlaybackSnapshot()` in the index-change binding and
  `handlePlaybackStateChange`; `markListeningSummaryStale()` in
  `resetListeningStoreCache()`.
- `UI/Carbon/Library/LibraryViewModel+Stats.swift` — new.
- `UI/Carbon/Library/LibraryViewModel+Resume.swift` — new; takes the
  pending-seek trio from `+RecordDivider.swift`.
- `UI/Carbon/Library/LibraryViewModel+Listening.swift` — stale mark after a
  counted play.
- `UI/Carbon/Library/LibraryViewModel+Queue.swift` — snapshot save after
  each mutation.
- `UI/Carbon/Library/LibraryViewModel+RecordDivider.swift` — renamed calls.
- `UI/Carbon/Header/OLEDDisplay.swift` — `StatsPane`, `DisplayContext` case.
- `UI/Carbon/Header/DisplayModeButton.swift` — cycle, label, accent.
- `UI/Carbon/Inspector/QueueInspectorView.swift` — `List` + `.onMove`.
- `UI/Theme/CarbonTheme.swift`, `UI/Theme/ThemeTokenCatalog.swift` —
  `lampStats`.
- `AppDelegate.swift` — View menu entry; snapshot save in
  `applicationWillTerminate`.

Docs:
- `CHANGELOG.md` — beta 9 entry.
- `website/roadmap.html` — Phase 4 marked shipped; Phases 2 and 3 moved
  under a "After 2.0" heading with one sentence saying why (they are the
  workshop half of the list; 2.0 ships the listening half first).
- `CLAUDE.md` — one paragraph under "Listening history" for the histogram
  rule and the resume snapshot, so the next reader knows `playCount` and
  `playsByMonth` are allowed to disagree.

---

## Resource budget, stated plainly

- `library.cdplays` grows by one short entry per (played track, month).
  No entry for unplayed tracks. No timestamps. No compaction needed.
- The summary is computed only when the STATS screen is showing and
  something changed. Never on a redraw, never on a time tick.
- The resume snapshot is at most 501 paths (~50 KB), written to
  `UserDefaults` only when its bytes changed, never on a time tick.
- Restore is one dictionary lookup per saved path at launch, then the
  same `load` a click on a track performs.
