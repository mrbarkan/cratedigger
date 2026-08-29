# 2.0 Phase 0 Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give CrateDigger a memory of what you have listened to, and move browser selection and sort out of the view model into tested Core types, so Phases 1 to 4 have something to build on.

**Architecture:** Two independent halves. Listening data becomes a `ListeningStats` value type in a new path-keyed `ListeningStore`, saved as `library.cdplays` beside the existing `library.cdtracks`, written from the playback callbacks that already drive Last.fm scrobbling. Browser state becomes a `BrowserState` value type in Core holding selection anchors, the three multi-selection sets and the three sort pairs; `LibraryViewModel` keeps every existing property *name* as a computed forward onto it, so no call site outside the view model changes.

**Tech Stack:** Swift 5.9+, SwiftPM, AppKit + SwiftUI, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-29-phase-0-foundations-design.md`

## Global Constraints

- **Branch is `v2`** (the 2.0 beta line). Never repoint `SUFeedURL`; it points at `website/appcast-beta.xml` and that is what keeps betas off other people's Macs.
- **Run `scripts/test.sh`, never bare `swift test`.** Filter with `scripts/test.sh --filter SomeTests`. The suite must be green at the end of every task, not just at the end of the plan.
- **Two-target boundary.** New testable logic goes in `Sources/CrateDiggerCore` (no AppKit views, no app state). UI glue goes in `Sources/CrateDiggerApp`. Core types are `public`, `Sendable`, and `Codable` where persisted.
- **The Last.fm scrobble threshold must not change**, with one deliberate exception. Task 1 is an extraction of: four minutes or half the duration, whichever is shorter, and never under thirty seconds, measured on *accumulated listened time*, not playhead position. The exception is a positivity guard the old inline rule lacked: at `duration == 0` the old `min(duration / 2, 240)` degenerated to a trigger of `0`, so anything past thirty seconds scrobbled even though the app did not know how long the track was. `PlayThreshold` returns false there instead. This is intentional and Task 1's tests pin it.
- **No em dashes or en dashes in user-facing copy.** Menu titles, tooltips, alert text. Code comments are exempt and the codebase uses them freely.
- **Mark deliberate simplifications with a `ponytail:` comment** naming the ceiling and the upgrade path, matching the convention already in `LibraryCleanupService.swift:90`.
- **Every line number in this plan is advisory, measured at commit `41c4ce7`.** Earlier tasks insert lines, so later tasks' numbers drift. Locate every edit site by the quoted code, which this plan always supplies, and use the line number only as a hint about where to look.
- **`LibraryViewModel` is 4175 lines.** Do not add behaviour to it. Every new piece of logic in this plan lands in Core; the view model only forwards.

---

## File Structure

**Create (Core):**
- `Sources/CrateDiggerCore/Services/PlayThreshold.swift` — the single definition of "listened to it properly".
- `Sources/CrateDiggerCore/Models/ListeningStats.swift` — the per-track value type.
- `Sources/CrateDiggerCore/Services/ListeningStore.swift` — path-keyed persistence for the above.
- `Sources/CrateDiggerCore/Models/BrowserState.swift` — selection + sort + the Phase 1 filter seam, and `BrowserSort`, and `BrowserColumn`.

**Create (App):**
- `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Listening.swift` — store plumbing, recording, rating actions.
- `Sources/CrateDiggerApp/UI/Carbon/Inspector/RatingStars.swift` — the five-star control.

**Create (Tests):**
- `Tests/CrateDiggerCoreTests/PlayThresholdTests.swift`
- `Tests/CrateDiggerCoreTests/ListeningStoreTests.swift`
- `Tests/CrateDiggerCoreTests/BrowserStateTests.swift`

**Modify:**
- `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` — scrobble call site, forwarding properties, init restore, store plumbing.
- `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+MultiSelect.swift` — becomes thin delegation.
- `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+ArrowNav.swift` — `BrowserColumn` moves out of it.
- `Sources/CrateDiggerApp/UI/Carbon/Inspector/InspectorPane.swift` — rating control in the info tab.
- `Sources/CrateDiggerApp/AppDelegate.swift` — rating menu items.
- `CLAUDE.md` — new Core types, corrected view model size.

---

## Task 1: `PlayThreshold`

Pure extraction of the scrobble rule so the play counter and the scrobbler share one definition. No behaviour change.

**Files:**
- Create: `Sources/CrateDiggerCore/Services/PlayThreshold.swift`
- Test: `Tests/CrateDiggerCoreTests/PlayThresholdTests.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift:2912-2914`

**Interfaces:**
- Consumes: nothing.
- Produces: `PlayThreshold.isPlayed(elapsed: Double, duration: Double) -> Bool`, `PlayThreshold.minimumSeconds: Double`, `PlayThreshold.capSeconds: Double`.

- [ ] **Step 1: Write the failing test**

Create `Tests/CrateDiggerCoreTests/PlayThresholdTests.swift`:

```swift
#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

/// Pins the exact rule the app has always used for Last.fm. These tests exist
/// so the extraction in Task 1 cannot quietly change when a track scrobbles.
final class PlayThresholdTests: XCTestCase {

    func testHalfOfAShortTrackCounts() {
        // 200s track: half is 100s, which is under the 240s cap.
        XCTAssertTrue(PlayThreshold.isPlayed(elapsed: 100, duration: 200))
        XCTAssertFalse(PlayThreshold.isPlayed(elapsed: 99, duration: 200))
    }

    func testLongTrackCapsAtFourMinutes() {
        // 3600s track: half would be 1800s, but four minutes is enough.
        XCTAssertTrue(PlayThreshold.isPlayed(elapsed: 240, duration: 3600))
        XCTAssertFalse(PlayThreshold.isPlayed(elapsed: 239, duration: 3600))
    }

    func testThirtySecondFloorBeatsTheHalfRule() {
        // 40s interlude: half is 20s, but nothing under 30s is ever a play.
        XCTAssertFalse(PlayThreshold.isPlayed(elapsed: 20, duration: 40))
        XCTAssertFalse(PlayThreshold.isPlayed(elapsed: 29.9, duration: 40))
        XCTAssertTrue(PlayThreshold.isPlayed(elapsed: 30, duration: 40))
    }

    func testZeroAndNegativeInputsAreNotPlays() {
        XCTAssertFalse(PlayThreshold.isPlayed(elapsed: 0, duration: 0))
        XCTAssertFalse(PlayThreshold.isPlayed(elapsed: -5, duration: 200))
        XCTAssertFalse(PlayThreshold.isPlayed(elapsed: 100, duration: 0))
    }
}
#endif
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `scripts/test.sh --filter PlayThresholdTests`
Expected: build failure, `cannot find 'PlayThreshold' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CrateDiggerCore/Services/PlayThreshold.swift`:

```swift
import Foundation

/// When a track counts as listened to.
///
/// One definition, shared by the Last.fm scrobbler and the play counter, so the
/// two can never drift apart and the rule is testable instead of inlined in a
/// view model. It is Last.fm's own guideline, which the app has used since
/// scrobbling shipped: half the track or four minutes, whichever comes first,
/// and never under thirty seconds.
///
/// `elapsed` is *accumulated listening time*, not playhead position. Seeking to
/// 90% and stopping is not a play, which is why the caller accumulates tick
/// deltas rather than reading the current time.
public enum PlayThreshold {

    /// Nothing shorter than this is a play, however short the track.
    public static let minimumSeconds: Double = 30

    /// Past this you have heard enough of anything, however long the track.
    public static let capSeconds: Double = 240

    public static func isPlayed(elapsed: Double, duration: Double) -> Bool {
        guard duration > 0, elapsed > 0 else { return false }
        let trigger = min(duration / 2, capSeconds)
        return elapsed >= trigger && elapsed >= minimumSeconds
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `scripts/test.sh --filter PlayThresholdTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Switch the scrobbler to it**

In `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift`, replace these three lines inside `checkScrobbleProgress(current:duration:)`:

```swift
        // Last.fm guidelines: scrobble if played at least 4 minutes (240s) or half the duration, whichever is shorter, and played for at least 30s.
        let triggerTime = min(duration / 2.0, 240.0)
        if listenedSeconds >= triggerTime && listenedSeconds >= 30.0 {
```

with:

```swift
        // Same rule as the play counter — see PlayThreshold.
        if PlayThreshold.isPlayed(elapsed: listenedSeconds, duration: duration) {
```

- [ ] **Step 6: Run the whole suite**

Run: `scripts/test.sh`
Expected: PASS, no regressions.

- [ ] **Step 7: Commit**

```bash
git add Sources/CrateDiggerCore/Services/PlayThreshold.swift \
        Tests/CrateDiggerCoreTests/PlayThresholdTests.swift \
        Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift
git commit -m "refactor(playback): one definition of a played track

Extracts the Last.fm scrobble threshold into PlayThreshold so the play
counter arriving in Phase 0 shares it rather than reimplementing it.
Behaviour is unchanged and the tests pin the exact boundaries."
```

---

## Task 2: `ListeningStats`

**Files:**
- Create: `Sources/CrateDiggerCore/Models/ListeningStats.swift`
- Test: `Tests/CrateDiggerCoreTests/ListeningStoreTests.swift` (created here, extended in Task 3)

