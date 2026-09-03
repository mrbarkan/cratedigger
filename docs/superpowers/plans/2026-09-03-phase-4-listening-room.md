# Phase 4: The Listening Room Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resume the transport where it was left at quit, put a STATS screen on the OLED showing the most played records of the month, the year and all time, and let the queue be reordered by drag.

**Architecture:** One model change in Core (`ListeningStats.playsByMonth`, a per-month histogram rather than a date log, so the plays file is bounded by tracks × months), one pure summariser (`ListeningSummary.compute`), one pure snapshot type (`PlaybackSnapshot` with a tested `resolve`), and thin view-model wiring in two new `LibraryViewModel+*.swift` extensions. The stats pass runs only while the STATS screen is showing and something changed; the snapshot is capped at 501 paths and written only when its bytes differ.

**Tech Stack:** Swift 5.9+, SwiftUI + AppKit, XCTest via `scripts/test.sh`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-03-phase-4-listening-room-design.md`

## Global Constraints

- Branch is `v2`. Commit there; never touch `main`.
- Run tests with `scripts/test.sh` (never bare `swift test`). One class: `scripts/test.sh --filter ClassName`. One method: `scripts/test.sh --filter ClassName/testName`.
- Build with `swift build`. The debug binary is `.build/arm64-apple-macosx/debug/CrateDiggerApp`; stop a running copy with `pkill -f CrateDiggerApp`.
- Every decidable value goes in `CrateDiggerCore` with an XCTest. View-model glue stays in `CrateDiggerApp` and is untested.
- `ListeningStats` is persisted with no migration: every new field must decode with a default when absent.
- User-facing copy (OLED strings, changelog, roadmap page) must not contain em dashes or en dashes. Use commas, colons, or " · ".
- `LibraryViewModel.swift` is ~4300 lines; add stored properties there only when an extension needs them, and put behaviour in the `+Stats` / `+Resume` extensions.
- New theme tokens follow the existing lamp pattern: override property, computed fallback, decode line, override key path in `monochromeGlass`, catalog swatch, fallback test.
- Commit messages: imperative, `type(scope): summary`, ending with the two attribution lines:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_018QEgsfNnYJM71UyWWHR8TL
  ```

---

## File Map

Core (`Sources/CrateDiggerCore`):
- `Models/ListeningStats.swift` — modify: `playsByMonth`, explicit `encode`, `monthKey`.
- `Services/ListeningStore.swift` — modify: merge sums histograms; `allStats`.
- `Services/ListeningSummary.swift` — create: `ListeningWindow`, `ListeningSummary`.
- `Models/PlaybackSnapshot.swift` — create.
- `Services/PreferencesStore.swift` — modify: `savedStatsWindow`, `playbackSnapshotData`.

App (`Sources/CrateDiggerApp`):
- `UI/Theme/CarbonTheme.swift`, `UI/Theme/ThemeTokenCatalog.swift` — modify: `lampStats`.
- `UI/Carbon/Library/LibraryViewModel.swift` — modify: `OLEDView.stats`; stored properties; hooks.
- `UI/Carbon/Library/LibraryViewModel+Stats.swift` — create.
- `UI/Carbon/Library/LibraryViewModel+Resume.swift` — create (absorbs the pending-seek trio).
- `UI/Carbon/Library/LibraryViewModel+RecordDivider.swift` — modify: renamed pending-seek calls.
- `UI/Carbon/Library/LibraryViewModel+Listening.swift` — modify: stale mark after a counted play.
- `UI/Carbon/Library/LibraryViewModel+Queue.swift` — modify: snapshot save after each mutation.
- `UI/Carbon/Header/DisplayModeButton.swift` — modify: cycle, label, accent.
- `UI/Carbon/Header/OLEDDisplay.swift` — modify: `StatsPane`, `DisplayContext` case.
- `UI/Carbon/Inspector/QueueInspectorView.swift` — modify: `List` + `.onMove`.
- `AppDelegate.swift` — modify: View menu; terminate hook.

Tests:
- `Tests/CrateDiggerCoreTests/ListeningStoreTests.swift` — modify.
- `Tests/CrateDiggerCoreTests/ListeningSummaryTests.swift` — create.
- `Tests/CrateDiggerCoreTests/PlaybackSnapshotTests.swift` — create.
- `Tests/CrateDiggerAppTests/DisplayLampTokenTests.swift` — modify.
- `Tests/CrateDiggerAppTests/OLEDViewCycleTests.swift` — create.

Docs: `CHANGELOG.md`, `website/roadmap.html`, `CLAUDE.md`.

---

### Task 1: `playsByMonth` on `ListeningStats`

**Files:**
- Modify: `Sources/CrateDiggerCore/Models/ListeningStats.swift`
- Test: `Tests/CrateDiggerCoreTests/ListeningStoreTests.swift` (class `ListeningStatsTests`)

**Interfaces:**
- Produces: `ListeningStats.playsByMonth: [String: Int]`; `static func monthKey(year: Int, month: Int) -> String`; `static func monthKey(for date: Date, calendar: Calendar = .current) -> String`; `mutating func recordPlay(at date: Date, calendar: Calendar = .current)`.

- [ ] **Step 1: Write the failing tests**

Add to `ListeningStatsTests` in `Tests/CrateDiggerCoreTests/ListeningStoreTests.swift`, after `testRecordingAPlayCountsItAndStampsTheDate`:

```swift
    /// A fixed calendar so the month boundary in these tests is not the
    /// machine's time zone.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testAPlayLandsInItsCalendarMonth() {
        var stats = ListeningStats(dateAdded: added)
        // 2026-09-03T12:00:00Z
        let september = Date(timeIntervalSince1970: 1_788_436_800)
        stats.recordPlay(at: september, calendar: utc)
        stats.recordPlay(at: september.addingTimeInterval(3600), calendar: utc)
        // 2026-10-01T00:00:00Z, the first second of the next month.
        stats.recordPlay(at: Date(timeIntervalSince1970: 1_790_812_800), calendar: utc)
        XCTAssertEqual(stats.playsByMonth, ["2026-09": 2, "2026-10": 1])
        XCTAssertEqual(stats.playCount, 3, "the lifetime count still moves with every play")
    }

    func testTheMonthKeyRespectsTheCalendarsTimeZone() {
        // 2026-09-30T23:30:00Z is still September in UTC but already October
        // in Auckland (UTC+13 in its summer).
        let lateSeptember = Date(timeIntervalSince1970: 1_790_811_000)
        XCTAssertEqual(ListeningStats.monthKey(for: lateSeptember, calendar: utc), "2026-09")
        var auckland = Calendar(identifier: .gregorian)
        auckland.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        XCTAssertEqual(ListeningStats.monthKey(for: lateSeptember, calendar: auckland), "2026-10")
        XCTAssertEqual(ListeningStats.monthKey(year: 2026, month: 3), "2026-03")
    }

    func testAnOldRecordWithoutAHistogramStillDecodes() throws {
        let json = #"{"playCount": 4, "skipCount": 0, "dateAdded": 1700000000.0, "rating": 0}"#
        let stats = try JSONDecoder().decode(ListeningStats.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(stats.playsByMonth, [:])
        XCTAssertEqual(stats.playCount, 4, "plays counted before the histogram shipped are not lost")
    }

    func testAnEmptyHistogramIsNotWrittenAndAFullOneRoundTrips() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let unplayed = ListeningStats(dateAdded: added)
        let unplayedJSON = String(decoding: try encoder.encode(unplayed), as: UTF8.self)
        XCTAssertFalse(unplayedJSON.contains("playsByMonth"),
                       "an unplayed track must not grow by an empty histogram")

        var played = ListeningStats(dateAdded: added)
        played.recordPlay(at: Date(timeIntervalSince1970: 1_788_436_800), calendar: utc)
        let data = try encoder.encode(played)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""playsByMonth":{"2026-09":1}"#))
        let decoded = try JSONDecoder().decode(ListeningStats.self, from: data)
        XCTAssertEqual(decoded, played)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh --filter ListeningStatsTests`
Expected: compile failure, `playsByMonth` and `monthKey` are not defined.

- [ ] **Step 3: Implement the field, the key helper, the explicit coding**

In `Sources/CrateDiggerCore/Models/ListeningStats.swift`:

Add the stored property after `rating`'s `didSet` block:

```swift
    /// Counted plays per calendar month, keyed "YYYY-MM" in the local calendar
    /// at the moment the play was counted. Empty for anything not played since
    /// this field shipped: `playCount` is the lifetime total and predates it, so
    /// the two are not expected to agree. All Time on the STATS screen reads
    /// `playCount`; Month and Year read this.
    ///
    /// A histogram rather than a list of dates on purpose: the plays file is
    /// rewritten on every counted play, so it must be bounded by tracks times
    /// months, not by how much someone listens.
    public var playsByMonth: [String: Int]
```

Extend `init(...)` with a trailing parameter and assignment:

```swift
    public init(
        playCount: Int = 0,
        skipCount: Int = 0,
        lastPlayed: Date? = nil,
        dateAdded: Date,
        rating: Int = 0,
        playsByMonth: [String: Int] = [:]
    ) {
        self.playCount = playCount
        self.skipCount = skipCount
        self.lastPlayed = lastPlayed
        self.dateAdded = dateAdded
        self.rating = min(max(rating, 0), 5)
        self.playsByMonth = playsByMonth
    }
```

In `init(from:)`, after the rating line:

```swift
        self.playsByMonth = try container.decodeIfPresent([String: Int].self, forKey: .playsByMonth) ?? [:]
```

Add the case to `CodingKeys`:

```swift
        case playsByMonth
```

Add an explicit encoder after `CodingKeys` (the synthesized one would write `"playsByMonth":{}` into every unplayed record):

```swift
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(playCount, forKey: .playCount)
        try container.encode(skipCount, forKey: .skipCount)
        // encodeIfPresent, as the synthesized encoder did, so an existing file's
        // bytes do not change on its next save.
        try container.encodeIfPresent(lastPlayed, forKey: .lastPlayed)
        try container.encode(dateAdded, forKey: .dateAdded)
        try container.encode(rating, forKey: .rating)
        if !playsByMonth.isEmpty {
            try container.encode(playsByMonth, forKey: .playsByMonth)
        }
    }
```

Add the key helpers and change `recordPlay`:

```swift
    /// The histogram key for a year and month: "2026-09". One formatter for the
    /// store and the summary, so a window can never miss a month over a
    /// formatting difference.
    public static func monthKey(year: Int, month: Int) -> String {
        String(format: "%04d-%02d", year, month)
    }

    public static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return monthKey(year: parts.year ?? 0, month: parts.month ?? 0)
    }

    public mutating func recordPlay(at date: Date, calendar: Calendar = .current) {
        playCount += 1
        lastPlayed = date
        playsByMonth[Self.monthKey(for: date, calendar: calendar), default: 0] += 1
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test.sh --filter ListeningStatsTests`
Expected: all pass, including the pre-existing ones.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Models/ListeningStats.swift Tests/CrateDiggerCoreTests/ListeningStoreTests.swift
git commit -m "feat(listening): count plays per calendar month

A histogram keyed YYYY-MM rather than a date log, so the plays file is
bounded by tracks times months instead of growing with every play. Omitted
from the file when empty; playCount stays the lifetime truth.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018QEgsfNnYJM71UyWWHR8TL"
```

---

### Task 2: the store merges histograms and exposes them

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/ListeningStore.swift`
- Test: `Tests/CrateDiggerCoreTests/ListeningStoreTests.swift` (class `ListeningStorePersistenceTests`)

**Interfaces:**
- Consumes: `ListeningStats.playsByMonth`, `ListeningStats.monthKey(for:)` (Task 1).
- Produces: `ListeningStore.allStats: [String: ListeningStats]`.

- [ ] **Step 1: Write the failing tests**

Add to `ListeningStorePersistenceTests`, after `testRepointOnATieMergesRatingAndSkipInsteadOfDroppingOne`:

```swift
    func testRepointOntoAnExistingRowSumsTheMonthHistograms() throws {
        let store = ListeningStore(fileURL: fileURL)
        let old = ListeningStore.key(for: trackA)
        let new = ListeningStore.key(for: trackB)
        let september = Date(timeIntervalSince1970: 1_788_436_800)
        let october = Date(timeIntervalSince1970: 1_790_812_800)

        store.recordPlay(path: old, at: september)
        store.recordPlay(path: old, at: september)
        store.recordPlay(path: new, at: september)
        store.recordPlay(path: new, at: october)

        store.repoint(from: old, to: new)

        let merged = try XCTUnwrap(store.stats(path: new))
        let sep = ListeningStats.monthKey(for: september)
        let oct = ListeningStats.monthKey(for: october)
        XCTAssertEqual(merged.playsByMonth[sep], 3, "both rows' September plays survive the move")
        XCTAssertEqual(merged.playsByMonth[oct], 1)
        XCTAssertEqual(merged.playCount, 2, "playCount keeps its max rule; the histogram is added on top")
    }

    func testAllStatsHandsBackEveryRow() {
        let store = ListeningStore(fileURL: fileURL)
        store.recordPlay(path: ListeningStore.key(for: trackA), at: now)
        store.recordSkip(path: ListeningStore.key(for: trackB))
        let all = store.allStats
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[ListeningStore.key(for: trackA)]?.playCount, 1)
        XCTAssertEqual(all[ListeningStore.key(for: trackB)]?.skipCount, 1)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh --filter ListeningStorePersistenceTests`
Expected: `allStats` does not compile; the merge test fails on `playsByMonth[sep]` being 1 rather than 3 once it does.

- [ ] **Step 3: Implement**

In `Sources/CrateDiggerCore/Services/ListeningStore.swift`, under `// MARK: - Reading`, after `allPaths`:

```swift
    /// Every row, for a summary pass. A copy-on-write handle to the same
    /// storage, not a deep copy: nothing is duplicated until someone mutates it.
    public var allStats: [String: ListeningStats] { byPath }
```

Replace the body of `private static func merge(_ a:_ b:)` with:

```swift
    private static func merge(_ a: ListeningStats, _ b: ListeningStats) -> ListeningStats {
        var merged = ListeningStats(
            playCount: max(a.playCount, b.playCount),
            skipCount: max(a.skipCount, b.skipCount),
            lastPlayed: [a.lastPlayed, b.lastPlayed].compactMap { $0 }.max(),
            // The track entered the library when the first of these rows was
            // created, not the second.
            dateAdded: min(a.dateAdded, b.dateAdded),
            // Two rows' months are two partial histories of one file: add them.
            playsByMonth: a.playsByMonth.merging(b.playsByMonth, uniquingKeysWith: +)
        )
        // 0 means unrated, so a real rating must never lose to an unrated row.
        merged.rating = a.rating != 0 ? a.rating : b.rating
        return merged
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test.sh --filter ListeningStorePersistenceTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/ListeningStore.swift Tests/CrateDiggerCoreTests/ListeningStoreTests.swift
git commit -m "feat(listening): merge month histograms on repoint, expose every row

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018QEgsfNnYJM71UyWWHR8TL"
```

---

### Task 3: `ListeningWindow` and `ListeningSummary`

**Files:**
- Create: `Sources/CrateDiggerCore/Services/ListeningSummary.swift`
- Test: `Tests/CrateDiggerCoreTests/ListeningSummaryTests.swift`

**Interfaces:**
- Consumes: `ListeningStats` (Task 1), `OutputPathPlanner().albumFolderKey(for:)` → `AlbumFolderKey` with `.artistBucket` and `.album` (existing), `LoadedTrack`.
- Produces: `ListeningWindow` (`.month`, `.year`, `.allTime`; `next`, `monthKeys(now:calendar:)`, `title(now:calendar:)`), `ListeningSummary` (`window`, `plays`, `listenedSeconds`, `recordsTouched`, `tracksTouched`, `topRecord`, `topArtist`, `topTrack`, `isEmpty`), `ListeningSummary.Entry` (`name`, `detail`, `plays`), `ListeningSummary.compute(stats:window:now:calendar:resolve:)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CrateDiggerCoreTests/ListeningSummaryTests.swift`:

```swift
#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class ListeningSummaryTests: XCTestCase {

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    /// 2026-09-03T12:00:00Z
    private let now = Date(timeIntervalSince1970: 1_788_436_800)
    private let added = Date(timeIntervalSince1970: 1_700_000_000)

    private func track(_ path: String, title: String, artist: String, album: String, duration: Double) -> LoadedTrack {
        LoadedTrack(
            track: AudioTrack(fileURL: URL(fileURLWithPath: path), title: title, artist: artist,
                              album: album, durationSeconds: duration, artworkSource: .none),
            metadata: ConversionMetadata(title: title, artist: artist, album: album)
        )
    }

    private func stats(playCount: Int = 0, months: [String: Int] = [:]) -> ListeningStats {
        ListeningStats(playCount: playCount, dateAdded: added, playsByMonth: months)
    }

    private lazy var library: [String: LoadedTrack] = [
        "/m/kob/1.flac": track("/m/kob/1.flac", title: "So What", artist: "Miles Davis", album: "Kind of Blue", duration: 540),
        "/m/kob/2.flac": track("/m/kob/2.flac", title: "Freddie Freeloader", artist: "Miles Davis", album: "Kind of Blue", duration: 580),
        "/m/bb/1.flac":  track("/m/bb/1.flac", title: "Birdland", artist: "Weather Report", album: "Heavy Weather", duration: 360),
    ]

    private func resolve(_ path: String) -> LoadedTrack? { library[path] }

    // MARK: Windows

    func testTheWindowsCycleMonthYearAllTime() {
        XCTAssertEqual(ListeningWindow.month.next, .year)
        XCTAssertEqual(ListeningWindow.year.next, .allTime)
        XCTAssertEqual(ListeningWindow.allTime.next, .month)
    }

    func testWindowTitlesReadLikeTheGlass() {
        XCTAssertEqual(ListeningWindow.month.title(now: now, calendar: utc), "SEPTEMBER 2026")
        XCTAssertEqual(ListeningWindow.year.title(now: now, calendar: utc), "2026")
        XCTAssertEqual(ListeningWindow.allTime.title(now: now, calendar: utc), "ALL TIME")
    }

    func testWindowKeysCoverExactlyTheirMonths() {
        XCTAssertEqual(ListeningWindow.month.monthKeys(now: now, calendar: utc), ["2026-09"])
        let year = ListeningWindow.year.monthKeys(now: now, calendar: utc)
        XCTAssertEqual(year?.count, 12)
        XCTAssertTrue(year?.contains("2026-01") == true)
        XCTAssertTrue(year?.contains("2026-12") == true)
        XCTAssertFalse(year?.contains("2025-12") == true)
        XCTAssertNil(ListeningWindow.allTime.monthKeys(now: now, calendar: utc))
    }

    // MARK: Counting

    func testMonthWindowReadsOnlyThisMonth() {
        let all = [
            "/m/kob/1.flac": stats(playCount: 10, months: ["2026-09": 3, "2026-08": 7]),
        ]
        let summary = ListeningSummary.compute(stats: all, window: .month, now: now, calendar: utc, resolve: resolve)
        XCTAssertEqual(summary.plays, 3)
        XCTAssertEqual(summary.tracksTouched, 1)
        XCTAssertEqual(summary.listenedSeconds, 3 * 540)
    }

    func testYearWindowSumsTheCalendarYear() {
        let all = [
            "/m/kob/1.flac": stats(playCount: 10, months: ["2026-01": 2, "2026-09": 3, "2025-12": 5]),
        ]
        let summary = ListeningSummary.compute(stats: all, window: .year, now: now, calendar: utc, resolve: resolve)
        XCTAssertEqual(summary.plays, 5, "December 2025 is not this year")
    }

    func testAllTimeReadsPlayCountEvenWithNoHistogram() {
        let all = ["/m/kob/1.flac": stats(playCount: 42)]
        let summary = ListeningSummary.compute(stats: all, window: .allTime, now: now, calendar: utc, resolve: resolve)
        XCTAssertEqual(summary.plays, 42)
        XCTAssertEqual(summary.topTrack?.name, "So What")
    }

    func testAnEmptyWindowIsEmpty() {
        let all = ["/m/kob/1.flac": stats(playCount: 5, months: ["2026-08": 5])]
        let summary = ListeningSummary.compute(stats: all, window: .month, now: now, calendar: utc, resolve: resolve)
        XCTAssertTrue(summary.isEmpty)
        XCTAssertNil(summary.topRecord)
        XCTAssertNil(summary.topArtist)
        XCTAssertNil(summary.topTrack)
        XCTAssertEqual(summary.recordsTouched, 0)
    }

    // MARK: Grouping

    func testTopRecordGroupsTracksOfOneAlbum() {
        let all = [
            "/m/kob/1.flac": stats(months: ["2026-09": 2]),
            "/m/kob/2.flac": stats(months: ["2026-09": 2]),
            "/m/bb/1.flac":  stats(months: ["2026-09": 3]),
        ]
        let summary = ListeningSummary.compute(stats: all, window: .month, now: now, calendar: utc, resolve: resolve)
        XCTAssertEqual(summary.topRecord?.name, "Kind of Blue", "two tracks of one record outvote one track of another")
        XCTAssertEqual(summary.topRecord?.detail, "Miles Davis")
        XCTAssertEqual(summary.topRecord?.plays, 4)
        XCTAssertEqual(summary.topArtist?.name, "Miles Davis")
        XCTAssertEqual(summary.topTrack?.name, "Birdland", "but the single most played track is still the other one")
        XCTAssertEqual(summary.recordsTouched, 2)
        XCTAssertEqual(summary.tracksTouched, 3)
    }

    func testTiesBreakByNameSoTheAnswerIsStable() {
        let all = [
            "/m/kob/1.flac": stats(months: ["2026-09": 1]),
            "/m/bb/1.flac":  stats(months: ["2026-09": 1]),
        ]
        let summary = ListeningSummary.compute(stats: all, window: .month, now: now, calendar: utc, resolve: resolve)
        XCTAssertEqual(summary.topTrack?.name, "Birdland")
        XCTAssertEqual(summary.topRecord?.name, "Heavy Weather")
    }

    func testAForgottenPathCountsButCannotBeNamed() {
        let all = [
            "/gone/x.flac":  stats(months: ["2026-09": 9]),
            "/m/bb/1.flac":  stats(months: ["2026-09": 1]),
        ]
        let summary = ListeningSummary.compute(stats: all, window: .month, now: now, calendar: utc, resolve: resolve)
        XCTAssertEqual(summary.plays, 10)
        XCTAssertEqual(summary.tracksTouched, 2)
        XCTAssertEqual(summary.recordsTouched, 1)
        XCTAssertEqual(summary.topTrack?.name, "Birdland")
        XCTAssertEqual(summary.listenedSeconds, 360, "no duration for a track nobody can name")
    }
}
#endif
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh --filter ListeningSummaryTests`
Expected: compile failure, `ListeningWindow` / `ListeningSummary` are not defined.

- [ ] **Step 3: Implement**

Create `Sources/CrateDiggerCore/Services/ListeningSummary.swift`:

```swift
import Foundation

/// The period the STATS screen is looking at. Calendar-aligned: "month" is
/// this calendar month, not the last thirty days, because that is what the
/// histogram in `ListeningStats.playsByMonth` can answer exactly.
public enum ListeningWindow: String, Codable, CaseIterable, Sendable {
    case month
    case year
    case allTime

    /// The next window when the period tag on the glass is clicked.
    public var next: ListeningWindow {
        switch self {
        case .month:   return .year
        case .year:    return .allTime
        case .allTime: return .month
        }
    }

    /// The histogram keys the window covers, or nil for all time (which reads
    /// `playCount` instead, since plays before the histogram have no month).
    public func monthKeys(now: Date, calendar: Calendar) -> Set<String>? {
        let parts = calendar.dateComponents([.year, .month], from: now)
        guard let year = parts.year, let month = parts.month else { return nil }
        switch self {
        case .allTime: return nil
        case .month:   return [ListeningStats.monthKey(year: year, month: month)]
        case .year:    return Set((1...12).map { ListeningStats.monthKey(year: year, month: $0) })
        }
    }

    /// "SEPTEMBER 2026", "2026", "ALL TIME". Month names come from the
    /// calendar's locale, so a French machine reads SEPTEMBRE.
    public func title(now: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month], from: now)
        let year = parts.year ?? 0
        switch self {
        case .allTime:
            return "ALL TIME"
        case .year:
            return String(year)
        case .month:
            let index = max(0, min(11, (parts.month ?? 1) - 1))
            return "\(calendar.monthSymbols[index].uppercased()) \(year)"
        }
    }
}

/// What the listening history says about one window: how much, and which
/// record, artist and track came out on top. One pass over the store; the
/// view model caches the result and recomputes only when a play is counted
/// while the STATS screen is showing.
public struct ListeningSummary: Equatable, Sendable {

    public struct Entry: Equatable, Sendable {
        /// Album title, artist bucket, or track title.
        public let name: String
        /// The artist for a record or a track; empty for an artist.
        public let detail: String
        public let plays: Int

        public init(name: String, detail: String, plays: Int) {
            self.name = name
            self.detail = detail
            self.plays = plays
        }
    }

    public let window: ListeningWindow
    public let plays: Int
    /// Σ plays × track duration. An estimate: a play is most of a track by
    /// definition (`PlayThreshold`), and the number people want is hours.
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
    ) -> ListeningSummary {
        let keys = window.monthKeys(now: now, calendar: calendar)
        // The same grouping the browser uses, so "top record" is the browser's
        // album and its artist is the browser's artist row.
        let planner = OutputPathPlanner()

        var plays = 0
        var tracksTouched = 0
        var listenedSeconds = 0.0
        var byRecord: [AlbumFolderKey: Tally] = [:]
        var byArtist: [String: Tally] = [:]
        var byTrack: [String: Tally] = [:]

        for (path, row) in stats {
            let count: Int
            if let keys {
                count = keys.reduce(0) { $0 + (row.playsByMonth[$1] ?? 0) }
            } else {
                count = row.playCount
            }
            guard count > 0 else { continue }
            plays += count
            tracksTouched += 1

            // A path the store has forgotten still happened; it just cannot
            // be named or timed.
            guard let loaded = resolve(path) else { continue }
            listenedSeconds += Double(count) * loaded.track.durationSeconds

            let key = planner.albumFolderKey(for: loaded)
            let albumTitle = loaded.track.album.isEmpty ? key.album : loaded.track.album
            byRecord[key, default: Tally(name: albumTitle, detail: key.artistBucket)].plays += count
            byArtist[key.artistBucket, default: Tally(name: key.artistBucket, detail: "")].plays += count
            byTrack[path, default: Tally(name: loaded.track.title, detail: loaded.track.artist)].plays += count
        }

        return ListeningSummary(
            window: window,
            plays: plays,
            listenedSeconds: listenedSeconds,
            recordsTouched: byRecord.count,
            tracksTouched: tracksTouched,
            topRecord: top(byRecord.values),
            topArtist: top(byArtist.values),
            topTrack: top(byTrack.values)
        )
    }

    private struct Tally {
        let name: String
        let detail: String
        var plays = 0
    }

    /// Most plays wins; on a tie the name that sorts first, so the result is
    /// deterministic rather than whichever the dictionary yielded last.
    private static func top<S: Sequence>(_ tallies: S) -> Entry? where S.Element == Tally {
        tallies.max { a, b in
            if a.plays != b.plays { return a.plays < b.plays }
            return a.name > b.name
        }
        .map { Entry(name: $0.name, detail: $0.detail, plays: $0.plays) }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test.sh --filter ListeningSummaryTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/ListeningSummary.swift Tests/CrateDiggerCoreTests/ListeningSummaryTests.swift
git commit -m "feat(listening): summarise a window of plays into top record, artist and track

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018QEgsfNnYJM71UyWWHR8TL"
```

---

### Task 4: `PlaybackSnapshot`

**Files:**
- Create: `Sources/CrateDiggerCore/Models/PlaybackSnapshot.swift`
- Test: `Tests/CrateDiggerCoreTests/PlaybackSnapshotTests.swift`