**Interfaces:**
- Consumes: nothing.
- Produces: `ListeningStats` with `playCount: Int`, `skipCount: Int`, `lastPlayed: Date?`, `dateAdded: Date`, `rating: Int`; `init(dateAdded:)`; `mutating func recordPlay(at:)`; `mutating func recordSkip()`; `var isRated: Bool`.

- [ ] **Step 1: Write the failing test**

Create `Tests/CrateDiggerCoreTests/ListeningStoreTests.swift`:

```swift
#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class ListeningStatsTests: XCTestCase {

    private let added = Date(timeIntervalSince1970: 1_700_000_000)

    func testANewTrackHasNoHistoryButKnowsWhenItArrived() {
        let stats = ListeningStats(dateAdded: added)
        XCTAssertEqual(stats.playCount, 0)
        XCTAssertEqual(stats.skipCount, 0)
        XCTAssertNil(stats.lastPlayed)
        XCTAssertEqual(stats.dateAdded, added)
        XCTAssertEqual(stats.rating, 0)
        XCTAssertFalse(stats.isRated, "0 means unrated, not rated zero")
    }

    func testRecordingAPlayCountsItAndStampsTheDate() {
        var stats = ListeningStats(dateAdded: added)
        let when = Date(timeIntervalSince1970: 1_700_000_500)
        stats.recordPlay(at: when)
        XCTAssertEqual(stats.playCount, 1)
        XCTAssertEqual(stats.lastPlayed, when)
        stats.recordPlay(at: when.addingTimeInterval(60))
        XCTAssertEqual(stats.playCount, 2)
    }

    func testASkipDoesNotCountAsAPlayAndDoesNotStampLastPlayed() {
        var stats = ListeningStats(dateAdded: added)
        stats.recordSkip()
        XCTAssertEqual(stats.skipCount, 1)
        XCTAssertEqual(stats.playCount, 0)
        XCTAssertNil(stats.lastPlayed, "you did not listen to it")
    }

    func testRatingIsClampedToTheFiveStarsTheUICanShow() {
        var stats = ListeningStats(dateAdded: added)
        stats.rating = 9
        XCTAssertEqual(stats.rating, 5)
        stats.rating = -3
        XCTAssertEqual(stats.rating, 0)
        stats.rating = 4
        XCTAssertTrue(stats.isRated)
    }

    func testRoundTripsThroughJSON() throws {
        var stats = ListeningStats(dateAdded: added)
        stats.recordPlay(at: added)
        stats.rating = 3
        let data = try JSONEncoder().encode(stats)
        XCTAssertEqual(try JSONDecoder().decode(ListeningStats.self, from: data), stats)
    }
}
#endif
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `scripts/test.sh --filter ListeningStatsTests`
Expected: build failure, `cannot find 'ListeningStats' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CrateDiggerCore/Models/ListeningStats.swift`:

```swift
import Foundation

/// What CrateDigger knows about your relationship with a track, as opposed to
/// what it knows about the file.
///
/// Kept apart from `AudioTrack` and `ConversionMetadata` on purpose: those
/// describe the recording and are rebuilt whenever a file is rescanned,
/// retagged or relinked. This is the part that would be irreplaceable if a
/// rebuild dropped it. See `ListeningStore`.
public struct ListeningStats: Codable, Sendable, Equatable {
    public var playCount: Int
    public var skipCount: Int
    public var lastPlayed: Date?
    /// When this track entered *this library*, which is not the file's creation
    /// date: a 2003 rip added last Tuesday should sort as last Tuesday.
    public var dateAdded: Date
    /// 0 means unrated, which is a different thing from rated zero. 1...5
    /// otherwise. An Int rather than an Int? because ratings get compared and
    /// sorted constantly and an optional would put a `??` at every one of
    /// those sites. Clamped on write so no UI has to defend against a 7.
    public var rating: Int {
        didSet { rating = min(max(rating, 0), 5) }
    }

    public init(
        playCount: Int = 0,
        skipCount: Int = 0,
        lastPlayed: Date? = nil,
        dateAdded: Date,
        rating: Int = 0
    ) {
        self.playCount = playCount
        self.skipCount = skipCount
        self.lastPlayed = lastPlayed
        self.dateAdded = dateAdded
        self.rating = min(max(rating, 0), 5)
    }

    /// Whether the user has expressed an opinion, as distinct from a low one.
    public var isRated: Bool { rating > 0 }

    public mutating func recordPlay(at date: Date) {
        playCount += 1
        lastPlayed = date
    }

    /// A skip leaves `lastPlayed` alone: you did not listen to it, so it should
    /// not surface in "recently played".
    public mutating func recordSkip() {
        skipCount += 1
    }
}
```

Note: a `didSet` on a stored property does not run from within `init`, which is why the initialiser clamps explicitly as well.

- [ ] **Step 4: Run the test to verify it passes**

Run: `scripts/test.sh --filter ListeningStatsTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Models/ListeningStats.swift \
        Tests/CrateDiggerCoreTests/ListeningStoreTests.swift
git commit -m "feat(core): ListeningStats, the per-track listening record

Play count, skip count, last played, date added and rating, as a value
type kept deliberately apart from the track record that rescans rebuild."
```

---

## Task 3: `ListeningStore`

Mirrors `TrackStore` (`Sources/CrateDiggerCore/Services/TrackStore.swift`) closely: same path key, same canonical output, same dirty-skip, same refusal to overwrite a file it could not read.

**Files:**
- Create: `Sources/CrateDiggerCore/Services/ListeningStore.swift`
- Test: `Tests/CrateDiggerCoreTests/ListeningStoreTests.swift` (append a second class)

**Interfaces:**
- Consumes: `ListeningStats` from Task 2.
- Produces: `ListeningStore(fileURL:)`; `static func key(for: URL) -> String`; `stats(path:) -> ListeningStats?`; `statsOrCreate(path:now:) -> ListeningStats`; `recordPlay(path:at:)`; `recordSkip(path:)`; `setRating(_:path:)`; `repoint(from:to:)`; `remove(path:)`; `backfill(paths:dateAdded:)`; `save() throws`; `count: Int`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/CrateDiggerCoreTests/ListeningStoreTests.swift`:

```swift
final class ListeningStorePersistenceTests: XCTestCase {

    private var folder: URL!
    private var fileURL: URL!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdplays-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("library.cdplays")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private let trackA = URL(fileURLWithPath: "/Music/A/01.flac")
    private let trackB = URL(fileURLWithPath: "/Music/B/02.flac")

    func testAPlaySurvivesAReload() throws {
        let store = ListeningStore(fileURL: fileURL)
        store.recordPlay(path: ListeningStore.key(for: trackA), at: now)
        try store.save()

        let reopened = ListeningStore(fileURL: fileURL)
        let stats = try XCTUnwrap(reopened.stats(path: ListeningStore.key(for: trackA)))
        XCTAssertEqual(stats.playCount, 1)
        XCTAssertEqual(stats.lastPlayed, now)
    }

    func testUnchangedStoreReSerializesToIdenticalBytes() throws {
        let store = ListeningStore(fileURL: fileURL)
        store.recordPlay(path: ListeningStore.key(for: trackB), at: now)
        store.recordPlay(path: ListeningStore.key(for: trackA), at: now)
        try store.save()
        let first = try Data(contentsOf: fileURL)

        // Reload and save again with no edits: backup dedup depends on this.
        let reopened = ListeningStore(fileURL: fileURL)
        reopened.setRating(3, path: ListeningStore.key(for: trackA))
        reopened.setRating(0, path: ListeningStore.key(for: trackA))
        try reopened.save()
        XCTAssertEqual(try Data(contentsOf: fileURL), first)
    }

    func testSavingWithNothingToWriteDoesNotTouchTheFile() throws {
        let store = ListeningStore(fileURL: fileURL)
        store.recordPlay(path: ListeningStore.key(for: trackA), at: now)
        try store.save()
        let stamp = try FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date

        let reopened = ListeningStore(fileURL: fileURL)
        try reopened.save()
        let after = try FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        XCTAssertEqual(stamp, after)
    }

    func testRepointCarriesStatsToTheNewPath() throws {
        let store = ListeningStore(fileURL: fileURL)
        let old = ListeningStore.key(for: trackA)
        let new = ListeningStore.key(for: trackB)
        store.recordPlay(path: old, at: now)
        store.setRating(5, path: old)

        store.repoint(from: old, to: new)

        XCTAssertNil(store.stats(path: old))
        let moved = try XCTUnwrap(store.stats(path: new))
        XCTAssertEqual(moved.playCount, 1)
        XCTAssertEqual(moved.rating, 5)
    }

    func testRepointOntoAnExistingRowKeepsTheRicherHistory() throws {
        let store = ListeningStore(fileURL: fileURL)
        let old = ListeningStore.key(for: trackA)
        let new = ListeningStore.key(for: trackB)
        store.recordPlay(path: old, at: now)
        store.recordPlay(path: old, at: now)
        store.recordPlay(path: new, at: now)

        store.repoint(from: old, to: new)

        // Two plays beat one: a move must never lose history to a stale row.
        XCTAssertEqual(store.stats(path: new)?.playCount, 2)
    }

    func testRemoveDropsARowForgotten() throws {
        let store = ListeningStore(fileURL: fileURL)
        store.recordPlay(path: ListeningStore.key(for: trackA), at: now)
        store.recordPlay(path: ListeningStore.key(for: trackB), at: now)

        store.remove(path: ListeningStore.key(for: trackB))

        XCTAssertEqual(store.count, 1)
        XCTAssertNotNil(store.stats(path: ListeningStore.key(for: trackA)))
        XCTAssertNil(store.stats(path: ListeningStore.key(for: trackB)))
    }

    func testBackfillStampsOnlyPathsWithNoRowYet() throws {
        let store = ListeningStore(fileURL: fileURL)
        let a = ListeningStore.key(for: trackA)
        let b = ListeningStore.key(for: trackB)
        store.recordPlay(path: a, at: now)
        let existingAdded = try XCTUnwrap(store.stats(path: a)).dateAdded

        let backfillDate = Date(timeIntervalSince1970: 1_600_000_000)
        store.backfill(paths: [a, b], dateAdded: backfillDate)

        XCTAssertEqual(store.stats(path: a)?.dateAdded, existingAdded, "must not rewrite a known row")
        XCTAssertEqual(store.stats(path: b)?.dateAdded, backfillDate)
        XCTAssertEqual(store.stats(path: b)?.playCount, 0)
    }

    func testAnUnreadableFileIsNotOverwritten() throws {
        try Data("this is not json".utf8).write(to: fileURL)
        let store = ListeningStore(fileURL: fileURL)
        store.recordPlay(path: ListeningStore.key(for: trackA), at: now)

        XCTAssertThrowsError(try store.save())
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("this is not json".utf8))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `scripts/test.sh --filter ListeningStorePersistenceTests`
Expected: build failure, `cannot find 'ListeningStore' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CrateDiggerCore/Services/ListeningStore.swift`:

```swift
import Foundation