**Interfaces:**
- Produces: `PlaybackSnapshot` (`paths`, `currentIndex`, `positionSeconds`, `sourceKey`, `static maxUpNext = 500`, failable `init(paths:currentIndex:positionSeconds:sourceKey:)`, `resolve(track:fileExists:) -> Resolved?`), `PlaybackSnapshot.Resolved` (`tracks`, `currentIndex`, `positionSeconds`, `sourceKey`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/CrateDiggerCoreTests/PlaybackSnapshotTests.swift`:

```swift
#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class PlaybackSnapshotTests: XCTestCase {

    private func track(_ path: String) -> LoadedTrack {
        LoadedTrack(
            track: AudioTrack(fileURL: URL(fileURLWithPath: path), title: path, artist: "", album: "",
                              durationSeconds: 100, artworkSource: .none),
            metadata: ConversionMetadata(title: path)
        )
    }

    private func paths(_ n: Int) -> [String] { (0..<n).map { "/m/\($0).flac" } }

    // MARK: Building

    func testTheSnapshotStartsAtTheLoadedTrack() throws {
        let snapshot = try XCTUnwrap(PlaybackSnapshot(paths: paths(5), currentIndex: 2, positionSeconds: 12.5, sourceKey: "all"))
        XCTAssertEqual(snapshot.paths, ["/m/2.flac", "/m/3.flac", "/m/4.flac"])
        XCTAssertEqual(snapshot.currentIndex, 0)
        XCTAssertEqual(snapshot.positionSeconds, 12.5)
        XCTAssertEqual(snapshot.sourceKey, "all")
    }

    func testTheSnapshotIsCappedAfterTheLoadedTrack() throws {
        let snapshot = try XCTUnwrap(PlaybackSnapshot(paths: paths(2000), currentIndex: 10, positionSeconds: 0, sourceKey: "all"))
        XCTAssertEqual(snapshot.paths.count, PlaybackSnapshot.maxUpNext + 1)
        XCTAssertEqual(snapshot.paths.first, "/m/10.flac")
    }

    func testNothingToSnapshot() {
        XCTAssertNil(PlaybackSnapshot(paths: [], currentIndex: 0, positionSeconds: 0, sourceKey: "all"))
        XCTAssertNil(PlaybackSnapshot(paths: paths(3), currentIndex: 3, positionSeconds: 0, sourceKey: "all"))
        XCTAssertNil(PlaybackSnapshot(paths: paths(3), currentIndex: -1, positionSeconds: 0, sourceKey: "all"))
    }

    func testANegativePositionIsClampedToZero() throws {
        let snapshot = try XCTUnwrap(PlaybackSnapshot(paths: paths(1), currentIndex: 0, positionSeconds: -3, sourceKey: "all"))
        XCTAssertEqual(snapshot.positionSeconds, 0)
    }

    // MARK: Resolving

    private func known(_ set: Set<String>) -> (String) -> LoadedTrack? {
        { set.contains($0) ? self.track($0) : nil }
    }

    func testResolveKeepsWhatTheLibraryKnows() throws {
        let snapshot = try XCTUnwrap(PlaybackSnapshot(paths: paths(4), currentIndex: 0, positionSeconds: 30, sourceKey: "crate:Jazz"))
        let resolved = try XCTUnwrap(snapshot.resolve(track: known(Set(paths(4))), fileExists: { _ in true }))
        XCTAssertEqual(resolved.tracks.map(\.track.fileURL.path), paths(4))
        XCTAssertEqual(resolved.currentIndex, 0)
        XCTAssertEqual(resolved.positionSeconds, 30)
        XCTAssertEqual(resolved.sourceKey, "crate:Jazz")
    }

    func testForgottenPathsAfterTheLoadedTrackAreDroppedWithoutMovingIt() throws {
        let snapshot = try XCTUnwrap(PlaybackSnapshot(paths: paths(4), currentIndex: 0, positionSeconds: 0, sourceKey: "all"))
        let resolved = try XCTUnwrap(snapshot.resolve(track: known(["/m/0.flac", "/m/2.flac"]), fileExists: { _ in true }))
        XCTAssertEqual(resolved.tracks.map(\.track.fileURL.path), ["/m/0.flac", "/m/2.flac"])
        XCTAssertEqual(resolved.currentIndex, 0)
    }

    func testForgottenPathsBeforeTheLoadedTrackShiftTheIndex() throws {
        // A hand-built snapshot with history before the loaded track; the
        // init never produces one, but a decoded file could.
        var snapshot = try XCTUnwrap(PlaybackSnapshot(paths: paths(4), currentIndex: 0, positionSeconds: 0, sourceKey: "all"))
        snapshot.currentIndex = 2
        let resolved = try XCTUnwrap(snapshot.resolve(track: known(["/m/0.flac", "/m/2.flac", "/m/3.flac"]), fileExists: { _ in true }))
        XCTAssertEqual(resolved.tracks.map(\.track.fileURL.path), ["/m/0.flac", "/m/2.flac", "/m/3.flac"])
        XCTAssertEqual(resolved.currentIndex, 1, "the loaded track is now second")
    }

    func testAForgottenLoadedTrackMeansNothingToRestore() throws {
        let snapshot = try XCTUnwrap(PlaybackSnapshot(paths: paths(3), currentIndex: 0, positionSeconds: 0, sourceKey: "all"))
        XCTAssertNil(snapshot.resolve(track: known(["/m/1.flac", "/m/2.flac"]), fileExists: { _ in true }))
    }

    func testAMissingLoadedFileMeansNothingToRestoreButALaterOneStays() throws {
        let snapshot = try XCTUnwrap(PlaybackSnapshot(paths: paths(3), currentIndex: 0, positionSeconds: 0, sourceKey: "all"))
        XCTAssertNil(snapshot.resolve(track: known(Set(paths(3))), fileExists: { $0 != "/m/0.flac" }),
                     "no file on disk for the loaded track: do not put up a track that cannot play")
        let resolved = try XCTUnwrap(snapshot.resolve(track: known(Set(paths(3))), fileExists: { $0 != "/m/2.flac" }))
        XCTAssertEqual(resolved.tracks.count, 3, "a later file being offline is playback's problem, not the snapshot's")
    }

    func testAnOutOfRangeIndexResolvesToNothing() throws {
        var snapshot = try XCTUnwrap(PlaybackSnapshot(paths: paths(2), currentIndex: 0, positionSeconds: 0, sourceKey: "all"))
        snapshot.currentIndex = 5
        XCTAssertNil(snapshot.resolve(track: known(Set(paths(2))), fileExists: { _ in true }))
    }

    // MARK: Coding

    func testRoundTrip() throws {
        let snapshot = try XCTUnwrap(PlaybackSnapshot(paths: paths(3), currentIndex: 1, positionSeconds: 7, sourceKey: "prep"))
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackSnapshot.self, from: data), snapshot)
    }
}
#endif
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh --filter PlaybackSnapshotTests`
Expected: compile failure, `PlaybackSnapshot` is not defined.

- [ ] **Step 3: Implement**

Create `Sources/CrateDiggerCore/Models/PlaybackSnapshot.swift`:

```swift
import Foundation

/// What the transport was doing when the app last quit, enough to put it
/// back: the queue as file paths, which one was loaded, how far in, and the
/// source it was playing from. Saved by `LibraryViewModel+Resume`.
public struct PlaybackSnapshot: Codable, Equatable, Sendable {

    /// Bounds the snapshot: the loaded track and up to this many after it. An
    /// "All Records" queue of 14k tracks is not something to serialise on
    /// every pause, and nobody scrolls Up Next past this.
    public static let maxUpNext = 500

    /// `ListeningStore.key(for:)` form. `paths[currentIndex]` is the loaded track.
    public var paths: [String]
    public var currentIndex: Int
    public var positionSeconds: Double
    /// `LibrarySource.persistenceKey` of the source the queue was started from.
    public var sourceKey: String

    /// Build from a live queue, dropping everything before the loaded track
    /// and everything past `maxUpNext` after it. Nil for an empty queue or an
    /// index outside it: there is nothing to come back to.
    public init?(paths: [String], currentIndex: Int, positionSeconds: Double, sourceKey: String) {
        guard paths.indices.contains(currentIndex) else { return nil }
        let end = min(paths.count, currentIndex + 1 + Self.maxUpNext)
        self.paths = Array(paths[currentIndex..<end])
        self.currentIndex = 0
        self.positionSeconds = max(0, positionSeconds)
        self.sourceKey = sourceKey
    }

    public struct Resolved: Equatable, Sendable {
        public let tracks: [LoadedTrack]
        public let currentIndex: Int
        public let positionSeconds: Double
        public let sourceKey: String
    }