public enum ListeningStoreError: LocalizedError {
    /// The plays file is present but would not decode. Reported instead of
    /// saving, because saving would replace a listening history we failed to
    /// read with whatever little happens to be in memory, and unlike a track
    /// index there is nothing to rebuild it from.
    case unreadableStore(path: String)

    public var errorDescription: String? {
        switch self {
        case .unreadableStore(let path):
            return "The listening history at \(path) could not be read, so CrateDigger "
                + "has not written over it. Move that file aside to start fresh, or "
                + "restore it from a backup."
        }
    }
}

/// Play counts, skips, ratings and dates for every track in a library, keyed by
/// standardized file path and saved as `library.cdplays` beside
/// `library.cdtracks`.
///
/// Deliberately not a field on `LoadedTrack` in the `TrackStore`, for two
/// reasons. `TrackStore.upsert(_:)` replaces a whole record, and the tag-write,
/// relink, rescan and organiser paths all reconstruct one — every such path
/// would have to remember to carry stats forward, and the cost of forgetting is
/// silently zeroing somebody's history. And `library.cdtracks` is byte-canonical
/// specifically so an unchanged library does not rewrite on save, which a play
/// count, the most frequently changing value in the app, would defeat.
///
/// Same shape as `TrackStore` otherwise: canonical output so backup tools can
/// dedup, and a dirty flag so a save with nothing to write does not happen.
public final class ListeningStore {
    private let fileURL: URL
    private var byPath: [String: ListeningStats] = [:]
    private var isDirty = false
    private var isUnreadable = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    /// The canonical key for a track: its standardized file path. Same rule as
    /// `TrackStore.key(for:)`, so the two stores agree on identity.
    public static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        // Must match `save()`. A default decoder reads dates as numeric
        // intervals and would fail on every ISO string this store writes.
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([String: ListeningStats].self, from: data) else {
            isUnreadable = true
            return
        }
        byPath = decoded
    }

    /// Persist. Canonical bytes: `.sortedKeys` fixes both the path order and the
    /// field order within each record, because Swift seeds its hashing per
    /// process and without it an unchanged file reads as changed to Time
    /// Machine, Dropbox and git on every save.
    public func save() throws {
        if isUnreadable { throw ListeningStoreError.unreadableStore(path: fileURL.path) }
        guard isDirty else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(byPath)
        try data.write(to: fileURL, options: .atomic)
        isDirty = false
    }

    // MARK: - Reading

    public func stats(path: String) -> ListeningStats? { byPath[path] }

    public var count: Int { byPath.count }
    public var allPaths: [String] { Array(byPath.keys) }

    /// The row for a path, creating an empty one stamped `now` if this is the
    /// first time the library has seen it.
    @discardableResult
    public func statsOrCreate(path: String, now: Date = Date()) -> ListeningStats {
        if let existing = byPath[path] { return existing }
        let fresh = ListeningStats(dateAdded: now)
        byPath[path] = fresh
        isDirty = true
        return fresh
    }

    // MARK: - Writing

    public func recordPlay(path: String, at date: Date = Date()) {
        var stats = statsOrCreate(path: path, now: date)
        stats.recordPlay(at: date)
        byPath[path] = stats
        isDirty = true
    }

    public func recordSkip(path: String) {
        var stats = statsOrCreate(path: path)
        stats.recordSkip()
        byPath[path] = stats
        isDirty = true
    }

    public func setRating(_ rating: Int, path: String) {
        var stats = statsOrCreate(path: path)
        let clamped = min(max(rating, 0), 5)
        guard stats.rating != clamped else { return }
        stats.rating = clamped
        byPath[path] = stats
        isDirty = true
    }

    // MARK: - Housekeeping

    /// Carry a track's history to its new path after a rename, move or
    /// consolidate. If the destination already has a row, the one with more
    /// plays wins: a move must never lose history to a stale row left behind by
    /// an earlier scan of the same file.
    public func repoint(from oldPath: String, to newPath: String) {
        guard oldPath != newPath, let moving = byPath.removeValue(forKey: oldPath) else { return }
        isDirty = true
        guard let existing = byPath[newPath] else {
            byPath[newPath] = moving
            return
        }
        byPath[newPath] = moving.playCount >= existing.playCount ? moving : existing
    }

    /// Forget a track's history, for when it leaves the library for good.
    /// Called from the same purge that drops its `TrackStore` key.
    ///
    /// Deliberately per-path rather than a sweep against a live set: a sweep run
    /// while a library folder happens to be unmounted would delete the history
    /// of every track on it.
    public func remove(path: String) {
        guard byPath.removeValue(forKey: path) != nil else { return }
        isDirty = true
    }

    /// Give every path with no row yet a `dateAdded`, leaving known rows alone.
    ///
    /// ponytail: on a library that predates this file, `dateAdded` is a single
    /// guess for the whole collection rather than a real per-track date, because
    /// there is no record to recover one from. The upgrade path, if it ever
    /// matters, is the file's own creation date. Stamping "today" instead would
    /// make Phase 2's "added this month" rule useless for a year.
    public func backfill(paths: [String], dateAdded: Date) {
        for path in paths where byPath[path] == nil {
            byPath[path] = ListeningStats(dateAdded: dateAdded)
            isDirty = true
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `scripts/test.sh --filter ListeningStorePersistenceTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Run the whole suite**

Run: `scripts/test.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/CrateDiggerCore/Services/ListeningStore.swift \
        Tests/CrateDiggerCoreTests/ListeningStoreTests.swift
git commit -m "feat(core): ListeningStore, path-keyed listening history

Saved as library.cdplays beside library.cdtracks. Canonical bytes and a
dirty flag, matching TrackStore, so backup tools can dedup and a save
with nothing to write does not happen."
```

---

## Task 4: Wire the store into the view model

Plumbing only. Nothing records yet.

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Listening.swift`

**Interfaces:**
- Consumes: `ListeningStore` from Task 3, and `cratesDirectoryURL` / `persistTrackStore()` which already exist on `LibraryViewModel`.
- Produces: on `LibraryViewModel`: `currentListeningStore() -> ListeningStore`, `persistListeningStore() -> Bool`, `backfillListeningStoreIfNeeded(knownPaths:)`, `resetListeningStoreCache()`.

- [ ] **Step 1: Write the file**

Create `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Listening.swift`:

```swift
import Foundation
import CrateDiggerCore

/// Listening history: the store, and reading from it. Recording lives further
/// down this file once Task 5 lands.
///
/// The store is cached per crates folder exactly like `TrackStore`, and for the
/// same reason: switching the crates index folder must give you that folder's
/// history, not the last one's.
@MainActor
extension LibraryViewModel {

    func currentListeningStore() -> ListeningStore {
        let folder = cratesDirectoryURL
        if let store = listeningStore, listeningStoreFolder?.path == folder.path {
            return store
        }
        let store = ListeningStore(fileURL: folder.appendingPathComponent("library.cdplays"))
        listeningStore = store
        listeningStoreFolder = folder
        return store
    }

    /// Persist, surfacing failures rather than dropping history while the UI
    /// claims nothing happened. Unlike the track store there is no rescan that
    /// can rebuild this, so a failure is worth an alert.
    @discardableResult
    func persistListeningStore() -> Bool {
        do {
            try currentListeningStore().save()
            return true
        } catch {
            AppLog.library.error("Failed to save listening history: \(error.localizedDescription)")
            appAlert = .error(
                title: "Listening History Not Saved",
                message: "Could not write your play counts and ratings: \(error.localizedDescription)"
            )
            return false
        }
    }

    /// First run against a library that predates the plays file: give every
    /// known track a dateAdded so Phase 2's date rules have something to read.
    /// The date is the track index's own modification time, which is the closest
    /// thing to "when this library was last real" that exists on disk.
    func backfillListeningStoreIfNeeded(knownPaths: [String]) {
        let store = currentListeningStore()
        guard store.count == 0, !knownPaths.isEmpty else { return }
        let indexURL = cratesDirectoryURL.appendingPathComponent("library.cdtracks")
        let stamp = (try? FileManager.default.attributesOfItem(atPath: indexURL.path)[.modificationDate] as? Date)
            .flatMap { $0 } ?? Date()
        store.backfill(paths: knownPaths, dateAdded: stamp)
        persistListeningStore()
        AppLog.library.notice("Backfilled listening history for \(knownPaths.count, privacy: .public) track(s)")
    }

    /// Called when the crates folder changes, so the next access rebuilds
    /// against the new folder.
    func resetListeningStoreCache() {
        listeningStore = nil
        listeningStoreFolder = nil
    }
}
```

- [ ] **Step 2: Add the two stored properties**

In `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift`, immediately after these existing lines (around line 3239):

```swift
    private var trackStore: TrackStore?
    private var trackStoreFolder: URL?
```

add:

```swift
    /// Listening history for the current crates folder. Separate from the track
    /// store on purpose — see ListeningStore.
    var listeningStore: ListeningStore?
    var listeningStoreFolder: URL?
```

They are internal rather than private because `LibraryViewModel+Listening.swift` is a different file.

- [ ] **Step 3: Reset the cache alongside the track store**

In `LibraryViewModel.swift` find the line `trackStore = nil   // rebuilt lazily for the (possibly new) folder` (around line 3152) and add immediately below it:

```swift
        resetListeningStoreCache()
```

- [ ] **Step 4: Call the backfill at launch**

In `LibraryViewModel.swift`, in `refreshAvailableCrates()` (line 3148), immediately
after the existing `migrateLegacyCratesIfNeeded()` line, add:

```swift
        // First run against a library older than the plays file: give every
        // known track a dateAdded. The track store's own paths are the source,
        // so this does not wait for the index to be built. No-op after the
        // first time, because the guard is "the plays file is empty".
        backfillListeningStoreIfNeeded(knownPaths: currentTrackStore().allPaths)
```

`refreshAvailableCrates()` is called once at launch (`LibraryViewModel.swift:995`)
and again whenever the crates folder changes, which is exactly the coverage
wanted: a folder the app has never opened gets backfilled the first time it does.
Note the placement is *before* the early `return` in the "no crates yet" branch,
which is deliberate: a brand new library has no paths and the guard makes it a
no-op anyway.

- [ ] **Step 5: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 6: Run the whole suite**

Run: `scripts/test.sh`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Listening.swift \
        Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift
git commit -m "feat(library): hold a ListeningStore per crates folder

Plumbing only: the store is created, cached, persisted, and backfilled
once for libraries that predate it. Nothing records into it yet."
```

---

## Task 5: Record plays and skips

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` — `checkScrobbleProgress`, `wirePlaybackBindings`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Listening.swift`

**Interfaces:**
- Consumes: `PlayThreshold` (Task 1), `currentListeningStore()` (Task 4).
- Produces: on `LibraryViewModel`: `recordPlayIfThresholdMet(elapsed:duration:)`, `recordSkipForOutgoingTrack()`.

- [ ] **Step 1: Add the recording methods**

Append to `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Listening.swift`, inside the same extension:

```swift
    /// Count a play once the same threshold that triggers a scrobble is met.
    ///
    /// Guarded by `countedPlayTrackID` rather than by the scrobble guard,
    /// because the two must not be coupled: a user with no Last.fm account still
    /// gets play counts, and the scrobble guard is cleared by network paths this
    /// has no business knowing about.
    func recordPlayIfThresholdMet(elapsed: Double, duration: Double) {
        guard !isRadioMode else { return }
        guard let nowPlaying = nowPlayingTrack else { return }
        guard countedPlayTrackID != nowPlaying.track.id else { return }
        guard PlayThreshold.isPlayed(elapsed: elapsed, duration: duration) else { return }

        countedPlayTrackID = nowPlaying.track.id
        currentListeningStore().recordPlay(path: ListeningStore.key(for: nowPlaying.track.fileURL))
        // ponytail: saved on every counted play. At one write per several
        // minutes of listening that is nothing; if a shuffle-heavy session ever
        // shows up in a profile, batch it behind a timer.
        persistListeningStore()
    }

    /// The track being left counts as skipped if it never reached the play
    /// threshold. Called from the index-change callback, before the per-track
    /// counters are reset for the incoming track.
    func recordSkipForOutgoingTrack() {
        guard !isRadioMode else { return }
        guard let outgoing = nowPlayingTrack else { return }
        guard countedPlayTrackID != outgoing.track.id else { return }
        // Nothing at all was heard: an auto-advance into a track that failed to
        // open is not a skip, it is a non-event.
        guard listenedSeconds > 0 else { return }

        currentListeningStore().recordSkip(path: ListeningStore.key(for: outgoing.track.fileURL))
        persistListeningStore()
    }
```

- [ ] **Step 2: Add the guard property**

In `LibraryViewModel.swift`, immediately after this existing line (around line 825):

```swift
    private var lastScrobbledTrackID: UUID?
```

add:

```swift
    /// The track whose play has already been counted, so a long track cannot
    /// count twice. Kept separate from `lastScrobbledTrackID` because play
    /// counts must work with no Last.fm account.
    var countedPlayTrackID: UUID?
```

- [ ] **Step 3: Call the play recorder**

In `LibraryViewModel.swift`, in `checkScrobbleProgress(current:duration:)`, immediately after the line `lastScrobbleTickTime = current`, add:

```swift
        // Play counts are ours and do not depend on a Last.fm account, so this
        // runs before the session-key guard below returns.
        recordPlayIfThresholdMet(elapsed: listenedSeconds, duration: duration)
```

This placement matters: the existing `guard let sessionKey = prefs.lastFmSessionKey` two lines further down returns early for anyone not scrobbling, and play counts must not be collateral damage.

- [ ] **Step 4: Call the skip recorder**

In `LibraryViewModel.swift`, in `wirePlaybackBindings()`, inside `playback.onCurrentIndexChange`, the body currently begins:

```swift
                guard let self else { return }
                self.playbackCurrentIndex = index
```

Insert the skip check between those two lines, so it sees the *outgoing* track before `playbackCurrentIndex` moves:

```swift
                guard let self else { return }
                // Before the index moves: the track we are leaving is skipped if
                // it never reached the play threshold.
                self.recordSkipForOutgoingTrack()
                self.playbackCurrentIndex = index
```

Then, in the same closure, alongside the existing scrobble resets, add the play-count reset. The existing lines are:

```swift
                self.lastScrobbledTrackID = nil
                self.listenedSeconds = 0
                self.lastScrobbleTickTime = nil
```

Add below them:

```swift
                self.countedPlayTrackID = nil
```

- [ ] **Step 5: Stamp dateAdded when tracks are staged**

In `LibraryViewModel.swift`, in `stageIntoPrepCrate(_:)` (around line 3085), immediately after the existing `ingestArtwork(from: unfiled)` line, add:

```swift
        // First sighting of these files in this library: stamp dateAdded now,
        // because "added" means added here, not the file's creation date.
        let store = currentListeningStore()
        let now = Date()
        for track in unfiled {
            store.statsOrCreate(path: ListeningStore.key(for: track.track.fileURL), now: now)
        }
        persistListeningStore()
```

- [ ] **Step 6: Build and run the whole suite**

Run: `swift build && scripts/test.sh`
Expected: `Build complete!` then PASS.

- [ ] **Step 7: Verify in the running app**

```bash
pkill -f CrateDiggerApp; swift build && .build/arm64-apple-macosx/debug/CrateDiggerApp &
```

Play a track for more than thirty seconds and past half its length, then check the file:

```bash
python3 -c "
import json,glob
for f in glob.glob('*/library.cdplays') + glob.glob('library.cdplays'):
    d=json.load(open(f)); print(f, len(d), 'rows')
    for k,v in list(d.items())[:5]: print(' ', k.split('/')[-1], v)
"
```

Expected: a row with `playCount: 1` and a `lastPlayed` timestamp. Then skip a track within its first few seconds and confirm a `skipCount` of 1 with `playCount` still 0. Quit the app afterwards with `pkill -f CrateDiggerApp`.

- [ ] **Step 8: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift \
        Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Listening.swift
git commit -m "feat(library): count plays and skips

Driven off the same playback callbacks and the same threshold as Last.fm,
but guarded separately so play counts work with no Last.fm account."
```

---

## Task 6: Keep the key correct across path changes

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift:3885` (`updateTrackURLInIndex`), `:3901` (`updateTrackURLsInIndex`), `:3671` (`purgeTracksFromLibraryState`)

**Interfaces:**
- Consumes: `ListeningStore.repoint(from:to:)` and `.remove(path:)` from Task 3.
- Produces: nothing new.

The spec names four choke points. Only two need editing: `moveLibrary()`
(`:4006`) and `consolidateLibrary()` (`:4161`) both funnel their results through
`updateTrackURLsInIndex(_:)`, so fixing that one covers both. Verify this before
you start — `grep -n "updateTrackURLsInIndex" Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift`
should show exactly those two callers plus the definition.

- [ ] **Step 1: Repoint on a single-track path change**

In `updateTrackURLInIndex(oldURL:newTrack:)`, the body currently reads:

```swift
        let oldKey = TrackStore.key(for: oldURL)
        if oldKey != TrackStore.key(for: newTrack.track.fileURL) {
            currentTrackStore().remove(path: oldKey)
        }
```

Replace with:

```swift
        let oldKey = TrackStore.key(for: oldURL)
        let newKey = TrackStore.key(for: newTrack.track.fileURL)
        if oldKey != newKey {
            currentTrackStore().remove(path: oldKey)
            // History is keyed by path, so a retag that moves the file has to
            // carry it or the user silently loses their play counts.
            currentListeningStore().repoint(from: oldKey, to: newKey)
            persistListeningStore()
        }
```

- [ ] **Step 2: Repoint on a batch path change**

In `updateTrackURLsInIndex(_:)`, the closing block currently reads:

```swift
        // Drop dead old-path keys, then persist the store once for the batch.
        let liveKeys = Set(newTracks.map { TrackStore.key(for: $0.track.fileURL) })
        for key in staleKeys.subtracting(liveKeys) { store.remove(path: key) }
        persistTrackStore()
```

Replace with:

```swift
        // Drop dead old-path keys, then persist the store once for the batch.
        let liveKeys = Set(newTracks.map { TrackStore.key(for: $0.track.fileURL) })
        for key in staleKeys.subtracting(liveKeys) { store.remove(path: key) }
        persistTrackStore()

        // Carry listening history across the same moves, by id, so a relocated
        // folder keeps its play counts. One save for the whole batch.
        let plays = currentListeningStore()
        for newTrack in newTracks {
            let newKey = TrackStore.key(for: newTrack.track.fileURL)
            guard let oldKey = staleKeys.first(where: { $0 != newKey && plays.stats(path: $0) != nil }),
                  !liveKeys.contains(oldKey) else { continue }
            plays.repoint(from: oldKey, to: newKey)
        }
        persistListeningStore()
```

Note: `staleKeys` is a `Set<String>` of the pre-move keys collected earlier in the same function. The `!liveKeys.contains(oldKey)` guard stops a key that is still live for another track from being consumed.

- [ ] **Step 3: Forget history when a track leaves the library**

`purgeTracksFromLibraryState(paths:)` at `LibraryViewModel.swift:3671` is the one
choke point for permanent removal, and already loops the track store. Find:

```swift
        let store = currentTrackStore()
        for path in paths { store.remove(path: path) }
```

Replace with:

```swift
        let store = currentTrackStore()
        let plays = currentListeningStore()
        for path in paths {
            store.remove(path: path)
            plays.remove(path: path)
        }
```

and add `persistListeningStore()` immediately after the existing
`persistTrackStore()` call near the end of the same function.

- [ ] **Step 4: Build and run the whole suite**

Run: `swift build && scripts/test.sh`
Expected: `Build complete!` then PASS.

- [ ] **Step 5: Verify a rename keeps the count**

Launch the app, play a track past the threshold to get it to `playCount: 1`,
then edit its title in a way that renames the file, then check `library.cdplays`
still shows one play against the *new* path and no row against the old one.

- [ ] **Step 6: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift
git commit -m "fix(library): carry listening history across path changes

A retag that moves a file, or a batch relink, repoints the plays store at
the same choke points that already repoint the track store, and a purge
forgets it at the one that already drops the track store key."
```

---

## Task 7: Rating

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/Inspector/RatingStars.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Listening.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Inspector/InspectorPane.swift:157` and `:196`
- Modify: `Sources/CrateDiggerApp/AppDelegate.swift`
- Modify: `Sources/CrateDiggerApp/UI/MainWindowController.swift:320`

**Interfaces:**
- Consumes: `currentListeningStore()` from Task 4, `selectedTracksForCrateAdd()` which already exists.
- Produces: on `LibraryViewModel`: `ratingForSelection: Int`, `rateSelection(_ rating: Int)`.

- [ ] **Step 1: Add the rating actions**

Append to the extension in `LibraryViewModel+Listening.swift`:

```swift
    /// The rating shown for the current selection: the shared value when every
    /// selected track agrees, otherwise 0, because showing one track's three
    /// stars for a mixed selection would be a lie the user then overwrites.
    var ratingForSelection: Int {
        let tracks = tracksToRate()
        guard let first = tracks.first else { return 0 }
        let store = currentListeningStore()
        let firstRating = store.stats(path: ListeningStore.key(for: first.track.fileURL))?.rating ?? 0
        for track in tracks.dropFirst() {
            let rating = store.stats(path: ListeningStore.key(for: track.track.fileURL))?.rating ?? 0
            if rating != firstRating { return 0 }
        }
        return firstRating
    }

    /// Rate everything selected. 0 clears.
    func rateSelection(_ rating: Int) {
        let tracks = tracksToRate()
        guard !tracks.isEmpty else { return }
        let store = currentListeningStore()
        for track in tracks {
            store.setRating(rating, path: ListeningStore.key(for: track.track.fileURL))
        }
        persistListeningStore()
        objectWillChange.send()
        showOLEDNotice(rating == 0
                       ? "RATING CLEARED"
                       : "RATED \(rating) STAR\(rating == 1 ? "" : "S")")
    }

    /// A real multi-selection rates all of it; otherwise the anchor track.
    /// Mirrors `tracksForInspectorTagEdit()` so rating and tag editing never
    /// disagree about what "the selection" means.
    private func tracksToRate() -> [LoadedTrack] {
        if selectedTrackIDs.count > 1 || selectedAlbumIDs.count > 1 || selectedArtistIDs.count > 1 {
            return selectedTracksForCrateAdd()
        }
        return selectedTrack.map { [$0] } ?? []
    }
```

- [ ] **Step 2: Write the control**

Create `Sources/CrateDiggerApp/UI/Carbon/Inspector/RatingStars.swift`:

```swift
import SwiftUI
import CrateDiggerCore

/// Five stars in the inspector. Clicking a lit star clears back to unrated, so
/// the control can undo itself without a separate button.
struct RatingStars: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    @State private var hovered: Int = 0

    private var rating: Int { model.ratingForSelection }

    var body: some View {
        HStack(spacing: 4) {
            Text("RATING")
                .font(CarbonFont.mono(8, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(theme.ink4)

            Spacer(minLength: 8)

            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= (hovered > 0 ? hovered : rating) ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(star <= (hovered > 0 ? hovered : rating) ? theme.orange : theme.ink4)
                    .onHover { inside in hovered = inside ? star : 0 }
                    .onTapGesture {
                        // Tapping the star you are already on clears the rating.
                        model.rateSelection(rating == star ? 0 : star)
                    }
                    .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .help("Rate the selected tracks. Click the same star again to clear.")
    }
}
```

- [ ] **Step 3: Put it in the inspector**

In `Sources/CrateDiggerApp/UI/Carbon/Inspector/InspectorPane.swift`, in `narrowLayout(height:)`, after the line `SpecRows(album: model.selectedAlbum)` (around line 157), add:

```swift
                        RatingStars()
```

Do the same in `wideLayout(width:)` after its own `SpecRows(album: model.selectedAlbum)` (around line 196). Both call sites are needed: they are the collapsed and expanded inspector layouts.

- [ ] **Step 4: Add the menu commands**

In `Sources/CrateDiggerApp/AppDelegate.swift`, after the `shuffleItem` block in the Playback menu (around line 941), add:

```swift
        playbackMenu.addItem(.separator())
        let ratingMenuItem = NSMenuItem(title: "Rating", action: nil, keyEquivalent: "")
        let ratingMenu = NSMenu(title: "Rating")
        ratingMenu.addItem(makeItem(title: "Clear Rating", action: #selector(setRating(_:)), key: "0"))
        for stars in 1...5 {
            let item = makeItem(
                title: stars == 1 ? "1 Star" : "\(stars) Stars",
                action: #selector(setRating(_:)),
                key: String(stars)
            )
            item.tag = stars
            ratingMenu.addItem(item)
        }
        ratingMenuItem.submenu = ratingMenu
        playbackMenu.addItem(ratingMenuItem)
```

The "Clear Rating" item keeps the default tag of 0, which is what the action reads.

Then add the action alongside the other `@objc` menu actions (near `setSleepMode(_:)` around line 247):

```swift
    @objc private func setRating(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        mainWindowController?.rateSelection(item.tag)
    }
```

And in `Sources/CrateDiggerApp/UI/MainWindowController.swift`, next to the
existing `setSleepMode(_:)` forwarder (line 320), add:

```swift
    func rateSelection(_ rating: Int) {
        hostingController.model.rateSelection(rating)
    }
```

- [ ] **Step 5: Build and run the whole suite**

Run: `swift build && scripts/test.sh`
Expected: `Build complete!` then PASS.

- [ ] **Step 6: Verify in the running app**

Launch, select a track, click three stars, confirm the OLED says `RATED 3 STARS` and that the stars stay lit after selecting away and back. Press ⌘0 and confirm they clear. Select two tracks with different ratings and confirm the control shows none rather than one of the two.

- [ ] **Step 7: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Inspector/RatingStars.swift \
        Sources/CrateDiggerApp/UI/Carbon/Inspector/InspectorPane.swift \
        Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Listening.swift \
        Sources/CrateDiggerApp/AppDelegate.swift \
        Sources/CrateDiggerApp/UI/MainWindowController.swift
git commit -m "feat(inspector): rate tracks, one to five stars

Inspector control plus Command-0 through Command-5. A field nothing can
set is dead weight, and Phase 2's rating rules need a writer."
```

---

## Task 8: `BrowserState` in Core

**Files:**
- Create: `Sources/CrateDiggerCore/Models/BrowserState.swift`
- Test: `Tests/CrateDiggerCoreTests/BrowserStateTests.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+ArrowNav.swift:5-7` (delete the local `BrowserColumn`)

**Interfaces:**
- Consumes: `Artist`, `Album`, `LoadedTrack`, `TrackSortField`, `AlbumSortField`, `ArtistSortField` (all existing Core types).
- Produces: `BrowserSort<Field>` with `.field` and `.ascending`; `BrowserColumn` (`.artist`, `.album`, `.track`); `BrowserState` with the properties and methods listed in the implementation below.

- [ ] **Step 1: Write the failing test**

Create `Tests/CrateDiggerCoreTests/BrowserStateTests.swift`:

```swift
#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// Selection has been the most-touched state in the app and the least tested.
/// These are its first tests.
final class BrowserStateTests: XCTestCase {

    private func track(_ name: String) -> LoadedTrack {
        let url = URL(fileURLWithPath: "/Music/Album/\(name).flac")
        return LoadedTrack(
            track: AudioTrack(fileURL: url, title: name, artist: "A", album: "Album"),
            metadata: ConversionMetadata()
        )
    }

    /// `Album` has no defaults for year/artworkHash, so they are spelled out.
    private func album(_ id: String, tracks: [LoadedTrack] = []) -> Album {
        Album(
            id: id,
            artistID: "artist",
            artistName: "A",
            title: id,
            year: nil,
            artworkHash: nil,
            tracks: tracks
        )
    }

    private func artist(_ id: String, albums: [Album] = []) -> Artist {
        Artist(id: id, name: id, albums: albums)
    }

    // MARK: - Mutual exclusivity

    func testPickingAnAlbumClearsArtistAndTrackSelections() {
        var state = BrowserState()
        let albums = [album("a1"), album("a2")]
        state.selectArtist(artist("ar1"), command: false, shift: false, ordered: [artist("ar1")])
        XCTAssertFalse(state.selectedArtistIDs.isEmpty)

        state.selectAlbum(albums[0], command: false, shift: false, ordered: albums, flat: false)

        XCTAssertTrue(state.selectedArtistIDs.isEmpty, "you pick artists or records, never both")
        XCTAssertTrue(state.selectedTrackIDs.isEmpty)
        XCTAssertEqual(state.selectedAlbumIDs, ["a1"])
    }

    func testPickingATrackClearsArtistAndAlbumSelections() {
        var state = BrowserState()
        let albums = [album("a1")]
        state.selectAlbum(albums[0], command: false, shift: false, ordered: albums, flat: false)

        let tracks = [track("one"), track("two")]
        state.selectTrack(tracks[0], command: false, shift: false, ordered: tracks)

        XCTAssertTrue(state.selectedAlbumIDs.isEmpty)
        XCTAssertTrue(state.selectedArtistIDs.isEmpty)
        XCTAssertEqual(state.selectedTrackIDs, [tracks[0].track.id])
    }

    // MARK: - Modifiers

    func testCommandClickTogglesOneItemWithoutClearingTheRest() {
        var state = BrowserState()
        let albums = [album("a1"), album("a2"), album("a3")]
        state.selectAlbum(albums[0], command: false, shift: false, ordered: albums, flat: false)
        state.selectAlbum(albums[2], command: true, shift: false, ordered: albums, flat: false)
        XCTAssertEqual(state.selectedAlbumIDs, ["a1", "a3"])

        state.selectAlbum(albums[2], command: true, shift: false, ordered: albums, flat: false)
        XCTAssertEqual(state.selectedAlbumIDs, ["a1"], "command-clicking a picked item unpicks it")
    }

    func testShiftClickSelectsTheRangeFromTheAnchor() {
        var state = BrowserState()
        let albums = [album("a1"), album("a2"), album("a3"), album("a4")]
        state.selectAlbum(albums[0], command: false, shift: false, ordered: albums, flat: false)
        state.selectAlbum(albums[2], command: false, shift: true, ordered: albums, flat: false)
        XCTAssertEqual(state.selectedAlbumIDs, ["a1", "a2", "a3"])
    }

    func testShiftRangeWorksBackwards() {
        var state = BrowserState()
        let albums = [album("a1"), album("a2"), album("a3"), album("a4")]
        state.selectAlbum(albums[3], command: false, shift: false, ordered: albums, flat: false)
        state.selectAlbum(albums[1], command: false, shift: true, ordered: albums, flat: false)
        XCTAssertEqual(state.selectedAlbumIDs, ["a2", "a3", "a4"])
    }

    // MARK: - Anchors and drill-down

    func testSelectingAnArtistDrillsIntoItsFirstAlbumAndTrack() {
        var state = BrowserState()
        let inner = track("first")
        let a = artist("ar1", albums: [album("a1", tracks: [inner])])
        state.selectArtist(a, command: false, shift: false, ordered: [a])
        XCTAssertEqual(state.selectedArtistID, "ar1")
        XCTAssertEqual(state.selectedAlbumID, "a1")
        XCTAssertEqual(state.selectedTrackID, inner.track.id)
    }

    func testFlatAlbumSelectionAlsoSetsTheArtistAnchor() {
        var state = BrowserState()
        let al = album("a1")
        state.selectAlbum(al, command: false, shift: false, ordered: [al], flat: true)
        XCTAssertEqual(state.selectedArtistID, al.artistID)
    }

    func testIsSelectedCountsBothTheAnchorAndTheSet() {
        var state = BrowserState()
        state.selectedAlbumID = "anchor"
        XCTAssertTrue(state.isAlbumSelected("anchor"))
        state.selectedAlbumIDs = ["other"]
        XCTAssertTrue(state.isAlbumSelected("other"))
    }

    func testClearMultiSelectionLeavesTheAnchorsAlone() {
        var state = BrowserState()
        let albums = [album("a1"), album("a2")]
        state.selectAlbum(albums[0], command: false, shift: false, ordered: albums, flat: false)
        state.clearMultiSelection()
        XCTAssertTrue(state.selectedAlbumIDs.isEmpty)
        XCTAssertEqual(state.selectedAlbumID, "a1", "the browser still has to show something")
    }

    // MARK: - Sort

    func testSortDefaultsMatchWhatTheBrowserHasAlwaysShown() {
        let state = BrowserState()
        XCTAssertEqual(state.trackSort.field, .trackNumber)
        XCTAssertTrue(state.trackSort.ascending)
        XCTAssertEqual(state.albumSort.field, .year)
        XCTAssertEqual(state.artistSort.field, .name)
    }

    func testChangingSortLeavesSelectionUntouched() {
        var state = BrowserState()
        let albums = [album("a1")]
        state.selectAlbum(albums[0], command: false, shift: false, ordered: albums, flat: false)
        let before = state.selectedAlbumIDs
        state.trackSort.field = .title
        state.trackSort.ascending = false
        XCTAssertEqual(state.selectedAlbumIDs, before)
    }
}
#endif
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `scripts/test.sh --filter BrowserStateTests`
Expected: build failure, `cannot find 'BrowserState' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CrateDiggerCore/Models/BrowserState.swift`:

```swift
import Foundation

/// Which browser column the keyboard arrows act on.
public enum BrowserColumn: Sendable, Equatable {
    case artist, album, track
}

/// A column's ordering: which field, which direction.
///
/// Named `BrowserSort` rather than the obvious `SortOrder` because Foundation
/// already has a `SortOrder`, and a Core type shadowing it is a trap for the
/// next person reading this.
public struct BrowserSort<Field: Equatable & Sendable>: Sendable, Equatable {
    public var field: Field
    public var ascending: Bool

    public init(field: Field, ascending: Bool = true) {
        self.field = field
        self.ascending = ascending
    }
}

/// Everything the browser is currently showing you and how: what is picked and
/// what order it is in.
///
/// This lived as roughly a dozen loose `@Published` properties on
/// `LibraryViewModel` plus 177 lines of selection rules in an extension, which
/// meant the most-clicked behaviour in the app had no tests at all. As a value
/// type the rules are testable, and the mutual-exclusivity invariant is
/// something one type enforces rather than something several call sites happen
/// to agree on.
///
/// Phase 1's search lands in the `filter` seam left at the bottom.
public struct BrowserState: Sendable, Equatable {

    // MARK: Anchors
    //
    // The last thing clicked in each column. Drives drill-down (picking an
    // artist moves the Album and Track columns) and is what a single selection
    // reads from, which is why clearing the multi-selection leaves these alone:
    // the browser always has to be showing something.

    public var selectedArtistID: String?
    public var selectedAlbumID: String?
    public var selectedTrackID: UUID?

    // MARK: Multi-selection
    //
    // Mutually exclusive by construction: you are picking whole artists, or
    // whole records, or individual tracks, never a mixture. Every select method
    // below clears the other two sets first.

    public var selectedArtistIDs: Set<String> = []
    public var selectedAlbumIDs: Set<String> = []
    public var selectedTrackIDs: Set<UUID> = []

    // MARK: Ordering

    public var trackSort = BrowserSort<TrackSortField>(field: .trackNumber)
    public var albumSort = BrowserSort<AlbumSortField>(field: .year)
    public var artistSort = BrowserSort<ArtistSortField>(field: .name)

    public var focusedColumn: BrowserColumn = .track

    public init() {}

    // MARK: - Predicates

    public func isArtistSelected(_ id: String) -> Bool {
        selectedArtistIDs.contains(id) || selectedArtistID == id
    }

    public func isAlbumSelected(_ id: String) -> Bool {
        selectedAlbumIDs.contains(id) || selectedAlbumID == id
    }

    public func isTrackSelected(_ id: UUID) -> Bool {
        selectedTrackIDs.contains(id) || selectedTrackID == id
    }

    public mutating func clearMultiSelection() {
        selectedArtistIDs = []
        selectedAlbumIDs = []
        selectedTrackIDs = []
    }

    // MARK: - Clicks

    /// Artist-column click with modifier keys. Clears the album/track sets,
    /// updates the anchor, and drills into the artist so the Album and Track
    /// columns follow.
    /// - Parameter ordered: the artists in their current display order, which is
    ///   what a shift-range is measured against.
    public mutating func selectArtist(_ artist: Artist, command: Bool, shift: Bool, ordered: [Artist]) {
        let id = artist.id
        selectedAlbumIDs = []
        selectedTrackIDs = []
        if command {
            if selectedArtistIDs.contains(id) { selectedArtistIDs.remove(id) } else { selectedArtistIDs.insert(id) }
        } else if shift, let anchor = selectedArtistID,
                  let a = ordered.firstIndex(where: { $0.id == anchor }),
                  let b = ordered.firstIndex(where: { $0.id == id }) {
            selectedArtistIDs = Set(ordered[min(a, b)...max(a, b)].map(\.id))
        } else {
            selectedArtistIDs = [id]
        }
        selectedArtistID = id
        selectedAlbumID = artist.albums.first?.id
        selectedTrackID = artist.albums.first?.tracks.first?.track.id
    }

    /// Album-column click with modifier keys. Clears the artist/track sets,
    /// updates the anchor, and drills into the album so the Track column
    /// follows the last click.
    /// - Parameter flat: true in the flat Album/Track layout, where there is no
    ///   Artist column to have set the artist anchor already.
    public mutating func selectAlbum(_ album: Album, command: Bool, shift: Bool, ordered: [Album], flat: Bool) {
        let id = album.id
        selectedArtistIDs = []
        selectedTrackIDs = []
        if command {
            if selectedAlbumIDs.contains(id) { selectedAlbumIDs.remove(id) } else { selectedAlbumIDs.insert(id) }
        } else if shift, let anchor = selectedAlbumID,
                  let a = ordered.firstIndex(where: { $0.id == anchor }),
                  let b = ordered.firstIndex(where: { $0.id == id }) {
            selectedAlbumIDs = Set(ordered[min(a, b)...max(a, b)].map(\.id))
        } else {
            selectedAlbumIDs = [id]
        }
        if flat { selectedArtistID = album.artistID }
        selectedAlbumID = id
        selectedTrackID = album.tracks.first?.track.id
    }

    /// Track-column click with modifier keys. Clears the artist/album sets and
    /// updates the anchor.
    public mutating func selectTrack(_ loaded: LoadedTrack, command: Bool, shift: Bool, ordered: [LoadedTrack]) {
        let id = loaded.track.id
        selectedArtistIDs = []
        selectedAlbumIDs = []
        if command {
            if selectedTrackIDs.contains(id) { selectedTrackIDs.remove(id) } else { selectedTrackIDs.insert(id) }
        } else if shift, let anchor = selectedTrackID,
                  let a = ordered.firstIndex(where: { $0.track.id == anchor }),
                  let b = ordered.firstIndex(where: { $0.track.id == id }) {
            selectedTrackIDs = Set(ordered[min(a, b)...max(a, b)].map { $0.track.id })
        } else {
            selectedTrackIDs = [id]
        }
        selectedTrackID = id
    }

    // MARK: - Select all

    public mutating func selectAllArtists(_ artists: [Artist]) {
        guard !artists.isEmpty else { return }
        selectedAlbumIDs = []
        selectedTrackIDs = []
        selectedArtistIDs = Set(artists.map(\.id))
        if selectedArtistID == nil { selectedArtistID = artists.first?.id }
    }

    public mutating func selectAllAlbums(_ albums: [Album]) {
        guard !albums.isEmpty else { return }
        selectedArtistIDs = []
        selectedTrackIDs = []
        selectedAlbumIDs = Set(albums.map(\.id))
        if selectedAlbumID == nil { selectedAlbumID = albums.first?.id }
    }

    public mutating func selectAllTracks(_ tracks: [LoadedTrack]) {
        guard !tracks.isEmpty else { return }
        selectedArtistIDs = []
        selectedAlbumIDs = []
        selectedTrackIDs = Set(tracks.map { $0.track.id })
        if selectedTrackID == nil { selectedTrackID = tracks.first?.track.id }
    }

    // MARK: - Phase 1 seam
    //
    // Search lands here: a query string plus whatever scope it runs at. Left
    // empty deliberately rather than guessed at, so Phase 1 designs it against
    // a real search field instead of against this comment.
}
```

- [ ] **Step 4: Delete the app-layer `BrowserColumn`**

In `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+ArrowNav.swift`, delete these lines:

```swift
/// Which browser column the keyboard arrows act on.
enum BrowserColumn: Sendable {
    case artist, album, track
}
```

The file already has `import CrateDiggerCore`, so the Core type takes over with no other change.

- [ ] **Step 5: Run the test to verify it passes**

Run: `scripts/test.sh --filter BrowserStateTests`
Expected: PASS, 11 tests.

- [ ] **Step 6: Build and run the whole suite**

Run: `swift build && scripts/test.sh`
Expected: `Build complete!` then PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/CrateDiggerCore/Models/BrowserState.swift \
        Tests/CrateDiggerCoreTests/BrowserStateTests.swift \
        Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+ArrowNav.swift
git commit -m "feat(core): BrowserState, selection and sort as a tested value type

The selection rules move out of a view model extension and get their
first tests. The view model still owns its own copies; Task 9 switches
it over."
```

---

## Task 9: Point the view model at `BrowserState`

The load-bearing task. Nothing outside `LibraryViewModel.swift` and `+MultiSelect.swift` changes, because every property keeps its name as a computed forward.

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift:113-115, 127-129, 497-513, 580, 929-940`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+MultiSelect.swift`

**Interfaces:**
- Consumes: `BrowserState` from Task 8.
- Produces: `LibraryViewModel.browser: BrowserState` (published). Every existing property name is preserved.

- [ ] **Step 1: Replace the stored selection properties**

In `LibraryViewModel.swift`, replace these six lines (at 113-115 and 127-129):

```swift
    @Published var selectedArtistID: String?
    @Published var selectedAlbumID: String?
    @Published var selectedTrackID: UUID?
```
```swift
    @Published var selectedArtistIDs: Set<String> = []
    @Published var selectedAlbumIDs: Set<String> = []
    @Published var selectedTrackIDs: Set<UUID> = []
```

with a single published struct plus forwards. Put the struct where the first block was:

```swift
    /// Selection, ordering and (from Phase 1) filtering, as one tested Core
    /// value type. The properties below forward onto it so the ~190 call sites
    /// that read `selectedTrackIDs` or `trackSortField` did not have to move.
    @Published var browser = BrowserState()

    var selectedArtistID: String? {
        get { browser.selectedArtistID }
        set { browser.selectedArtistID = newValue }
    }
    var selectedAlbumID: String? {
        get { browser.selectedAlbumID }
        set { browser.selectedAlbumID = newValue }
    }
    var selectedTrackID: UUID? {
        get { browser.selectedTrackID }
        set { browser.selectedTrackID = newValue }
    }
    var selectedArtistIDs: Set<String> {
        get { browser.selectedArtistIDs }
        set { browser.selectedArtistIDs = newValue }
    }
    var selectedAlbumIDs: Set<String> {
        get { browser.selectedAlbumIDs }
        set { browser.selectedAlbumIDs = newValue }
    }
    var selectedTrackIDs: Set<UUID> {
        get { browser.selectedTrackIDs }
        set { browser.selectedTrackIDs = newValue }
    }
```

Delete the now-empty second block at 127-129.

- [ ] **Step 2: Replace the stored sort properties**

Replace the block at 497-513 (the six sort properties with their `didSet`s) with forwards that keep the same side effects:

```swift
    /// How the Track column orders the currently shown album.
    var trackSortField: TrackSortField {
        get { browser.trackSort.field }
        set {
            browser.trackSort.field = newValue
            prefs.savedTrackSortField = newValue.rawValue
            recomputeSortedCollections()
        }
    }
    var trackSortAscending: Bool {
        get { browser.trackSort.ascending }
        set {
            browser.trackSort.ascending = newValue
            prefs.savedTrackSortAscending = newValue
            recomputeSortedCollections()
        }
    }
    var artistSortField: ArtistSortField {
        get { browser.artistSort.field }
        set {
            browser.artistSort.field = newValue
            prefs.savedArtistSortField = newValue.rawValue
            recomputeSortedCollections()
        }
    }
    var artistSortAscending: Bool {
        get { browser.artistSort.ascending }
        set {
            browser.artistSort.ascending = newValue
            prefs.savedArtistSortAscending = newValue
            recomputeSortedCollections()
        }
    }
    var albumSortField: AlbumSortField {
        get { browser.albumSort.field }
        set {
            browser.albumSort.field = newValue
            prefs.savedAlbumSortField = newValue.rawValue
            recomputeSortedCollections()
        }
    }
    var albumSortAscending: Bool {
        get { browser.albumSort.ascending }
        set {
            browser.albumSort.ascending = newValue
            prefs.savedAlbumSortAscending = newValue
            recomputeSortedCollections()
        }
    }
```

Leave `showSortControls` exactly as it is: it is chrome, not browser state, and stays a stored `@Published`.

Per-property setters rather than one `didSet` on `browser` are the point. A single observer on the whole struct cannot tell a sort change from a selection change, so every click in the browser would re-sort the entire library.

- [ ] **Step 3: Forward `focusedColumn`**

Replace the line at 580:

```swift
    @Published var focusedColumn: BrowserColumn = .track
```

with:

```swift
    var focusedColumn: BrowserColumn {
        get { browser.focusedColumn }
        set { browser.focusedColumn = newValue }
    }
```

- [ ] **Step 4: Fix the init restore**

This is the one place the forwards change behaviour, and it must be handled explicitly. The restore block at 929-940 runs inside `init`, where property observers do not fire — so today `recomputeSortedCollections()` is *not* called. Computed setters always run, so leaving the block as-is would call it during init against a not-yet-populated index.

Replace the restore block with direct writes to the struct:

```swift
        // Direct to `browser`, not through the forwarding setters: those call
        // recomputeSortedCollections(), and during init there is no index to
        // recompute against. The stored properties this replaced had didSet
        // observers, which do not fire in init either, so this preserves the
        // existing behaviour exactly.
        if let savedField = prefs.savedTrackSortField, let field = TrackSortField(rawValue: savedField) {
            browser.trackSort.field = field
        }
        browser.trackSort.ascending = prefs.savedTrackSortAscending
        if let savedField = prefs.savedArtistSortField, let field = ArtistSortField(rawValue: savedField) {
            browser.artistSort.field = field
        }
        browser.artistSort.ascending = prefs.savedArtistSortAscending
        if let savedField = prefs.savedAlbumSortField, let field = AlbumSortField(rawValue: savedField) {
            browser.albumSort.field = field
        }
        browser.albumSort.ascending = prefs.savedAlbumSortAscending
```

Leave the `showSortControls = prefs.savedShowSortControls` line that follows it untouched.

- [ ] **Step 5: Make `+MultiSelect` delegate**

In `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+MultiSelect.swift`:

Change the import line from `import AppKit` to nothing (delete it) — it was never used. Keep `import CrateDiggerCore`.

Replace the predicate and click methods with delegation, keeping every signature identical so call sites do not move:

```swift
    func isArtistSelected(_ id: String) -> Bool { browser.isArtistSelected(id) }
    func isAlbumSelected(_ id: String) -> Bool { browser.isAlbumSelected(id) }
    func isTrackSelected(_ id: UUID) -> Bool { browser.isTrackSelected(id) }

    func clearMultiSelection() { browser.clearMultiSelection() }

    func selectArtist(_ artist: Artist, command: Bool, shift: Bool, ordered: [Artist]) {
        browser.selectArtist(artist, command: command, shift: shift, ordered: ordered)
    }

    func selectAlbum(_ album: Album, command: Bool, shift: Bool, ordered: [Album], flat: Bool) {
        browser.selectAlbum(album, command: command, shift: shift, ordered: ordered, flat: flat)
    }

    func selectTrack(_ loaded: LoadedTrack, command: Bool, shift: Bool, ordered: [LoadedTrack]) {
        browser.selectTrack(loaded, command: command, shift: shift, ordered: ordered)
    }

    func selectAllArtists() { browser.selectAllArtists(index.artists) }
    func selectAllAlbums() { browser.selectAllAlbums(index.allAlbums) }
    func selectAllTracks() { browser.selectAllTracks(index.allTracks) }
```

Leave `selectAllInSource()`, `selectedTracksForCrateAdd()`, `tracksForInspectorTagEdit()` and `addSelectionToCrate(crateName:)` exactly as they are: they read `index` and `browserLayout`, which are view-model concerns, not browser state.

- [ ] **Step 6: Build**

Run: `swift build`
Expected: `Build complete!` The compiler is the coverage here — if any of the 121 selection or 65 sort references needed to change, it will say so. If one does, forward the property rather than editing the call site.

- [ ] **Step 7: Run the whole suite**

Run: `scripts/test.sh`
Expected: PASS.

- [ ] **Step 8: Verify in the running app**

This task has no user-visible deliverable, which is exactly why it needs hands-on checking. Launch and confirm, in order:

1. Click an artist: the Album and Track columns follow it.
2. Shift-click three albums: all three highlight.
3. Command-click one of them: it unhighlights, the others stay.
4. Click a track: the album highlight clears.
5. Change the Track column sort field, then the direction: the list reorders both times.
6. Quit and relaunch: the sort you chose is still applied.
7. Arrow keys still move within a column and switch columns.

- [ ] **Step 9: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift \
        Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+MultiSelect.swift
git commit -m "refactor(library): browser selection and sort live in Core

LibraryViewModel keeps every property name as a computed forward onto
BrowserState, so no call site outside the view model moves. The init
restore writes the struct directly, because computed setters run during
init where the didSet observers they replaced did not."
```

---

## Task 10: Documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Correct the view model size and describe the new types**

In `CLAUDE.md`, in the "`LibraryViewModel` — the center of gravity" section, change `(~2600 lines)` to `(~4200 lines)`, and add `+Listening` to the list of `LibraryViewModel+*.swift` extensions.

In the same section, after the paragraph ending "this is where the wiring lives", add:

```markdown
**Browser state is no longer here.** Selection (anchors + the three
mutually-exclusive multi-selection sets), the three sort pairs and
`focusedColumn` live in Core's `BrowserState`; the view model holds one
`@Published var browser` and forwards every old property name onto it as a
computed property. Add browser state to `BrowserState`, not here. The
forwarding setters are where the `PreferencesStore` writes and the
`recomputeSortedCollections()` call live — a single `didSet` on `browser`
would re-sort the whole library on every click.
```

- [ ] **Step 2: Document the listening store**

In `CLAUDE.md`, in the "Sources model" section immediately after the paragraph describing `TrackStore` and `ArtworkStore`, add:

```markdown
- **Listening history** is a third store in the same folder: `library.cdplays`,
  a path-keyed `[String: ListeningStats]` holding play count, skip count, last
  played, date added and rating. Deliberately NOT a field on `LoadedTrack`:
  `TrackStore.upsert` replaces whole records and the retag, relink and rescan
  paths all rebuild one, so stats living there would be one forgotten line away
  from being silently zeroed. Anything that changes a track's path must call
  `ListeningStore.repoint(from:to:)` alongside the `TrackStore` update — the
  same choke points already do both. Plays are counted against
  `PlayThreshold.isPlayed`, which is also what triggers a Last.fm scrobble, so
  the two can never drift.
```

- [ ] **Step 3: Add the changelog entry**

In `CHANGELOG.md`, under the `## 2.0.0 (73) — 2026-08-28 — BETA 1` heading's `### Added` list, add at the top:

```markdown
- **CrateDigger remembers what you play.** Play counts, skips, when you last
  heard something, when it was added, and a one to five star rating on every
  track. Rate from the inspector or with Command-1 through Command-5. None of
  it is visible in the browser yet; it is the foundation the smart crates and
  the listening stats are built on.
```

- [ ] **Step 4: Verify the copy has no em dashes**

Run: `grep -n "—\|–" CHANGELOG.md | head -20`
Expected: existing entries may contain them; your new entry must not. Check your added lines specifically.

- [ ] **Step 5: Run the whole suite one final time**

Run: `scripts/test.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md CHANGELOG.md
git commit -m "docs: Phase 0 foundations

Records the listening store's separation from the track store and the
move of browser state into Core, and corrects the view model line count."
```

---

## Done when

- `scripts/test.sh` passes with the four new suites: `PlayThresholdTests`, `ListeningStatsTests`, `ListeningStorePersistenceTests`, `BrowserStateTests`.
- Playing a track past the threshold writes a row to `library.cdplays`; skipping one early writes a skip and no play.
- Rating from the inspector and from Command-1 through Command-5 both stick across a relaunch.
- Renaming a track through a tag edit that moves the file keeps its play count.
- Every browser interaction in Task 9 Step 8 behaves as it did before.
- `BrowserState` has the empty Phase 1 filter seam and nothing more.