    /// Match the saved paths against what the library knows now. Paths the
    /// store has forgotten are dropped and the index shifts to follow the
    /// loaded track; if the loaded track itself is forgotten, or its file is
    /// not on disk, there is nothing worth restoring and this returns nil.
    ///
    /// Other missing files stay in the queue: playback already skips past a
    /// file that fails to open, and dropping them here would make an
    /// unmounted drive look like a shorter queue.
    public func resolve(
        track: (String) -> LoadedTrack?,
        fileExists: (String) -> Bool
    ) -> Resolved? {
        guard paths.indices.contains(currentIndex) else { return nil }
        let loadedPath = paths[currentIndex]
        guard track(loadedPath) != nil, fileExists(loadedPath) else { return nil }

        var tracks: [LoadedTrack] = []
        tracks.reserveCapacity(paths.count)
        var resolvedIndex = 0
        for (offset, path) in paths.enumerated() {
            guard let loaded = track(path) else { continue }
            if offset == currentIndex { resolvedIndex = tracks.count }
            tracks.append(loaded)
        }
        return Resolved(
            tracks: tracks,
            currentIndex: resolvedIndex,
            positionSeconds: positionSeconds,
            sourceKey: sourceKey
        )
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test.sh --filter PlaybackSnapshotTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Models/PlaybackSnapshot.swift Tests/CrateDiggerCoreTests/PlaybackSnapshotTests.swift
git commit -m "feat(playback): a bounded snapshot of the transport that resolves against the library

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018QEgsfNnYJM71UyWWHR8TL"
```

---

### Task 5: preferences for the stats window and the snapshot

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/PreferencesStore.swift`

**Interfaces:**
- Produces: `PreferencesStore.savedStatsWindow: String?`, `PreferencesStore.playbackSnapshotData: Data?`.

No test: these are two more copies of a pattern (`savedOLEDView`, `streamSourcesData`) with no logic of their own.

- [ ] **Step 1: Add the keys**

In the `private enum Key` block of `Sources/CrateDiggerCore/Services/PreferencesStore.swift`, next to `oledView` (line ~25):

```swift
        static let statsWindow = "cratedigger.ui.statsWindow"
```

and next to `repeatMode` (line ~28):

```swift
        static let playbackSnapshot = "cratedigger.playback.snapshot"
```

- [ ] **Step 2: Add the accessors**

Directly after `savedOLEDView` (under `// MARK: - UI state`):

```swift
    /// `ListeningWindow.rawValue` the STATS screen was last showing.
    public var savedStatsWindow: String? {
        get { defaults.string(forKey: Key.statsWindow) }
        set {
            if let value = newValue {
                defaults.set(value, forKey: Key.statsWindow)
            } else {
                defaults.removeObject(forKey: Key.statsWindow)
            }
        }
    }
```

Directly after `savedRepeatMode`:

```swift
    /// Raw JSON of a `PlaybackSnapshot`: the transport at last quit.
    /// `LibraryViewModel+Resume` owns (de)serialization. Bounded by
    /// `PlaybackSnapshot.maxUpNext`, so this stays in the tens of KB.
    public var playbackSnapshotData: Data? {
        get { defaults.data(forKey: Key.playbackSnapshot) }
        set {
            if let data = newValue {
                defaults.set(data, forKey: Key.playbackSnapshot)
            } else {
                defaults.removeObject(forKey: Key.playbackSnapshot)
            }
        }
    }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/CrateDiggerCore/Services/PreferencesStore.swift
git commit -m "feat(prefs): stats window and playback snapshot keys

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018QEgsfNnYJM71UyWWHR8TL"
```

---

### Task 6: the `lampStats` theme token

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Theme/CarbonTheme.swift:100-120, 445-455, 520-530`
- Modify: `Sources/CrateDiggerApp/UI/Theme/ThemeTokenCatalog.swift:269-272`
- Test: `Tests/CrateDiggerAppTests/DisplayLampTokenTests.swift`

**Interfaces:**
- Produces: `CarbonTheme.lampStatsOverride: Color?`, `CarbonTheme.lampStats: Color` (falls back to `sunHi`), catalog key `"lampStats"`.

- [ ] **Step 1: Write the failing tests**

In `Tests/CrateDiggerAppTests/DisplayLampTokenTests.swift`, after `testSearchLampFollowsTheTealGlowUntilPinned`:

```swift
    /// STATS is the eighth screen. It is about what you have been playing, so
    /// its lamp is the NOW family one step brighter: `sunHi`.
    func testStatsLampFollowsSunHiUntilPinned() {
        let retinted = theme(colors: ["sunHi": "#332211"])
        XCTAssertEqual(retinted.lampStats, retinted.sunHi)

        let pinned = theme(colors: ["lampStats": "#00FF00", "sunHi": "#332211"])
        XCTAssertEqual(pinned.lampStats, Color(hexString: "#00FF00"))
        XCTAssertEqual(pinned.monochromeGlass.lampStats, pinned.oledForeground)
    }
```

And add `"lampStats"` to the assertions in `testBothNewTokensAreReachableFromTheEditorCatalog`:

```swift
        XCTAssertTrue(keys.contains("lampStats"), "lampStats has no swatch in the theme editor")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh --filter DisplayLampTokenTests`
Expected: compile failure on `lampStats`.

- [ ] **Step 3: Implement**

In `Sources/CrateDiggerApp/UI/Theme/CarbonTheme.swift`:

After `public var lampSearchOverride: Color?` (line ~107):

```swift
    public var lampStatsOverride: Color?
```

After the `lampSearch` computed property (line ~117):

```swift
    /// The eighth screen. What you have been playing, so the NOW family one
    /// step brighter: related to the Now Playing lamp without being the same LED.
    public var lampStats: Color { lampStatsOverride ?? sunHi }
```

After the `lampSearchOverride = optionalColor(...)` decode line (line ~451):

```swift
        lampStatsOverride = optionalColor("lampStats", resolvedBase.lampStatsOverride)
```

In `monochromeGlass`'s lamp key path array (line ~527), append `\.lampStatsOverride`:

```swift
        for lamp: WritableKeyPath<CarbonTheme, Color?> in [
            \.lampNowOverride, \.lampConvertOverride, \.lampScanOverride,
            \.lampSyncOverride, \.lampCDOverride, \.lampDevicesOverride,
            \.lampSearchOverride, \.lampStatsOverride,
        ] {
```

Check `CarbonTheme.swift` for any other list that enumerates the lamp override key paths (search `lampSearchOverride`; there are exactly three hits before this task: declaration, decode, `monochromeGlass`). If a fourth appears, add `lampStatsOverride` there too.

In `Sources/CrateDiggerApp/UI/Theme/ThemeTokenCatalog.swift`, after the `lampSearch` token (line ~271), inside the same `Display Lamps` group:

```swift
            ColorToken(key: "lampStats", label: "STAT Lamp",
                       note: "The STAT annunciator and DISPLAY strip on the stats screen. Unset it follows Amber Light.",
                       read: \.lampStats),
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test.sh --filter DisplayLampTokenTests`
Expected: all pass. Also run `scripts/test.sh --filter ThemeDraftSaveTests` and `scripts/test.sh --filter BundledThemeTests` to confirm no bundled theme or round-trip test enumerates the override set by count.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Theme/CarbonTheme.swift Sources/CrateDiggerApp/UI/Theme/ThemeTokenCatalog.swift Tests/CrateDiggerAppTests/DisplayLampTokenTests.swift
git commit -m "feat(theme): a lamp token for the stats screen

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018QEgsfNnYJM71UyWWHR8TL"
```

---

### Task 7: `OLEDView.stats`, the cycle, the menu, and the view-model state

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift:7-30` (enum), `:1103-1109` (stored properties block), `:1323-1330` (init restore), `:3828` (`currentTrackStore` visibility)
- Create: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Stats.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Listening.swift:88-100` (`recordPlayIfThresholdMet`), `:62-66` (`resetListeningStoreCache`)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Header/DisplayModeButton.swift:10-22, 46, 74-84`
- Modify: `Sources/CrateDiggerApp/AppDelegate.swift:948-960`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Header/OLEDDisplay.swift:114-130` (`DisplayContext`)
- Test: `Tests/CrateDiggerAppTests/OLEDViewCycleTests.swift`

**Interfaces:**
- Consumes: `ListeningWindow`, `ListeningSummary` (Task 3); `ListeningStore.allStats` (Task 2); `PreferencesStore.savedStatsWindow` (Task 5); `CarbonTheme.lampStats` (Task 6).
- Produces: `OLEDView.stats`; `LibraryViewModel.statsWindow: ListeningWindow`, `.listeningSummary: ListeningSummary?`, `.cycleStatsWindow()`, `.markListeningSummaryStale()`, `.refreshListeningSummaryIfNeeded()`; `DisplayModeButton.cycle` (internal). Task 8 replaces the placeholder pane.

- [ ] **Step 1: Write the failing test**

Create `Tests/CrateDiggerAppTests/OLEDViewCycleTests.swift`:

```swift
#if canImport(XCTest)
import XCTest
@testable import CrateDiggerApp

/// The DISPLAY key walks the screens a user chooses; SEARCH is summoned by
/// a query and must never appear in the walk, and STATS is the last stop.
final class OLEDViewCycleTests: XCTestCase {

    func testTheDisplayCycleEndsOnStatsAndSkipsSearch() {
        XCTAssertEqual(DisplayModeButton.cycle.last, .stats)
        XCTAssertFalse(DisplayModeButton.cycle.contains(.search))
        XCTAssertEqual(DisplayModeButton.cycle.count, Set(DisplayModeButton.cycle).count, "no screen twice")
    }

    func testEveryScreenHasARailLabel() {
        for view in OLEDView.allCases {
            XCTAssertFalse(view.label.isEmpty, "\(view) has no label")
        }
    }
}
#endif
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `scripts/test.sh --filter OLEDViewCycleTests`
Expected: compile failure, `.stats` does not exist and `cycle` is private.

- [ ] **Step 3: Add the case and its labels**

In `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift`, `enum OLEDView`: add a case after `search` and a label:

```swift
    case search
    /// What you have been playing: most played record, artist and track for
    /// the month, the year, or all time. Persisted like the other chosen
    /// screens; only SEARCH is not.
    case stats
```

```swift
        case .search:     return "Search"
        case .stats:      return "Stats"
```

In `Sources/CrateDiggerApp/UI/Carbon/Header/DisplayModeButton.swift`:

- `accent(_:)`: add `case .stats: return theme.lampStats`.
- Change `private static let cycle` to `static let cycle: [OLEDView] = [.nowPlaying, .conversion, .scan, .devices, .stats]`.
- `currentLabel`: add `case .stats: return "STATS"`.

In `Sources/CrateDiggerApp/AppDelegate.swift`, `displayedViews`:

```swift
        let displayedViews: [(OLEDView, String)] = [
            (.nowPlaying, "1"),
            (.conversion, "2"),
            (.scan, "3"),
            (.devices, "4"),
            (.stats, "5")
        ]
```

In `Sources/CrateDiggerApp/UI/Carbon/Header/OLEDDisplay.swift`, `DisplayContext`, add a temporary case so the switch is exhaustive until Task 8:

```swift
            case .stats:       SearchPane()   // replaced by StatsPane in the next task
```

In the same file, `DisplayRail` (line ~135) prints every screen's annunciator on the glass. Add one after the `SRCH` line and before `ON AIR`:

```swift
                ann("STAT", lit: v == .stats, color: OLEDView.stats.accent(theme))
```

- [ ] **Step 4: Add the stored state to the view model**

In `LibraryViewModel.swift`, directly after the `pendingRecordSeekTrackID` declaration (line ~1108):

```swift
    // MARK: - Stats screen (behaviour in LibraryViewModel+Stats)

    /// The period the STATS screen shows. Persisted; the setter marks the
    /// summary stale so the next look recomputes.
    @Published var statsWindow: ListeningWindow = .month {
        didSet {
            prefs.savedStatsWindow = statsWindow.rawValue
            markListeningSummaryStale()
        }
    }
    /// The cached summary the STATS pane draws. Written only by
    /// `refreshListeningSummaryIfNeeded()`; nil until the screen is first shown.
    @Published var listeningSummary: ListeningSummary?
    /// Set on every counted play, window change and store reset; cleared by
    /// the recompute. The pass never runs unless this is true and the STATS
    /// screen is the one on the glass.
    var listeningSummaryIsStale = true
```

In `init`, after the `savedOLEDView` restore (line ~1325):

```swift
        if let saved = prefs.savedStatsWindow, let window = ListeningWindow(rawValue: saved) {
            statsWindow = window
        }
```

Change `private func currentTrackStore() -> TrackStore` (line ~3828) to `func currentTrackStore() -> TrackStore`, with the comment `/// Not private: the +Stats and +Resume extensions read it.` above it.

- [ ] **Step 5: Create the extension**

Create `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Stats.swift`:

```swift
import CrateDiggerCore
import Foundation

/// The STATS screen: which window it shows and the cached summary it draws.
///
/// The summary is one pass over the listening store, cheap but not free, so
/// it runs only when both are true: something changed (a counted play, a
/// window change, a store reset) and the screen is the one on the glass. An
/// evening of shuffle on the NOW screen costs zero passes.
@MainActor
extension LibraryViewModel {

    func cycleStatsWindow() {
        statsWindow = statsWindow.next
    }

    /// Something the summary reads has changed. Recomputes at once if the
    /// screen is showing, otherwise waits for it to be shown.
    func markListeningSummaryStale() {
        listeningSummaryIsStale = true
        if oledView == .stats { refreshListeningSummaryIfNeeded() }
    }

    /// Recompute if anything changed since the last pass. Called by the pane
    /// on appear and by `markListeningSummaryStale()` while it is showing.
    func refreshListeningSummaryIfNeeded() {
        guard listeningSummaryIsStale else { return }
        listeningSummaryIsStale = false
        let store = currentTrackStore()
        listeningSummary = ListeningSummary.compute(
            stats: currentListeningStore().allStats,
            window: statsWindow,
            resolve: { store.track(path: $0) }
        )
    }
}
```

- [ ] **Step 6: Wire the two stale marks**

In `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Listening.swift`:

In `recordPlayIfThresholdMet`, after `persistListeningStore()`:

```swift
        markListeningSummaryStale()
```

In `resetListeningStoreCache()`, after `listeningSaveFailureAlerted = false`:

```swift
        markListeningSummaryStale()
```

- [ ] **Step 7: Build and run the test**

Run: `swift build && scripts/test.sh --filter OLEDViewCycleTests`
Expected: build succeeds; both tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Stats.swift Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Listening.swift Sources/CrateDiggerApp/UI/Carbon/Header/DisplayModeButton.swift Sources/CrateDiggerApp/UI/Carbon/Header/OLEDDisplay.swift Sources/CrateDiggerApp/AppDelegate.swift Tests/CrateDiggerAppTests/OLEDViewCycleTests.swift
git commit -m "feat(oled): a STATS screen in the display cycle, with a lazily computed summary

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018QEgsfNnYJM71UyWWHR8TL"
```

---

### Task 8: `StatsPane`

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Header/OLEDDisplay.swift` (`DisplayContext` case; new pane after `SearchPane`, line ~1152)

**Interfaces:**
- Consumes: `model.listeningSummary`, `model.statsWindow`, `model.cycleStatsWindow()`, `model.refreshListeningSummaryIfNeeded()` (Task 7); `theme.lampStats` (Task 6); the file's private `OLEDPaneScaffold`, `NPTitles`, `OLEDCellData`, `OLEDCells`, `OLEDTag`, `oledFG`, `oledFGo`.

No unit test: it is a view. Verified by running the app (Step 3).

- [ ] **Step 1: Replace the placeholder case and add the pane**

In `DisplayContext`, replace the temporary `case .stats: SearchPane()` with:

```swift
            case .stats:       StatsPane()
```

After the closing brace of `SearchPane` (before `private struct ScanPane`), add:

```swift
/// STATS: what you have been playing. The headline is the window's top
/// record, the readout its play count with the period tag under it, and the
/// rail names the rest. The tag cycles Month, Year, All Time.
private struct StatsPane: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.carbon) private var theme

    var body: some View {
        OLEDPaneScaffold {
            NPTitles(title: headline, sub: subtitle, titleColor: titleColor)
        } readout: {
            VStack(alignment: .trailing, spacing: 6) {
                Text(playsValue)
                    .font(CarbonFont.display(34, weight: .thin))
                    .foregroundStyle(oledFG)
                Button(action: { model.cycleStatsWindow() }) {
                    OLEDTag(text: periodLabel, ink: theme.lampStats, background: theme.lampStats.opacity(0.14))
                }
                .buttonStyle(.plain)
                .carbonTip("Click to change the period")
            }
            .fixedSize()
        } ticker: {
            EmptyView()
        } cells: {
            OLEDCells(cells)
        }
        // The summary is computed lazily: showing the screen is what asks
        // for it, so a relaunch straight into STATS draws real numbers too.
        .onAppear { model.refreshListeningSummaryIfNeeded() }
    }

    private var summary: ListeningSummary? { model.listeningSummary }
    private var hasPlays: Bool { !(summary?.isEmpty ?? true) }
    private var windowTitle: String { model.statsWindow.title(now: Date(), calendar: .current) }

    private var headline: String {
        summary?.topRecord?.name ?? "NOTHING YET"
    }

    private var titleColor: Color {
        hasPlays ? oledFG : oledFGo(0.45)
    }

    private var subtitle: String {
        guard hasPlays, let record = summary?.topRecord else { return "Play something · \(windowTitle)" }
        return record.detail.isEmpty
            ? "Top record · \(windowTitle)"
            : "\(record.detail) · Top record · \(windowTitle)"
    }

    private var playsValue: String {
        hasPlays ? "\(summary?.plays ?? 0)" : "—"
    }

    private var periodLabel: String {
        switch model.statsWindow {
        case .month:   return "MONTH"
        case .year:    return "YEAR"
        case .allTime: return "ALL"
        }
    }

    private var cells: [OLEDCellData] {
        [
            OLEDCellData(key: "Artist", value: summary?.topArtist?.name ?? "—",
                         sub: summary?.topArtist.map { "\($0.plays) plays" } ?? "Top",
                         valueColor: theme.lampStats),
            OLEDCellData(key: "Track", value: summary?.topTrack?.name ?? "—",
                         sub: summary?.topTrack?.detail.nonEmpty ?? "Top",
                         valueColor: theme.sun),
            OLEDCellData(key: "Hours", value: hoursValue, sub: "Listened"),
            OLEDCellData(key: "Records", value: count(summary?.recordsTouched), sub: "Played"),
            OLEDCellData(key: "Tracks", value: count(summary?.tracksTouched), sub: "Played")
        ]
    }

    private var hoursValue: String {
        guard hasPlays, let seconds = summary?.listenedSeconds, seconds > 0 else { return "—" }
        let hours = seconds / 3600
        return hours < 10 ? String(format: "%.1f", hours) : "\(Int(hours.rounded()))"
    }

    private func count(_ n: Int?) -> String {
        guard hasPlays, let n else { return "—" }
        return "\(n)"
    }
}

private extension String {
    /// nil for "", so a `??` fallback can take over an empty detail line.
    var nonEmpty: String? { isEmpty ? nil : self }
}
```

Note: the "—" placeholder is the OLED's existing rest glyph (`SearchPane` uses it); it is a glyph on the glass, not copy, and is exempt from the no-dash rule.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success.

- [ ] **Step 3: Verify in the app**

Run:

```bash
pkill -f CrateDiggerApp; .build/arm64-apple-macosx/debug/CrateDiggerApp &
```

Check, in order:
1. Press the DISPLAY key five times from NOW: the screens cycle NOW → CNVRT → SCAN → DEV → STATS → NOW, and the strip glows amber-bright on STATS.
2. View menu shows "Stats Display ⌘5"; ⌘5 selects it.
3. With no plays this month, STATS reads "NOTHING YET / PLAY SOMETHING · SEPTEMBER 2026" with "—" in the readout and cells.
4. Click the period tag three times: MONTH → YEAR → ALL → MONTH; the sub line's window title follows.
5. Play a track through (or scrub to past half and let it run 30 s) while STATS is showing: the readout ticks to 1 and the headline names the record without switching screens.
6. Quit and relaunch: STATS is still the selected screen with the same period, and the numbers are there on first draw.

Then `pkill -f CrateDiggerApp`.

- [ ] **Step 4: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Header/OLEDDisplay.swift
git commit -m "feat(oled): the STATS pane

Top record, its plays, and a period tag that cycles month, year and all
time; the rail carries top artist, top track, hours, records and tracks.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018QEgsfNnYJM71UyWWHR8TL"
```

---

### Task 9: resume where you left off

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Resume.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift:1103-1109` (pending-seek properties), `:1412-1418` (init tail), `:3508-3532` (index-change binding), `:3533-3542` (time binding), `:3408-3440` (`handlePlaybackStateChange`), `:2841` (`playTrack` load)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+RecordDivider.swift:218-249`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Queue.swift` (every mutation)
- Modify: `Sources/CrateDiggerApp/AppDelegate.swift:75-80`

**Interfaces:**
- Consumes: `PlaybackSnapshot` (Task 4), `PreferencesStore.playbackSnapshotData` (Task 5), `currentTrackStore()` made internal (Task 7), `Self.queueItem(for:)` and `playback.load(...)` (existing).
- Produces: `LibraryViewModel.savePlaybackSnapshot()`, `.restorePlaybackSnapshot()`, `.applyPendingSeekIfNeeded()`, `pendingSeekTrackID`, `pendingSeekSeconds`.

No unit test: the decidable parts are in `PlaybackSnapshot` (Task 4). Verified by running the app (Step 6).

- [ ] **Step 1: Rename the pending-seek trio**

In `LibraryViewModel.swift` (line ~1103-1108), replace the two properties and their comment with:

```swift
    /// A position to seek to once the target file is loaded and its duration
    /// is known. Two writers: Record Divider (clicking a sub-track before its
    /// file is playing) and resume at launch (a paused load of the last queue).
    /// Consumed by `applyPendingSeekIfNeeded()` in `+Resume`.
    var pendingSeekSeconds: Double?
    var pendingSeekTrackID: UUID?

    /// The last snapshot bytes written, so a pause/unpause of the same track
    /// does not touch UserDefaults twice. See `savePlaybackSnapshot()`.
    var lastSavedPlaybackSnapshot: Data?
```

In `LibraryViewModel+RecordDivider.swift`, in `playRecordTrack(parent:markerIndex:)` replace:

```swift
        pendingRecordSeekTrackID = parent.track.id
        pendingRecordSeekSeconds = start
```

with:

```swift
        pendingSeekTrackID = parent.track.id
        pendingSeekSeconds = start
```

and delete the whole `applyPendingRecordSeekIfNeeded()` function (with its doc comment) from that file.

In `LibraryViewModel.swift`'s `playback.onTimeChange` binding (line ~3538), replace `self?.applyPendingRecordSeekIfNeeded()` with `self?.applyPendingSeekIfNeeded()`.

- [ ] **Step 2: Create the extension**

Create `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Resume.swift`:

```swift
import CrateDiggerCore
import Foundation

/// Resume where you left off: the transport is snapshotted as it changes and
/// put back, paused, at the next launch. The decidable part (what survives a
/// library that has moved on) is `PlaybackSnapshot.resolve`; this file is
/// the wiring.
@MainActor
extension LibraryViewModel {

    // MARK: - Deferred seek

    /// Apply a deferred seek once the target file is loaded and its duration
    /// is known. Called from the playback time binding. A paused load fires
    /// that tick too (`PlaybackService` sets the duration in `onItemReady`
    /// before deciding whether to play), which is what lets resume land on a
    /// position without ever starting playback.
    func applyPendingSeekIfNeeded() {
        guard let seconds = pendingSeekSeconds,
              let id = pendingSeekTrackID,
              nowPlayingTrack?.track.id == id,
              playbackDuration > 0 else { return }
        pendingSeekTrackID = nil
        pendingSeekSeconds = nil
        playback.seek(toSeconds: seconds)
    }

    // MARK: - Snapshot

    /// Sources whose tracks live in the track store and are still there at
    /// the next launch. A CD leaves with the disc, a remote queue with the
    /// session, a device with the cable.
    static func isResumable(_ source: LibrarySource?) -> Bool {
        switch source {
        case .localAll?, .localCrate?, .prepCrate?, .playlist?, nil:
            return true
        case .remote?, .cd?, .device?, .offlineDevice?, .radio?:
            return false
        }
    }

    /// Record the transport. Called on every index change, pause, queue edit
    /// and at quit; cheap because identical bytes are not written twice.
    func savePlaybackSnapshot() {
        guard !isStreamActive,
              let index = playbackCurrentIndex,
              !playbackQueue.isEmpty,
              Self.isResumable(playingSource),
              let snapshot = PlaybackSnapshot(
                paths: playbackQueue.map { ListeningStore.key(for: $0.track.fileURL) },
                currentIndex: index,
                positionSeconds: playback.currentTimeSeconds,
                sourceKey: (playingSource ?? .localAll).persistenceKey
              )
        else {
            clearPlaybackSnapshot()
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(snapshot) else { return }
        guard data != lastSavedPlaybackSnapshot else { return }
        lastSavedPlaybackSnapshot = data
        prefs.playbackSnapshotData = data
    }

    private func clearPlaybackSnapshot() {
        guard lastSavedPlaybackSnapshot != nil || prefs.playbackSnapshotData != nil else { return }
        lastSavedPlaybackSnapshot = nil
        prefs.playbackSnapshotData = nil
    }

    /// Put the last transport back, paused, at launch. Nothing is restored if
    /// the loaded track has left the library or its file is not on disk, and
    /// nothing is said about it: a missing file at launch is not something the
    /// user just did.
    func restorePlaybackSnapshot() {
        guard let data = prefs.playbackSnapshotData else { return }
        guard let snapshot = try? JSONDecoder().decode(PlaybackSnapshot.self, from: data) else {
            clearPlaybackSnapshot()
            return
        }
        let store = currentTrackStore()
        guard let resolved = snapshot.resolve(
            track: { store.track(path: $0) },
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        ) else {
            clearPlaybackSnapshot()
            return
        }

        // `persistenceKey` has no inverse and does not need one for the five
        // shapes that can be here: match by key, else All Records.
        let candidates: [LibrarySource] = [.localAll, .prepCrate]
            + availableCrates.map { LibrarySource.localCrate(name: $0) }
        playingSource = candidates.first { $0.persistenceKey == resolved.sourceKey } ?? .localAll

        playbackQueue = resolved.tracks
        if resolved.positionSeconds > 0 {
            pendingSeekTrackID = resolved.tracks[resolved.currentIndex].track.id
            pendingSeekSeconds = resolved.positionSeconds
        }
        lastSavedPlaybackSnapshot = data
        playback.load(queue: resolved.tracks.map(Self.queueItem), startIndex: resolved.currentIndex, autoPlay: false)
        AppLog.library.notice("Restored playback: \(resolved.tracks.count, privacy: .public) track(s) at \(Int(resolved.positionSeconds), privacy: .public)s")
    }
}
```

If `LibrarySource` has a case not listed in `isResumable`, the switch will not compile: add it to whichever side is right (local files that survive a relaunch → resumable). If `.playlist`'s tracks turn out not to be in the track store, `resolve` returns nil and nothing is restored; that is acceptable and needs no special case.

- [ ] **Step 3: Call the save from every place the transport changes**

In `LibraryViewModel.swift`:

- `playback.onCurrentIndexChange` binding: after `self.noteSleepTrackChanged()`, add `self.savePlaybackSnapshot()`.
- `handlePlaybackStateChange(_:)`: at the top, after the `.ended` sleep line, add:

```swift
        // Pause and end are the natural "I might quit now" moments; the
        // position saved here is insurance against a crash, and the exact one
        // is taken in applicationWillTerminate.
        if state == .paused || state == .ended { savePlaybackSnapshot() }
```

- `playTrack(id:)`: after `playback.load(queue: queueItems, startIndex: startIndex, autoPlay: true)`, add `savePlaybackSnapshot()`.

- `init`: after `selectSource(.localAll)` and before `recomputeOfflineVolumes()`, add `restorePlaybackSnapshot()`.

In `LibraryViewModel+Queue.swift`, add `savePlaybackSnapshot()` as the last statement of:
- `enqueue(_:next:)` (after `showOLEDNotice(...)`),
- `startQueue(_:at:)` (after `playback.load(...)`),
- `removeFromQueue(trackIDs:)` (after the removal loop),
- `clearUpNext()` (both the early-return branch, after `playback.load(queue: [], ...)`, and the end),
- `moveInQueue(from:to:)` (after the insert),
- `playFromQueue(trackID:)` (after `playback.load(...)`).

In `AppDelegate.applicationWillTerminate(_:)`, before the Space-monitor removal:

```swift
        // The one snapshot whose position has to be exact.
        mainWindowController?.model.savePlaybackSnapshot()
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: success. If the compiler reports a `playback.load(` call site not covered above (there are four in the app: one in `playTrack`, three in `+Queue`), add the save after it.

- [ ] **Step 5: Run the Core and App suites**

Run: `scripts/test.sh`
Expected: all pass. Nothing in this task changes tested behaviour, so a failure means a rename was missed.

- [ ] **Step 6: Verify in the app**

```bash
pkill -f CrateDiggerApp; .build/arm64-apple-macosx/debug/CrateDiggerApp &
```

1. Play a track from a crate, let it run to about 1:30, queue two more with Play Last, then pause. ⌘Q.
2. Relaunch. Expected: the transport shows the same track, paused, with the clock at about 1:30 and its art on the NOW screen; the QUEUE tab lists the two queued tracks; the sidebar marks the crate as playing. Press play: it continues from there.
3. ⌘Q while playing (not paused). Relaunch: same result, at the moment of quitting.
4. Play a track, then Clear Up Next, then stop playback by loading an empty source (or quit with nothing playing after `clearUpNext` when nothing was playing). Relaunch: nothing loaded. `defaults read com.<bundle id> cratedigger.playback.snapshot` reports no such key (find the bundle id in `Sources/CrateDiggerApp/Info.plist` or `scripts/package-app.sh`).
5. Play a track, quit, rename the file on disk, relaunch: nothing loaded, no alert. Rename it back.
6. Start a radio stream, quit, relaunch: nothing loaded.

Then `pkill -f CrateDiggerApp`.

- [ ] **Step 7: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Resume.swift Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+RecordDivider.swift Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Queue.swift Sources/CrateDiggerApp/AppDelegate.swift
git commit -m "feat(playback): resume where you left off

The transport is snapshotted on index change, pause, queue edits and at
quit, capped at the loaded track plus 500 and written only when the bytes
changed. At launch it comes back paused at the position, riding the same
deferred seek Record Divider already uses.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018QEgsfNnYJM71UyWWHR8TL"
```

---

### Task 10: drag to reorder in the QUEUE tab

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Inspector/QueueInspectorView.swift:68-90` (`list`)

**Interfaces:**
- Consumes: `model.moveInQueue(from:to:)`, `model.upNextTracks`, `model.playbackCurrentIndex` (existing).

No unit test: it is a view over an already-tested move. Verified by running the app.

- [ ] **Step 1: Replace the list**

Replace the `private var list: some View { ... }` body with:

```swift
    private var list: some View {
        // Offset into the full queue: Up Next starts after the playing track.
        let base = (model.playbackCurrentIndex ?? -1) + 1
        return List {
            ForEach(Array(model.upNextTracks.enumerated()), id: \.element.track.id) { offset, loaded in
                QueueRow(
                    loaded: loaded,
                    position: offset + 1,
                    onPlay: { model.playFromQueue(trackID: loaded.track.id) },
                    onRemove: { model.removeFromQueue(trackIDs: [loaded.track.id]) },
                    onMoveUp: offset > 0
                        ? { model.moveInQueue(from: base + offset, to: base + offset - 1) }
                        : nil,
                    onMoveDown: offset < model.upNextTracks.count - 1
                        ? { model.moveInQueue(from: base + offset, to: base + offset + 2) }
                        : nil
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .onMove { offsets, destination in
                // `destination` is List's insertion index in the pre-move
                // array, the convention `moveInQueue` already implements.
                guard let source = offsets.first else { return }
                model.moveInQueue(from: base + source, to: base + destination)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
```

- [ ] **Step 2: Build and verify in the app**

Run: `swift build && (pkill -f CrateDiggerApp; .build/arm64-apple-macosx/debug/CrateDiggerApp &)`

1. Play a track, Play Last four more, open the QUEUE tab.
2. Drag row 3 above row 1: it lands first and the position numbers renumber 01..04.
3. Drag row 1 to the end: it lands last.
4. Skip to the next track: the order the drag produced is what plays.
5. The up/down/remove hover controls and the Play Now / Remove context menu still work; rows still hover-highlight; the list background is the Carbon well, not a white system list.

If rows render with extra vertical padding from the List's default minimum row height, add `.environment(\.defaultMinListRowHeight, 1)` after `.listStyle(.plain)`.

Then `pkill -f CrateDiggerApp`.

- [ ] **Step 3: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Inspector/QueueInspectorView.swift
git commit -m "feat(queue): drag to reorder Up Next

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018QEgsfNnYJM71UyWWHR8TL"
```

---

### Task 11: docs, changelog, roadmap

**Files:**
- Modify: `CHANGELOG.md:7-40` (the accumulating `## 2.0.0` section)
- Modify: `website/roadmap.html:126-149`
- Modify: `CLAUDE.md:139`

No code. The `press-the-record` skill bumps the version header and takes its release notes from the section; this task only adds the content.

- [ ] **Step 1: CHANGELOG**

In `CHANGELOG.md`, in the `## 2.0.0 (80)` section, insert a paragraph above the "Beta 8 is one fix" paragraph:

```
Beta 9 is the listening room. The app comes back where you left it, paused
on the same track at the same second with the same queue. A STATS screen on
the display shows your most played record, artist and track for the month,
the year, or all time. And Up Next can finally be dragged into order.
```

At the top of the `### Added` list, before "**A logo for every theme.**":

```
- **Resume where you left off.** Quit mid-record and the transport comes
  back paused on the same track, at the same second, with the same Up Next,
  and the crate it was playing from still marked in the sidebar. Press play
  to carry on. Streams, CDs and remote libraries start fresh, as they always
  have.
- **STATS on the display.** An eighth screen, on the DISPLAY key after DEV
  and in the View menu as Command-5: the record you played most, its artist
  and its plays as the headline, then top artist, top track, hours listened,
  and how many records and tracks you touched. The tag under the number
  switches between this month, this year and all time. Plays are counted per
  calendar month from this build on; all time reads the lifetime count, so a
  library that already had plays keeps them.
- **Drag to reorder the queue.** Rows in the QUEUE tab drag now; the up and
  down keys stay for the keyboard.
```

Check both blocks for em or en dashes before committing (`grep -n "—\|–" CHANGELOG.md` should return only lines that predate this task).

- [ ] **Step 2: roadmap page**

In `website/roadmap.html`:

Move the `<h2>Phase 4: the listening room</h2>` block (line ~145-148) up so it follows the Phase 1 block (after the `</p>` at line ~124), and change its heading and text to:

```html
        <h2>Phase 4: the listening room (shipped in beta 9)</h2>
        <p>
          A queue you can actually edit: drag to reorder, play this next, see what is coming. Resume where you left off when you reopen the app. And a stats view on the glass, built on Phase 0 data, showing your most played record, artist and track of the month, the year and all time. Cheap to build, genuinely fun, and precisely the sort of thing an OLED panel on a piece of imaginary hardware should be doing.
        </p>
```

Then, above the (now following) `<h2>Phase 2: crates that fill themselves</h2>`, insert:

```html
        <h2>After 2.0</h2>
        <p>
          Phases 2 and 3 are the workshop half of this list, and 2.0 ships the listening half first. They stay on the plan; they are not in the release.
        </p>
```

Also mark Phase 0 and Phase 1 headings as shipped for consistency, if they are not already: `<h2>Phase 0: the foundations (shipped in beta 2)</h2>` and `<h2>Phase 1: find anything (shipped in beta 6)</h2>`.

Update `"dateModified"` in the page's JSON-LD to `"2026-09-03"`. Confirm no em or en dashes were introduced (`grep -n "—\|–" website/roadmap.html`).

- [ ] **Step 3: CLAUDE.md**

At the end of the **Listening history** bullet (line 139), append:

```
  Since 2.0 beta 9 each record also carries `playsByMonth`, a `"YYYY-MM"` → count histogram written by `recordPlay(at:)` and omitted from the file when empty. It is deliberately a histogram, not a date log, so the file is bounded by tracks × months. `playCount` predates it and stays the lifetime truth: the STATS screen's All Time reads `playCount`, Month and Year read the histogram, and the two are allowed to disagree. `ListeningSummary.compute` is the one reader; the view model runs it only while the STATS screen is showing and something changed.
- **Resume** is a `PlaybackSnapshot` (loaded track plus up to 500 following, position, source key) kept in `PreferencesStore.playbackSnapshotData`, saved by `LibraryViewModel+Resume` on index change, pause, queue edits and at quit, and written only when its bytes changed. At launch `PlaybackSnapshot.resolve` drops paths the `TrackStore` no longer knows and gives up entirely if the loaded track is gone or its file is not on disk. The position lands through the same `pendingSeek*` pair Record Divider uses.
```

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md website/roadmap.html CLAUDE.md
git commit -m "docs: phase 4 in the changelog, roadmap and CLAUDE.md; phases 2 and 3 move past 2.0

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018QEgsfNnYJM71UyWWHR8TL"
```

---

### Task 12: full suite and a last look

**Files:** none new.

- [ ] **Step 1: Run everything**

Run: `swift build && scripts/test.sh`
Expected: build succeeds; every test passes (the existing ~900 plus the new `ListeningSummaryTests`, `PlaybackSnapshotTests`, `OLEDViewCycleTests`, and the additions to `ListeningStatsTests`, `ListeningStorePersistenceTests`, `DisplayLampTokenTests`).

- [ ] **Step 2: Check the plays file did not grow for unplayed tracks**

With the app having run at least once against a real library after Task 1: open the crates folder's `library.cdplays` and confirm `grep -c playsByMonth library.cdplays` equals the number of tracks played since the build, not the number of tracks in the library.

- [ ] **Step 3: Check for stray dashes in copy**

Run: `git diff 14e84fb..HEAD -- Sources/CrateDiggerApp CHANGELOG.md website/roadmap.html | grep -n "^+.*[—–]"`
Expected: only the OLED "—" rest glyph lines in `OLEDDisplay.swift` (a glyph, not copy). Fix anything else.

- [ ] **Step 4: Hand off**

The branch is ready for the user's own tweaks and then `press-the-record` for beta 9.
