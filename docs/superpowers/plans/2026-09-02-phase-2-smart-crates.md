# Smart Crates (2.0 Phase 2, part one) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A crate that is a rule set instead of a list of paths, sitting in the
same sidebar as every other crate and keeping itself current.

**Architecture:** A pure rule engine in `CrateDiggerCore` (model, evaluator,
context, file store), then thin wiring in `CrateDiggerApp` (a `LibrarySource`
case, sidebar rows, an editor sheet). Rules always match tracks. The two
expensive facts, whether a file still exists and whether a track is a probable
duplicate, are computed once per pass and only when some rule asks for them.

**Tech Stack:** Swift 5.9 / macOS 13, SwiftPM two-target layout, XCTest via
`scripts/test.sh`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-02-phase-2-3-smart-crates-health-design.md`

## Global Constraints

- **Core stays pure.** `CrateDiggerCore` has no AppKit views and no app state.
  Everything in Tasks 1 to 6 is `public`, `Sendable`, and testable in isolation.
- **Run `scripts/test.sh`, never bare `swift test`.** Filter with
  `scripts/test.sh --filter SmartCrateEvaluatorTests`.
- **Every Core test file is wrapped in `#if canImport(XCTest)` … `#endif`** and
  imports `@testable import CrateDiggerCore`. Match the shape of
  `Tests/CrateDiggerCoreTests/GallerySectionTests.swift`.
- **No em dashes, en dashes, or hyphens as sentence punctuation in any
  user-facing string** (menu titles, tooltips, alerts, button labels). Hyphens
  inside real names are fine. This is a standing project rule.
- **Rules match tracks, never albums.** Where a count reads better as albums,
  the caller counts distinct albums among matched tracks.
- **An empty rule list matches nothing.**
- **Absence is not zero.** `year`, `rating`, `lastPlayed` and the text fields
  distinguish "no value" from "zero" or "empty string".
- **Commit after every task**, with the trailer:
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`

---

### Task 1: The rule model

**Files:**
- Create: `Sources/CrateDiggerCore/Models/SmartCrate.swift`
- Test: `Tests/CrateDiggerCoreTests/SmartCrateModelTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `SmartCrate(name:match:rules:)`, `SmartRule(_:_:_:)`, `MatchMode`,
  `RuleField`, `RuleFieldKind`, `RuleOperator`, `RuleValue`,
  `RuleField.kind`, `RuleField.title`, `RuleFieldKind.operators`.

- [ ] **Step 1: Write the failing test**

Create `Tests/CrateDiggerCoreTests/SmartCrateModelTests.swift`:

```swift
#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// The on-disk shape of a smart crate, and the field/operator table the
/// editor's menus are built from.
final class SmartCrateModelTests: XCTestCase {

    func testRoundTripsThroughJSON() throws {
        let crate = SmartCrate(name: "Never Played FLAC", match: .all, rules: [
            SmartRule(.format, .equals, .text("FLAC")),
            SmartRule(.playCount, .isAtMost, .number(0)),
            SmartRule(.lastPlayed, .isEmpty, .blank),
        ])

        let data = try JSONEncoder().encode(crate)
        let decoded = try JSONDecoder().decode(SmartCrate.self, from: data)

        XCTAssertEqual(decoded, crate)
    }

    /// The file is meant to be readable and shareable, so the value encodes as
    /// a single-key object naming its type rather than a bare string.
    func testValueEncodesAsATaggedObject() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(RuleValue.text("FLAC")), as: UTF8.self)
        XCTAssertEqual(json, #"{"text":"FLAC"}"#)

        let none = String(decoding: try encoder.encode(RuleValue.blank), as: UTF8.self)
        XCTAssertEqual(none, #"{"none":true}"#)
    }

    func testEveryFieldDeclaresAKindAndATitle() {
        for field in RuleField.allCases {
            XCTAssertFalse(field.title.isEmpty, "\(field) has no title for the editor")
            XCTAssertFalse(field.kind.operators.isEmpty, "\(field.kind) offers no operators")
        }
    }

    /// The editor builds its operator menu from the kind, so the table has to
    /// agree with what the evaluator can actually do.
    func testOperatorTableMatchesTheSpec() {
        XCTAssertEqual(RuleFieldKind.text.operators, [
            .equals, .notEquals, .contains, .doesNotContain,
            .beginsWith, .endsWith, .isEmpty, .isNotEmpty,
        ])
        XCTAssertEqual(RuleFieldKind.number.operators, [
            .equals, .notEquals, .isAtLeast, .isAtMost, .isEmpty,
        ])
        XCTAssertEqual(RuleFieldKind.date.operators, [
            .isBefore, .isAfter, .inLastDays, .notInLastDays, .isEmpty,
        ])
        XCTAssertEqual(RuleFieldKind.choice.operators, [.equals, .notEquals])
        XCTAssertEqual(RuleFieldKind.flag.operators, [.isTrue, .isFalse])
    }

    func testFieldsSitInTheKindTheSpecGivesThem() {
        XCTAssertEqual(RuleField.title.kind, .text)
        XCTAssertEqual(RuleField.year.kind, .number)
        XCTAssertEqual(RuleField.rating.kind, .number)
        XCTAssertEqual(RuleField.lastPlayed.kind, .date)
        XCTAssertEqual(RuleField.format.kind, .choice)
        XCTAssertEqual(RuleField.hasArtwork.kind, .flag)
    }

    func testEmptyCrateHasSaneDefaults() {
        let crate = SmartCrate(name: "New Crate")
        XCTAssertEqual(crate.match, .all)
        XCTAssertTrue(crate.rules.isEmpty)
        XCTAssertEqual(crate.id, "New Crate")
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter SmartCrateModelTests`
Expected: build failure, "cannot find 'SmartCrate' in scope".

- [ ] **Step 3: Write the model**

Create `Sources/CrateDiggerCore/Models/SmartCrate.swift`:

```swift
import Foundation

/// A crate defined by what its members have in common rather than by a list of
/// paths. Evaluated against the library on demand; see `SmartCrateEvaluator`.
///
/// Persisted as one small JSON file per crate (`SmartCrateStore`), carrying no
/// track data at all, which is what makes a smart crate shareable in a way a
/// membership list is not.
public struct SmartCrate: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var match: MatchMode
    public var rules: [SmartRule]

    /// The name is the identity: it is the file name and the sidebar row, and
    /// two crates cannot share one.
    public var id: String { name }

    public init(name: String, match: MatchMode = .all, rules: [SmartRule] = []) {
        self.name = name
        self.match = match
        self.rules = rules
    }
}

/// Whether every rule has to hold, or any one of them.
public enum MatchMode: String, Codable, Sendable, CaseIterable {
    case all
    case any

    /// The word the editor puts in its toggle.
    public var title: String {
        switch self {
        case .all: return "ALL"
        case .any: return "ANY"
        }
    }
}

public struct SmartRule: Codable, Sendable, Equatable {
    public var field: RuleField
    public var op: RuleOperator
    public var value: RuleValue

    public init(_ field: RuleField, _ op: RuleOperator, _ value: RuleValue) {
        self.field = field
        self.op = op
        self.value = value
    }
}

// MARK: - Fields

/// What a rule reads off a track. Each belongs to a `RuleFieldKind`, and the
/// kind decides which operators apply and how the evaluator extracts a value,
/// so adding a field is one case here and one line in `kind`.
public enum RuleField: String, Codable, Sendable, CaseIterable {
    case title
    case artist
    case albumArtist
    case album
    case genre
    case comment
    case path

    case year
    case bitrate
    case sampleRate
    case duration
    case playCount
    case skipCount
    case rating
    case trackNumber

    case lastPlayed
    case dateAdded

    case format

    case hasArtwork
    case fileExists
    case isDuplicate

    public var kind: RuleFieldKind {
        switch self {
        case .title, .artist, .albumArtist, .album, .genre, .comment, .path:
            return .text
        case .year, .bitrate, .sampleRate, .duration,
             .playCount, .skipCount, .rating, .trackNumber:
            return .number
        case .lastPlayed, .dateAdded:
            return .date
        case .format:
            return .choice
        case .hasArtwork, .fileExists, .isDuplicate:
            return .flag
        }
    }

    /// The label in the editor's field menu.
    public var title: String {
        switch self {
        case .title:       return "Title"
        case .artist:      return "Artist"
        case .albumArtist: return "Album Artist"
        case .album:       return "Album"
        case .genre:       return "Genre"
        case .comment:     return "Comment"
        case .path:        return "File Path"
        case .year:        return "Year"
        case .bitrate:     return "Bitrate"
        case .sampleRate:  return "Sample Rate"
        case .duration:    return "Duration"
        case .playCount:   return "Play Count"
        case .skipCount:   return "Skip Count"
        case .rating:      return "Rating"
        case .trackNumber: return "Track Number"
        case .lastPlayed:  return "Last Played"
        case .dateAdded:   return "Date Added"
        case .format:      return "Format"
        case .hasArtwork:  return "Has Artwork"
        case .fileExists:  return "File Exists"
        case .isDuplicate: return "Is Duplicate"
        }
    }
}

public enum RuleFieldKind: String, Sendable, CaseIterable {
    case text
    case number
    case date
    case choice
    case flag

    /// What the editor offers for a field of this kind, in menu order.
    public var operators: [RuleOperator] {
        switch self {
        case .text:
            return [.equals, .notEquals, .contains, .doesNotContain,
                    .beginsWith, .endsWith, .isEmpty, .isNotEmpty]
        case .number:
            return [.equals, .notEquals, .isAtLeast, .isAtMost, .isEmpty]
        case .date:
            return [.isBefore, .isAfter, .inLastDays, .notInLastDays, .isEmpty]
        case .choice:
            return [.equals, .notEquals]
        case .flag:
            return [.isTrue, .isFalse]
        }
    }
}

public enum RuleOperator: String, Codable, Sendable, CaseIterable {
    case equals = "is"
    case notEquals = "isNot"
    case contains
    case doesNotContain
    case beginsWith
    case endsWith
    case isAtLeast
    case isAtMost
    case isBefore
    case isAfter
    case inLastDays
    case notInLastDays
    case isEmpty
    case isNotEmpty
    case isTrue
    case isFalse

    /// The label in the editor's operator menu.
    public var title: String {
        switch self {
        case .equals:         return "is"
        case .notEquals:      return "is not"
        case .contains:       return "contains"
        case .doesNotContain: return "does not contain"
        case .beginsWith:     return "begins with"
        case .endsWith:       return "ends with"
        case .isAtLeast:      return "is at least"
        case .isAtMost:       return "is at most"
        case .isBefore:       return "is before"
        case .isAfter:        return "is after"
        case .inLastDays:     return "in the last"
        case .notInLastDays:  return "not in the last"
        case .isEmpty:        return "is empty"
        case .isNotEmpty:     return "is not empty"
        case .isTrue:         return "is true"
        case .isFalse:        return "is false"
        }
    }

    /// Whether the rule carries a value the editor has to collect. `is empty`
    /// and the two flag operators are complete on their own.
    public var needsValue: Bool {
        switch self {
        case .isEmpty, .isNotEmpty, .isTrue, .isFalse: return false
        default: return true
        }
    }
}

// MARK: - Values

/// A rule's right-hand side. Encoded as a single-key object naming the type
/// (`{"text": "FLAC"}`) so a hand-edited file stays readable and a decode
/// cannot silently reinterpret a number as a string.
public enum RuleValue: Codable, Sendable, Equatable {
    case blank
    case text(String)
    case number(Double)
    case date(Date)
    case days(Int)

    private enum CodingKeys: String, CodingKey {
        case blank, text, number, date, days
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .text(text)
        } else if let number = try container.decodeIfPresent(Double.self, forKey: .number) {
            self = .number(number)
        } else if let date = try container.decodeIfPresent(Date.self, forKey: .date) {
            self = .date(date)
        } else if let days = try container.decodeIfPresent(Int.self, forKey: .days) {
            self = .days(days)
        } else {
            self = .blank
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .blank:           try container.encode(true, forKey: .blank)
        case .text(let v):     try container.encode(v, forKey: .text)
        case .number(let v):   try container.encode(v, forKey: .number)
        case .date(let v):     try container.encode(v, forKey: .date)
        case .days(let v):     try container.encode(v, forKey: .days)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter SmartCrateModelTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Models/SmartCrate.swift Tests/CrateDiggerCoreTests/SmartCrateModelTests.swift
git commit -m "$(cat <<'EOF'
feat(core): the smart crate rule model

A crate defined by what its members have in common: a name, a match mode
and a flat list of field/operator/value rules. Each field declares a kind,
and the kind owns the operator list, so the editor's menus and the
evaluator read one table rather than two.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: The context, and what it has to compute

**Files:**
- Create: `Sources/CrateDiggerCore/Services/RuleContext.swift`
- Test: `Tests/CrateDiggerCoreTests/RuleContextTests.swift`

**Interfaces:**
- Consumes: `SmartCrate`, `SmartRule`, `RuleField` (Task 1); `ListeningStats`,
  `LibraryIndex`, `LoadedTrack`.
- Produces: `RuleContext(statsByPath:coveredTrackIDs:missingPaths:duplicatePaths:now:)`,
  `RuleContext.Requirements` (`.fileExistence`, `.duplicates`),
  `RuleContext.requirements(for:)`,
  `RuleContext.coveredTrackIDs(in:)`.

- [ ] **Step 1: Write the failing test**

Create `Tests/CrateDiggerCoreTests/RuleContextTests.swift`:

```swift
#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// The context carries the facts a rule cannot read off a track by itself.
/// Two of them cost real work, so the property that matters is that they are
/// asked for only when some rule actually reads them.
final class RuleContextTests: XCTestCase {

    private func crate(_ rules: SmartRule...) -> SmartCrate {
        SmartCrate(name: "C", match: .all, rules: rules)
    }

    func testNothingExpensiveIsRequiredForOrdinaryRules() {
        let requirements = RuleContext.requirements(for: [
            crate(SmartRule(.genre, .equals, .text("Jazz"))),
            crate(SmartRule(.rating, .isAtLeast, .number(4))),
        ])
        XCTAssertTrue(requirements.isEmpty)
    }

    func testFileExistenceIsRequiredOnlyByItsField() {
        let requirements = RuleContext.requirements(for: [
            crate(SmartRule(.fileExists, .isFalse, .blank)),
        ])
        XCTAssertTrue(requirements.contains(.fileExistence))
        XCTAssertFalse(requirements.contains(.duplicates))
    }

    func testDuplicatesIsRequiredOnlyByItsField() {
        let requirements = RuleContext.requirements(for: [
            crate(SmartRule(.isDuplicate, .isTrue, .blank)),
        ])
        XCTAssertTrue(requirements.contains(.duplicates))
        XCTAssertFalse(requirements.contains(.fileExistence))
    }

    /// Several crates asking for the same lookup is still one lookup: the
    /// caller builds from the union, which is the whole point of asking once
    /// for the whole set rather than once per crate.
    func testRequirementsAreTheUnionAcrossCrates() {
        let requirements = RuleContext.requirements(for: [
            crate(SmartRule(.fileExists, .isFalse, .blank)),
            crate(SmartRule(.isDuplicate, .isTrue, .blank)),
            crate(SmartRule(.genre, .equals, .text("Jazz"))),
        ])
        XCTAssertEqual(requirements, [.fileExistence, .duplicates])
    }

    /// A track with no art of its own is still covered when its album has a
    /// cover, which is what makes "no cover art" mean albums.
    func testCoverageFallsBackToTheAlbum() {
        let covered = LoadedTrack(
            track: AudioTrack(fileURL: URL(fileURLWithPath: "/m/a/1.flac"), title: "One",
                              artist: "A", album: "Covered", artworkHash: nil),
            metadata: ConversionMetadata()
        )
        let bare = LoadedTrack(
            track: AudioTrack(fileURL: URL(fileURLWithPath: "/m/b/1.flac"), title: "Two",
                              artist: "B", album: "Bare", artworkHash: nil),
            metadata: ConversionMetadata()
        )
        let withOwnArt = LoadedTrack(
            track: AudioTrack(fileURL: URL(fileURLWithPath: "/m/b/2.flac"), title: "Three",
                              artist: "B", album: "Bare", artworkHash: "hash-own"),
            metadata: ConversionMetadata()
        )

        // Album "Covered" carries a hash at the album level; "Bare" does not.
        var index = LibraryIndex.build(from: [covered, bare, withOwnArt])
        index = Self.stampingAlbumArtwork(index, albumTitled: "Covered", hash: "hash-album")

        let ids = RuleContext.coveredTrackIDs(in: index)
        XCTAssertTrue(ids.contains(covered.track.id), "an album cover covers its tracks")
        XCTAssertTrue(ids.contains(withOwnArt.track.id), "a track's own art counts")
        XCTAssertFalse(ids.contains(bare.track.id))
    }

    /// Rebuilds the index with one album's artwork hash set, which
    /// `LibraryIndex.build` only does when the files carry art.
    private static func stampingAlbumArtwork(_ index: LibraryIndex,
                                             albumTitled title: String,
                                             hash: String) -> LibraryIndex {
        let artists = index.artists.map { artist -> Artist in
            let albums = artist.albums.map { album -> Album in
                guard album.title == title else { return album }
                return Album(id: album.id, artistID: album.artistID, artistName: album.artistName,
                             title: album.title, year: album.year, artworkHash: hash,
                             tracks: album.tracks)
            }
            return Artist(id: artist.id, name: artist.name, albums: albums)
        }
        return LibraryIndex(artists: artists, allTracks: index.allTracks,
                            albumCount: index.albumCount, totalSizeBytes: index.totalSizeBytes)
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter RuleContextTests`
Expected: build failure, "cannot find 'RuleContext' in scope".

If `Artist(id:name:albums:)` does not match the real initializer, read
`Sources/CrateDiggerCore/Models/Artist.swift` and adjust the helper. Do not
change the assertions.

- [ ] **Step 3: Write the context**

Create `Sources/CrateDiggerCore/Services/RuleContext.swift`:

```swift
import Foundation

/// The facts a rule needs that are not on the track itself.
///
/// Two of them are expensive: whether a file still exists is a stat per track,
/// and whether a track is a probable duplicate is a grouping pass over the
/// whole library. Neither can run on every index change, so both are optional
/// and are built only when `requirements(for:)` says some rule reads them.
///
/// `nil` and empty mean different things. `nil` is "nobody asked, this was
/// never computed", and a rule reading a `nil` lookup does not match. Treating
/// an uncomputed lookup as "everything is fine" would show a duplicates crate
/// as empty, which reads as a clean library rather than as a pending scan.
public struct RuleContext: Sendable {
    public let statsByPath: [String: ListeningStats]
    /// Tracks that have artwork of their own or sit in an album that does.
    public let coveredTrackIDs: Set<UUID>
    public let missingPaths: Set<String>?
    public let duplicatePaths: Set<String>?
    /// Injected rather than read inside the evaluator: "played in the last
    /// thirty days" is otherwise untestable without freezing the clock.
    public let now: Date

    public init(
        statsByPath: [String: ListeningStats] = [:],
        coveredTrackIDs: Set<UUID> = [],
        missingPaths: Set<String>? = nil,
        duplicatePaths: Set<String>? = nil,
        now: Date = Date()
    ) {
        self.statsByPath = statsByPath
        self.coveredTrackIDs = coveredTrackIDs
        self.missingPaths = missingPaths
        self.duplicatePaths = duplicatePaths
        self.now = now
    }

    // MARK: - Requirements

    public struct Requirements: OptionSet, Sendable, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let fileExistence = Requirements(rawValue: 1 << 0)
        public static let duplicates = Requirements(rawValue: 1 << 1)
    }

    /// Which expensive lookups this set of crates reads between them. Asked
    /// once for the whole set so each lookup is built at most once, however
    /// many crates want it.
    public static func requirements(for crates: [SmartCrate]) -> Requirements {
        var requirements: Requirements = []
        for crate in crates {
            for rule in crate.rules {
                switch rule.field {
                case .fileExists:  requirements.insert(.fileExistence)
                case .isDuplicate: requirements.insert(.duplicates)
                default:           break
                }
            }
        }
        return requirements
    }

    // MARK: - Coverage

    /// Every track that would draw a cover: its own artwork, or its album's.
    /// Cheap, index-only, so it is always built rather than gated behind a
    /// requirement.
    public static func coveredTrackIDs(in index: LibraryIndex) -> Set<UUID> {
        var ids: Set<UUID> = []
        for artist in index.artists {
            for album in artist.albums {
                let albumCovered = album.artworkHash != nil
                for track in album.tracks where albumCovered || track.track.artworkHash != nil {
                    ids.insert(track.track.id)
                }
            }
        }
        return ids
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter RuleContextTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/RuleContext.swift Tests/CrateDiggerCoreTests/RuleContextTests.swift
git commit -m "$(cat <<'EOF'
feat(core): the rule evaluation context

Carries what a rule cannot read off a track: listening stats, which
tracks are covered by artwork, and the two expensive lookups. File
existence and duplicate membership are optional and are built only when
some rule reads them, once for the whole set of crates rather than once
per crate.

An uncomputed lookup is nil rather than empty, and a rule reading nil
does not match, so a duplicates crate awaiting its scan reads as pending
rather than as a clean library.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Evaluating text and choice fields

**Files:**
- Create: `Sources/CrateDiggerCore/Services/SmartCrateEvaluator.swift`
- Test: `Tests/CrateDiggerCoreTests/SmartCrateEvaluatorTests.swift`

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces: `SmartCrateEvaluator.matches(_:rule:context:) -> Bool`, plus the
  internal `text(_:of:)` extraction later tasks extend.

- [ ] **Step 1: Write the failing test**

Create `Tests/CrateDiggerCoreTests/SmartCrateEvaluatorTests.swift`:

```swift
#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// One rule against one track. The three cases worth care are a missing
/// value, an empty string, and a zero that must not read as absent.
final class SmartCrateEvaluatorTests: XCTestCase {

    // MARK: - Fixtures

    static func track(
        path: String = "/music/air/moon safari/01 la femme.flac",
        title: String = "La Femme d'Argent",
        artist: String = "Air",
        album: String = "Moon Safari",
        format: String? = "FLAC",
        albumArtist: String? = "Air",
        genre: String? = "Electronic",
        comment: String? = nil,
        year: Int? = 1998
    ) -> LoadedTrack {
        var metadata = ConversionMetadata()
        metadata.albumArtist = albumArtist
        metadata.genre = genre
        metadata.comment = comment
        metadata.year = year
        return LoadedTrack(
            track: AudioTrack(fileURL: URL(fileURLWithPath: path), title: title,
                              artist: artist, album: album, formatName: format, year: year),
            metadata: metadata
        )
    }

    private func matches(_ track: LoadedTrack, _ field: RuleField,
                         _ op: RuleOperator, _ value: RuleValue,
                         context: RuleContext = RuleContext()) -> Bool {
        SmartCrateEvaluator.matches(track, rule: SmartRule(field, op, value), context: context)
    }

    // MARK: - Text

    func testTextComparesCaseAndDiacriticInsensitively() {
        let track = Self.track()
        XCTAssertTrue(matches(track, .artist, .equals, .text("air")))
        XCTAssertTrue(matches(track, .title, .contains, .text("FEMME")))
        XCTAssertTrue(matches(track, .title, .contains, .text("d'argent")))
        XCTAssertFalse(matches(track, .artist, .equals, .text("Portishead")))
    }

    func testTextOperators() {
        let track = Self.track()
        XCTAssertTrue(matches(track, .album, .beginsWith, .text("Moon")))
        XCTAssertTrue(matches(track, .album, .endsWith, .text("Safari")))
        XCTAssertTrue(matches(track, .album, .doesNotContain, .text("Talkie")))
        XCTAssertTrue(matches(track, .artist, .notEquals, .text("Portishead")))
    }

    func testPathReadsTheWholeFilePath() {
        let track = Self.track()
        XCTAssertTrue(matches(track, .path, .contains, .text("moon safari")))
        XCTAssertTrue(matches(track, .path, .endsWith, .text(".flac")))
    }

    /// An absent tag and an empty tag are the same answer to "is empty", and
    /// neither may satisfy `contains`.
    func testEmptyTextIsEmptyWhetherAbsentOrBlank() {
        let noComment = Self.track(comment: nil)
        let blankComment = Self.track(comment: "   ")
        XCTAssertTrue(matches(noComment, .comment, .isEmpty, .blank))
        XCTAssertTrue(matches(blankComment, .comment, .isEmpty, .blank))
        XCTAssertFalse(matches(noComment, .comment, .isNotEmpty, .blank))
        XCTAssertFalse(matches(noComment, .comment, .contains, .text("rip")))
        XCTAssertTrue(matches(Self.track(), .title, .isNotEmpty, .blank))
    }

    /// Album artist falls back to the track artist, because most files never
    /// carry one and a rule that ignored the fallback would miss everything.
    func testAlbumArtistFallsBackToArtist() {
        let track = Self.track(albumArtist: nil)
        XCTAssertTrue(matches(track, .albumArtist, .equals, .text("Air")))
    }

    // MARK: - Choice

    func testFormatIsAChoiceComparedCaseInsensitively() {
        let track = Self.track(format: "FLAC")
        XCTAssertTrue(matches(track, .format, .equals, .text("flac")))
        XCTAssertTrue(matches(track, .format, .notEquals, .text("MP3")))
    }

    func testAFormatlessTrackMatchesNothing() {
        let track = Self.track(format: nil)
        XCTAssertFalse(matches(track, .format, .equals, .text("FLAC")))
        XCTAssertFalse(matches(track, .format, .notEquals, .text("FLAC")),
                       "a missing value is not evidence of difference")
    }

    /// A rule whose value is the wrong shape for its field is a corrupt file,
    /// not a crash.
    func testMismatchedValueTypeDoesNotMatch() {
        XCTAssertFalse(matches(Self.track(), .artist, .equals, .number(4)))
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter SmartCrateEvaluatorTests`
Expected: build failure, "cannot find 'SmartCrateEvaluator' in scope".

- [ ] **Step 3: Write the text and choice half of the evaluator**

Create `Sources/CrateDiggerCore/Services/SmartCrateEvaluator.swift`:

```swift
import Foundation

/// Decides which tracks a smart crate holds. Pure: everything it needs beyond
/// the track itself arrives in the `RuleContext`.
public enum SmartCrateEvaluator {

    /// One rule against one track.
    public static func matches(_ track: LoadedTrack, rule: SmartRule, context: RuleContext) -> Bool {
        switch rule.field.kind {
        case .text, .choice:
            return matchesText(text(rule.field, of: track), rule: rule, caseless: true)
        case .number, .date, .flag:
            return false   // Tasks 4 and 5.
        }
    }

    // MARK: - Text

    /// The field's value, or `nil` when the tag is absent or blank. Blank and
    /// absent are one answer: a tag of three spaces is not a title.
    static func text(_ field: RuleField, of track: LoadedTrack) -> String? {
        let raw: String?
        switch field {
        case .title:       raw = track.metadata.title ?? track.track.title
        case .artist:      raw = track.metadata.artist ?? track.track.artist
        case .albumArtist: raw = track.metadata.albumArtist ?? track.metadata.artist ?? track.track.artist
        case .album:       raw = track.metadata.album ?? track.track.album
        case .genre:       raw = track.metadata.genre
        case .comment:     raw = track.metadata.comment
        case .path:        raw = track.track.fileURL.path
        case .format:      raw = track.track.formatName
        default:           raw = nil
        }
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func matchesText(_ subject: String?, rule: SmartRule, caseless: Bool) -> Bool {
        switch rule.op {
        case .isEmpty:    return subject == nil
        case .isNotEmpty: return subject != nil
        default:          break
        }

        // A missing value is not evidence of difference: it satisfies neither
        // "is" nor "is not", the same way SQL treats NULL.
        guard let subject, case .text(let raw) = rule.value else { return false }
        let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }

        let options: String.CompareOptions = caseless ? [.caseInsensitive, .diacriticInsensitive] : []
        switch rule.op {
        case .equals:         return subject.compare(needle, options: options) == .orderedSame
        case .notEquals:      return subject.compare(needle, options: options) != .orderedSame
        case .contains:       return subject.range(of: needle, options: options) != nil
        case .doesNotContain: return subject.range(of: needle, options: options) == nil
        case .beginsWith:     return subject.range(of: needle, options: options.union(.anchored)) != nil
        case .endsWith:
            return subject.range(of: needle, options: options.union([.anchored, .backwards])) != nil
        default:              return false
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter SmartCrateEvaluatorTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/SmartCrateEvaluator.swift Tests/CrateDiggerCoreTests/SmartCrateEvaluatorTests.swift
git commit -m "$(cat <<'EOF'
feat(core): evaluate text and format rules

Case and diacritic insensitive, so a rule typed in lower case finds the
record. A blank tag and a missing tag are one answer, and a missing value
satisfies neither "is" nor "is not", the way SQL treats NULL. Album
artist falls back to the track artist, since most files carry no album
artist at all.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Evaluating number and date fields

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/SmartCrateEvaluator.swift`
- Test: `Tests/CrateDiggerCoreTests/SmartCrateEvaluatorTests.swift` (append)

**Interfaces:**
- Consumes: Task 3's `matches(_:rule:context:)`.
- Produces: `SmartCrateEvaluator.number(_:of:context:) -> Double?` and
  `SmartCrateEvaluator.date(_:of:context:) -> Date?`.

- [ ] **Step 1: Write the failing test**

Append inside `SmartCrateEvaluatorTests`, before the closing brace:

```swift
    // MARK: - Numbers

    private func stats(_ track: LoadedTrack,
                       playCount: Int = 0, skipCount: Int = 0,
                       lastPlayed: Date? = nil, dateAdded: Date = Date(timeIntervalSince1970: 0),
                       rating: Int = 0, now: Date = Date(timeIntervalSince1970: 1_000_000)) -> RuleContext {
        RuleContext(
            statsByPath: [ListeningStore.key(for: track.track.fileURL):
                ListeningStats(playCount: playCount, skipCount: skipCount,
                               lastPlayed: lastPlayed, dateAdded: dateAdded, rating: rating)],
            now: now
        )
    }

    func testNumberOperators() {
        let track = Self.track(year: 1998)
        XCTAssertTrue(matches(track, .year, .equals, .number(1998)))
        XCTAssertTrue(matches(track, .year, .isAtLeast, .number(1990)))
        XCTAssertTrue(matches(track, .year, .isAtMost, .number(1998)))
        XCTAssertFalse(matches(track, .year, .isAtLeast, .number(1999)))
        XCTAssertTrue(matches(track, .year, .notEquals, .number(1972)))
    }

    /// The rule the roadmap names first. A track with no year must not match
    /// `year is 0`, and must match `year is empty`.
    func testMissingYearIsEmptyNotZero() {
        let track = Self.track(year: nil)
        XCTAssertTrue(matches(track, .year, .isEmpty, .blank))
        XCTAssertFalse(matches(track, .year, .equals, .number(0)))
        XCTAssertFalse(matches(track, .year, .isAtMost, .number(2030)))
    }

    /// Rating stores unrated as zero, so this one field maps zero to absent.
    /// Nothing else does: a play count of zero is a real zero.
    func testUnratedIsEmptyButZeroPlaysIsZero() {
        let track = Self.track()
        let unrated = stats(track, playCount: 0, rating: 0)
        XCTAssertTrue(SmartCrateEvaluator.matches(track, rule: SmartRule(.rating, .isEmpty, .blank), context: unrated))
        XCTAssertFalse(SmartCrateEvaluator.matches(track, rule: SmartRule(.rating, .isAtLeast, .number(1)), context: unrated))

        XCTAssertFalse(SmartCrateEvaluator.matches(track, rule: SmartRule(.playCount, .isEmpty, .blank), context: unrated),
                       "zero plays is a count, not an absence")
        XCTAssertTrue(SmartCrateEvaluator.matches(track, rule: SmartRule(.playCount, .isAtMost, .number(0)), context: unrated))

        let rated = stats(track, rating: 4)
        XCTAssertTrue(SmartCrateEvaluator.matches(track, rule: SmartRule(.rating, .isAtLeast, .number(4)), context: rated))
    }

    /// A track the listening store has never heard of has no counts at all.
    func testATrackWithNoStatsHasNoListeningNumbers() {
        let track = Self.track()
        let empty = RuleContext()
        XCTAssertTrue(SmartCrateEvaluator.matches(track, rule: SmartRule(.playCount, .isEmpty, .blank), context: empty))
        XCTAssertFalse(SmartCrateEvaluator.matches(track, rule: SmartRule(.playCount, .isAtLeast, .number(1)), context: empty))
    }

    func testSpecsReadOffTheTrack() {
        let loaded = LoadedTrack(
            track: AudioTrack(fileURL: URL(fileURLWithPath: "/m/1.mp3"), title: "T",
                              durationSeconds: 245, formatName: "MP3",
                              bitrateKbps: 128, sampleRateHz: 44_100),
            metadata: ConversionMetadata()
        )
        XCTAssertTrue(matches(loaded, .bitrate, .isAtMost, .number(192)))
        XCTAssertTrue(matches(loaded, .sampleRate, .equals, .number(44_100)))
        XCTAssertTrue(matches(loaded, .duration, .isAtLeast, .number(240)))
    }

    // MARK: - Dates

    func testDateComparisons() {
        let track = Self.track()
        let played = Date(timeIntervalSince1970: 900_000)
        let context = stats(track, lastPlayed: played, now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertTrue(SmartCrateEvaluator.matches(track, rule: SmartRule(.lastPlayed, .isAfter, .date(Date(timeIntervalSince1970: 800_000))), context: context))
        XCTAssertTrue(SmartCrateEvaluator.matches(track, rule: SmartRule(.lastPlayed, .isBefore, .date(Date(timeIntervalSince1970: 950_000))), context: context))
    }

    /// "In the last N days" is measured against the injected clock, never
    /// against the wall clock, or this test would pass only today.
    func testInTheLastDaysUsesTheInjectedClock() {
        let track = Self.track()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let twoDaysAgo = now.addingTimeInterval(-2 * 86_400)
        let context = stats(track, lastPlayed: twoDaysAgo, now: now)

        XCTAssertTrue(SmartCrateEvaluator.matches(track, rule: SmartRule(.lastPlayed, .inLastDays, .days(7)), context: context))
        XCTAssertFalse(SmartCrateEvaluator.matches(track, rule: SmartRule(.lastPlayed, .inLastDays, .days(1)), context: context))
        XCTAssertTrue(SmartCrateEvaluator.matches(track, rule: SmartRule(.lastPlayed, .notInLastDays, .days(1)), context: context))
    }

    /// Never played is the roadmap's rule, and it is an absence.
    func testNeverPlayedIsAnEmptyLastPlayed() {
        let track = Self.track()
        let context = stats(track, playCount: 0, lastPlayed: nil)
        XCTAssertTrue(SmartCrateEvaluator.matches(track, rule: SmartRule(.lastPlayed, .isEmpty, .blank), context: context))
        XCTAssertFalse(SmartCrateEvaluator.matches(track, rule: SmartRule(.lastPlayed, .inLastDays, .days(3650)), context: context))
        XCTAssertFalse(SmartCrateEvaluator.matches(track, rule: SmartRule(.lastPlayed, .notInLastDays, .days(1)), context: context),
                       "never played is not the same as played long ago")
    }

    func testDateAddedComesFromTheListeningStore() {
        let track = Self.track()
        let added = Date(timeIntervalSince1970: 500_000)
        let context = stats(track, dateAdded: added, now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertTrue(SmartCrateEvaluator.matches(track, rule: SmartRule(.dateAdded, .isBefore, .date(Date(timeIntervalSince1970: 600_000))), context: context))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter SmartCrateEvaluatorTests`
Expected: the nine new tests FAIL (numbers and dates return `false` from the
Task 3 stub); the eight text tests still pass.

- [ ] **Step 3: Extend the evaluator**

In `SmartCrateEvaluator.swift`, replace the `matches(_:rule:context:)` switch:

```swift
    public static func matches(_ track: LoadedTrack, rule: SmartRule, context: RuleContext) -> Bool {
        switch rule.field.kind {
        case .text, .choice:
            return matchesText(text(rule.field, of: track), rule: rule, caseless: true)
        case .number:
            return matchesNumber(number(rule.field, of: track, context: context), rule: rule)
        case .date:
            return matchesDate(date(rule.field, of: track, context: context), rule: rule, now: context.now)
        case .flag:
            return false   // Task 5.
        }
    }
```

and append to the type:

```swift
    // MARK: - Numbers

    /// The field's value, or `nil` when it is genuinely absent.
    ///
    /// Only `rating` maps zero to absent, because `ListeningStats` stores
    /// unrated as zero and "unrated" is a different question from "rated
    /// zero". A play count of zero is a real count and stays one.
    static func number(_ field: RuleField, of track: LoadedTrack, context: RuleContext) -> Double? {
        switch field {
        case .year:        return (track.metadata.year ?? track.track.year).map(Double.init)
        case .bitrate:     return track.track.bitrateKbps.map(Double.init)
        case .sampleRate:  return track.track.sampleRateHz.map(Double.init)
        case .duration:    return track.track.durationSeconds > 0 ? track.track.durationSeconds : nil
        case .trackNumber: return (track.metadata.trackNumber ?? track.track.trackNumber).map(Double.init)
        case .playCount:   return stats(for: track, in: context).map { Double($0.playCount) }
        case .skipCount:   return stats(for: track, in: context).map { Double($0.skipCount) }
        case .rating:
            guard let rating = stats(for: track, in: context)?.rating, rating > 0 else { return nil }
            return Double(rating)
        default:           return nil
        }
    }

    private static func matchesNumber(_ subject: Double?, rule: SmartRule) -> Bool {
        if rule.op == .isEmpty { return subject == nil }
        guard let subject, case .number(let target) = rule.value else { return false }
        switch rule.op {
        case .equals:    return subject == target
        case .notEquals: return subject != target
        case .isAtLeast: return subject >= target
        case .isAtMost:  return subject <= target
        default:         return false
        }
    }

    // MARK: - Dates

    static func date(_ field: RuleField, of track: LoadedTrack, context: RuleContext) -> Date? {
        switch field {
        case .lastPlayed: return stats(for: track, in: context)?.lastPlayed
        case .dateAdded:  return stats(for: track, in: context)?.dateAdded
        default:          return nil
        }
    }

    private static func matchesDate(_ subject: Date?, rule: SmartRule, now: Date) -> Bool {
        if rule.op == .isEmpty { return subject == nil }
        guard let subject else { return false }
        switch (rule.op, rule.value) {
        case (.isBefore, .date(let target)): return subject < target
        case (.isAfter, .date(let target)):  return subject > target
        case (.inLastDays, .days(let days)):
            return subject >= now.addingTimeInterval(-Double(days) * 86_400)
        case (.notInLastDays, .days(let days)):
            return subject < now.addingTimeInterval(-Double(days) * 86_400)
        default: return false
        }
    }

    // MARK: - Stats lookup

    /// `nil` when the listening store has never seen this file, which is a
    /// different thing from a stored record of zero plays.
    private static func stats(for track: LoadedTrack, in context: RuleContext) -> ListeningStats? {
        context.statsByPath[ListeningStore.key(for: track.track.fileURL)]
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter SmartCrateEvaluatorTests`
Expected: PASS, 17 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/SmartCrateEvaluator.swift Tests/CrateDiggerCoreTests/SmartCrateEvaluatorTests.swift
git commit -m "$(cat <<'EOF'
feat(core): evaluate number and date rules

Absence is not zero. A track with no year does not match "year is 0", an
unrated track does not match "rating is at least 1", and never played is
an empty last-played rather than a very old one. Rating is the only field
that maps zero to absent, because the store spells unrated that way.

The clock is injected, so "in the last thirty days" is testable without
freezing time globally.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Flags, match modes, and members

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/SmartCrateEvaluator.swift`
- Test: `Tests/CrateDiggerCoreTests/SmartCrateEvaluatorTests.swift` (append)

**Interfaces:**
- Consumes: Tasks 1 to 4.
- Produces: `SmartCrateEvaluator.members(of:in:context:) -> [LoadedTrack]`.

- [ ] **Step 1: Write the failing test**

Append inside `SmartCrateEvaluatorTests`, before the closing brace:

```swift
    // MARK: - Flags

    func testArtworkFlagReadsTheContextsCoverage() {
        let track = Self.track()
        let covered = RuleContext(coveredTrackIDs: [track.track.id])
        XCTAssertTrue(SmartCrateEvaluator.matches(track, rule: SmartRule(.hasArtwork, .isTrue, .blank), context: covered))
        XCTAssertFalse(SmartCrateEvaluator.matches(track, rule: SmartRule(.hasArtwork, .isFalse, .blank), context: covered))

        let bare = RuleContext(coveredTrackIDs: [])
        XCTAssertTrue(SmartCrateEvaluator.matches(track, rule: SmartRule(.hasArtwork, .isFalse, .blank), context: bare))
    }

    func testFileExistenceReadsTheMissingSet() {
        let track = Self.track()
        let key = ListeningStore.key(for: track.track.fileURL)
        let scanned = RuleContext(missingPaths: [key])
        XCTAssertTrue(SmartCrateEvaluator.matches(track, rule: SmartRule(.fileExists, .isFalse, .blank), context: scanned))
        XCTAssertFalse(SmartCrateEvaluator.matches(track, rule: SmartRule(.fileExists, .isTrue, .blank), context: scanned))

        let present = RuleContext(missingPaths: [])
        XCTAssertTrue(SmartCrateEvaluator.matches(track, rule: SmartRule(.fileExists, .isTrue, .blank), context: present))
    }

    /// The property the whole two-tier design rests on: before the scan has
    /// run, the answer is "not yet", not "all clear".
    func testAnUncomputedLookupMatchesNothing() {
        let track = Self.track()
        let unscanned = RuleContext(missingPaths: nil, duplicatePaths: nil)
        XCTAssertFalse(SmartCrateEvaluator.matches(track, rule: SmartRule(.fileExists, .isFalse, .blank), context: unscanned))
        XCTAssertFalse(SmartCrateEvaluator.matches(track, rule: SmartRule(.fileExists, .isTrue, .blank), context: unscanned))
        XCTAssertFalse(SmartCrateEvaluator.matches(track, rule: SmartRule(.isDuplicate, .isTrue, .blank), context: unscanned))
    }

    func testDuplicateFlagReadsTheDuplicateSet() {
        let track = Self.track()
        let key = ListeningStore.key(for: track.track.fileURL)
        let context = RuleContext(duplicatePaths: [key])
        XCTAssertTrue(SmartCrateEvaluator.matches(track, rule: SmartRule(.isDuplicate, .isTrue, .blank), context: context))
        XCTAssertFalse(SmartCrateEvaluator.matches(track, rule: SmartRule(.isDuplicate, .isFalse, .blank), context: context))
    }

    // MARK: - Match modes

    private var library: [LoadedTrack] {
        [
            Self.track(path: "/m/1.flac", title: "One", artist: "Air", format: "FLAC", genre: "Electronic", year: 1998),
            Self.track(path: "/m/2.mp3", title: "Two", artist: "Air", format: "MP3", genre: "Electronic", year: 2004),
            Self.track(path: "/m/3.flac", title: "Three", artist: "Miles Davis", format: "FLAC", genre: "Jazz", year: 1959),
        ]
    }

    func testMatchAllRequiresEveryRule() {
        let crate = SmartCrate(name: "Old FLAC", match: .all, rules: [
            SmartRule(.format, .equals, .text("FLAC")),
            SmartRule(.year, .isAtMost, .number(1990)),
        ])
        let members = SmartCrateEvaluator.members(of: crate, in: library, context: RuleContext())
        XCTAssertEqual(members.map(\.track.title), ["Three"])
    }

    func testMatchAnyTakesTheUnion() {
        let crate = SmartCrate(name: "Jazz or MP3", match: .any, rules: [
            SmartRule(.genre, .equals, .text("Jazz")),
            SmartRule(.format, .equals, .text("MP3")),
        ])
        let members = SmartCrateEvaluator.members(of: crate, in: library, context: RuleContext())
        XCTAssertEqual(members.map(\.track.title), ["Two", "Three"])
    }

    /// A crate you have not finished writing holds nothing. A sidebar row that
    /// silently meant "your whole library" would be a worse answer.
    func testNoRulesMatchesNothing() {
        let crate = SmartCrate(name: "Unfinished", match: .all, rules: [])
        XCTAssertTrue(SmartCrateEvaluator.members(of: crate, in: library, context: RuleContext()).isEmpty)

        let anyCrate = SmartCrate(name: "Unfinished", match: .any, rules: [])
        XCTAssertTrue(SmartCrateEvaluator.members(of: anyCrate, in: library, context: RuleContext()).isEmpty)
    }

    func testMembersKeepTheInputOrder() {
        let crate = SmartCrate(name: "All FLAC", match: .all, rules: [
            SmartRule(.format, .equals, .text("FLAC")),
        ])
        let members = SmartCrateEvaluator.members(of: crate, in: library, context: RuleContext())
        XCTAssertEqual(members.map(\.track.title), ["One", "Three"])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter SmartCrateEvaluatorTests`
Expected: the eight new tests FAIL; `members` does not exist and flags return
`false`.

- [ ] **Step 3: Finish the evaluator**

Replace the `.flag` arm of `matches(_:rule:context:)`:

```swift
        case .flag:
            return matchesFlag(flag(rule.field, of: track, context: context), rule: rule)
```

and append to the type:

```swift
    // MARK: - Flags

    /// `nil` when the lookup behind this flag was never computed. See
    /// `RuleContext` for why that is not the same as `false`.
    static func flag(_ field: RuleField, of track: LoadedTrack, context: RuleContext) -> Bool? {
        switch field {
        case .hasArtwork:
            return context.coveredTrackIDs.contains(track.track.id)
        case .fileExists:
            guard let missing = context.missingPaths else { return nil }
            return !missing.contains(ListeningStore.key(for: track.track.fileURL))
        case .isDuplicate:
            guard let duplicates = context.duplicatePaths else { return nil }
            return duplicates.contains(ListeningStore.key(for: track.track.fileURL))
        default:
            return nil
        }
    }

    private static func matchesFlag(_ subject: Bool?, rule: SmartRule) -> Bool {
        guard let subject else { return false }
        switch rule.op {
        case .isTrue:  return subject
        case .isFalse: return !subject
        default:       return false
        }
    }

    // MARK: - Members

    /// The tracks this crate holds, in the order they arrived. A crate does
    /// not sort; the browser's own sort does that.
    public static func members(of crate: SmartCrate,
                               in tracks: [LoadedTrack],
                               context: RuleContext) -> [LoadedTrack] {
        // An unfinished crate holds nothing, under either match mode.
        guard !crate.rules.isEmpty else { return [] }
        return tracks.filter { track in
            switch crate.match {
            case .all: return crate.rules.allSatisfy { matches(track, rule: $0, context: context) }
            case .any: return crate.rules.contains { matches(track, rule: $0, context: context) }
            }
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter SmartCrateEvaluatorTests`
Expected: PASS, 25 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/SmartCrateEvaluator.swift Tests/CrateDiggerCoreTests/SmartCrateEvaluatorTests.swift
git commit -m "$(cat <<'EOF'
feat(core): flags, match modes, and a crate's members

A flag whose lookup was never computed matches neither true nor false, so
a duplicates crate awaiting its scan reads as pending rather than clean.
An empty rule list holds nothing under either match mode, and members
keep the order they arrived in, leaving sorting to the browser.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Storage

**Files:**
- Create: `Sources/CrateDiggerCore/Services/SmartCrateStore.swift`
- Test: `Tests/CrateDiggerCoreTests/SmartCrateStoreTests.swift`

**Interfaces:**
- Consumes: `SmartCrate` (Task 1).
- Produces: `SmartCrateStore(directory:)`, `.all()`, `.load(name:)`,
  `.save(_:)`, `.delete(name:)`, `.url(for:)`,
  `SmartCrateStore.fileExtension` (`"cdsmart"`).

- [ ] **Step 1: Write the failing test**

Create `Tests/CrateDiggerCoreTests/SmartCrateStoreTests.swift`:

```swift
#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// Smart crates live beside the membership lists in the crates index folder,
/// one small JSON file each.
final class SmartCrateStoreTests: XCTestCase {
    private var directory: URL!
    private var store: SmartCrateStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartCrateStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SmartCrateStore(directory: directory)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private func crate(_ name: String) -> SmartCrate {
        SmartCrate(name: name, match: .all, rules: [SmartRule(.genre, .equals, .text("Jazz"))])
    }

    func testSaveAndLoadRoundTrip() throws {
        try store.save(crate("Jazz"))
        XCTAssertEqual(store.load(name: "Jazz"), crate("Jazz"))
        XCTAssertEqual(store.url(for: "Jazz").lastPathComponent, "Jazz.cdsmart")
    }

    func testAllListsAlphabeticallyAndIgnoresOtherFiles() throws {
        try store.save(crate("Zulu"))
        try store.save(crate("alpha"))
        try Data("[]".utf8).write(to: directory.appendingPathComponent("Ordinary.cdcrate"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("library.cdtracks"))

        XCTAssertEqual(store.all().map(\.name), ["alpha", "Zulu"])
    }

    /// The file's name is the crate's name, so a rename is a move rather than
    /// a second copy. A save under a new name leaves no orphan behind only
    /// because the caller deletes the old one; this pins the primitive.
    func testDeleteRemovesTheFileAndIsSafeWhenMissing() throws {
        try store.save(crate("Jazz"))
        try store.delete(name: "Jazz")
        XCTAssertNil(store.load(name: "Jazz"))
        XCTAssertNoThrow(try store.delete(name: "Jazz"))
    }

    /// A corrupt or hand-broken file is skipped, not fatal: one bad crate
    /// must not cost the user the other nine.
    func testACorruptFileIsSkipped() throws {
        try store.save(crate("Good"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("Broken.cdsmart"))
        XCTAssertEqual(store.all().map(\.name), ["Good"])
        XCTAssertNil(store.load(name: "Broken"))
    }

    /// The file is meant to be read and shared, so it is pretty-printed with
    /// sorted keys, the same contract an authored theme gets.
    func testTheFileIsHumanReadable() throws {
        try store.save(crate("Jazz"))
        let text = try String(contentsOf: store.url(for: "Jazz"), encoding: .utf8)
        XCTAssertTrue(text.contains("\n"), "not pretty-printed")
        XCTAssertTrue(text.contains("\"match\""))
        XCTAssertLessThan(text.firstRange(of: "\"match\"")!.lowerBound,
                          text.firstRange(of: "\"name\"")!.lowerBound,
                          "keys are not sorted")
    }

    func testMissingDirectoryIsCreatedOnSave() throws {
        let nested = directory.appendingPathComponent("Deeper", isDirectory: true)
        let nestedStore = SmartCrateStore(directory: nested)
        try nestedStore.save(crate("Jazz"))
        XCTAssertEqual(nestedStore.load(name: "Jazz")?.name, "Jazz")
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter SmartCrateStoreTests`
Expected: build failure, "cannot find 'SmartCrateStore' in scope".

- [ ] **Step 3: Write the store**

Create `Sources/CrateDiggerCore/Services/SmartCrateStore.swift`:

```swift
import Foundation

/// Smart crates on disk: one `<name>.cdsmart` file per crate, in the crates
/// index folder beside the `.cdcrate` membership lists, so they are covered by
/// the same backup and the same sync.
///
/// The file carries rules and nothing else. No track data means it is small,
/// it diffs, and it means something on someone else's library, which a
/// membership list does not.
public struct SmartCrateStore: Sendable {
    public static let fileExtension = "cdsmart"

    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public func url(for name: String) -> URL {
        directory.appendingPathComponent(name).appendingPathExtension(Self.fileExtension)
    }

    /// Every readable crate, by name, case insensitively ordered. A file that
    /// does not parse is skipped: one hand-broken crate must not cost the user
    /// the rest of them.
    public func all() -> [SmartCrate] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { $0.pathExtension.lowercased() == Self.fileExtension }
            .compactMap { decode(at: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func load(name: String) -> SmartCrate? {
        decode(at: url(for: name))
    }

    /// Keys sorted and the JSON pretty-printed, so the file stays hand-editable
    /// and diffs cleanly. Same contract an authored theme gets.
    public func save(_ crate: SmartCrate) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(crate).write(to: url(for: crate.name), options: .atomic)
    }

    /// Safe when there is nothing there: deleting a crate twice is a normal
    /// consequence of an undo and a retry.
    public func delete(name: String) throws {
        let target = url(for: name)
        guard fileManager.fileExists(atPath: target.path) else { return }
        try fileManager.removeItem(at: target)
    }

    private func decode(at url: URL) -> SmartCrate? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SmartCrate.self, from: data)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter SmartCrateStoreTests`
Expected: PASS, 6 tests.

If `testTheFileIsHumanReadable` fails on the `firstRange(of:)` call under the
project's Swift version, replace those two assertions with
`XCTAssertTrue(text.contains("\"match\""))` and a check that the string index
of `"match"` precedes `"name"` using `range(of:)`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/SmartCrateStore.swift Tests/CrateDiggerCoreTests/SmartCrateStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(core): smart crates on disk

One .cdsmart file per crate in the crates index folder, beside the
membership lists, pretty-printed with sorted keys so it stays readable.
A file that does not parse is skipped rather than fatal, and deleting a
crate that is already gone is not an error.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: A smart crate is a source

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift`
  (the `LibrarySource` enum near the top, `persistenceKey`, `isLocalLibrary`,
  and `selectSource(_:)`)
- Create: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+SmartCrates.swift`
- Test: `Tests/CrateDiggerAppTests/SmartCrateSourceTests.swift`

**Interfaces:**
- Consumes: `SmartCrate`, `SmartCrateStore`, `SmartCrateEvaluator`,
  `RuleContext` (Tasks 1 to 6).
- Produces: `LibrarySource.smartCrate(name:)`,
  `LibraryViewModel.smartCrates: [SmartCrate]`,
  `LibraryViewModel.smartCrateCounts: [String: Int]`,
  `LibraryViewModel.smartCrateStore`,
  `LibraryViewModel.refreshSmartCrates()`,
  `LibraryViewModel.saveSmartCrate(_:replacing:)`,
  `LibraryViewModel.deleteSmartCrate(name:)`,
  `LibraryViewModel.smartCrateTracks(name:) -> [LoadedTrack]`,
  `LibraryViewModel.ruleContext(for:) -> RuleContext`.

- [ ] **Step 1: Write the failing test**

Create `Tests/CrateDiggerAppTests/SmartCrateSourceTests.swift`:

```swift
import CrateDiggerCore
import XCTest
@testable import CrateDiggerApp

/// A smart crate has to be a source like any other: it belongs to the local
/// library, it keeps a live search when you move into it, and it remembers
/// its own browser view.
final class SmartCrateSourceTests: XCTestCase {

    func testASmartCrateIsPartOfTheLocalLibrary() {
        let source = LibrarySource.smartCrate(name: "Jazz")
        XCTAssertTrue(source.isLocalLibrary)
        XCTAssertTrue(source.keepsSearch(movingTo: .localAll))
        XCTAssertTrue(LibrarySource.localCrate(name: "Rock").keepsSearch(movingTo: source))
        XCTAssertFalse(source.keepsSearch(movingTo: .radio(category: nil)))
    }

    /// The key is what a saved browser view is filed under, so it has to be
    /// stable and it must not collide with an ordinary crate of the same name.
    func testPersistenceKeyIsDistinctFromAnOrdinaryCrate() {
        XCTAssertEqual(LibrarySource.smartCrate(name: "Jazz").persistenceKey, "smart:Jazz")
        XCTAssertNotEqual(LibrarySource.smartCrate(name: "Jazz").persistenceKey,
                          LibrarySource.localCrate(name: "Jazz").persistenceKey)
    }

    func testTwoSmartCratesAreDistinguishedByName() {
        XCTAssertNotEqual(LibrarySource.smartCrate(name: "A"), LibrarySource.smartCrate(name: "B"))
        XCTAssertEqual(LibrarySource.smartCrate(name: "A"), LibrarySource.smartCrate(name: "A"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter SmartCrateSourceTests`
Expected: build failure, "type 'LibrarySource' has no member 'smartCrate'".

- [ ] **Step 3: Add the source case**

In `LibraryViewModel.swift`, in the `LibrarySource` enum, after
`case localCrate(name: String)`:

```swift
    /// A crate defined by rules rather than by a list of paths. Same folder,
    /// same sidebar section, same everything downstream: by the time anything
    /// past `selectSource` sees it, it is a list of tracks.
    case smartCrate(name: String)
```

In `isLocalLibrary`, extend the case list:

```swift
        case .localAll, .localCrate, .smartCrate, .prepCrate: return true
```

In `persistenceKey`, before the `prepCrate` line:

```swift
        case .smartCrate(let name):        return "smart:\(name)"
```

In `selectSource(_:)`, after the `.localCrate` arm:

```swift
        case .smartCrate(let name):
            localIndex = buildIndex(smartCrateTracks(name: name))
            index = localIndex
```

- [ ] **Step 4: Write the view model extension**

Create `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+SmartCrates.swift`:

```swift
import CrateDiggerCore
import Foundation

/// Smart crates: loading them, evaluating them, and keeping the sidebar's
/// counts honest.
///
/// The counts come in two tiers. A crate whose rules only touch tags, specs
/// and listening data is recomputed with the index and its count is always
/// live. A crate reading file existence or duplicate membership cannot be,
/// without stat-ing the whole library on every keystroke, so it keeps its last
/// known count until the background pass lands. `nil` is a count that has
/// never been computed, and the sidebar draws it as a dash: zero is an answer,
/// and this is not one.
@MainActor
extension LibraryViewModel {

    var smartCrateStore: SmartCrateStore {
        SmartCrateStore(directory: cratesDirectoryURL)
    }

    /// Re-reads the folder and recomputes every cheap count. Call after any
    /// change to the crates folder, alongside `refreshCrateCounts()`.
    func refreshSmartCrates() {
        smartCrates = smartCrateStore.all()
        recomputeSmartCrateCounts()
    }

    /// Saves, replacing a differently-named original so a rename moves the
    /// file rather than leaving two.
    func saveSmartCrate(_ crate: SmartCrate, replacing previousName: String? = nil) {
        do {
            if let previousName, previousName != crate.name {
                try smartCrateStore.delete(name: previousName)
            }
            try smartCrateStore.save(crate)
            refreshSmartCrates()
            if case .smartCrate(let current) = currentSource,
               current == previousName || current == crate.name {
                selectSource(.smartCrate(name: crate.name))
            }
        } catch {
            appAlert = .error(title: "Couldn't Save Crate",
                              message: "The rules could not be written. \(error.localizedDescription)")
        }
    }

    /// Deletes the file and nothing else. A smart crate owns no paths, so
    /// there is no track data to orphan.
    func deleteSmartCrate(name: String) {
        try? smartCrateStore.delete(name: name)
        if case .smartCrate(let current) = currentSource, current == name {
            selectSource(.localAll)
        }
        refreshSmartCrates()
    }

    /// The tracks a crate holds right now, evaluated over the whole local
    /// library the way All Records is built.
    func smartCrateTracks(name: String) -> [LoadedTrack] {
        guard let crate = smartCrates.first(where: { $0.name == name }) else { return [] }
        let library = allLocalTracks()
        return SmartCrateEvaluator.members(of: crate, in: library,
                                           context: ruleContext(for: [crate]))
    }

    /// Every track in every crate, deduplicated, which is what All Records
    /// browses and therefore what a rule reads.
    func allLocalTracks() -> [LoadedTrack] {
        var all: [LoadedTrack] = []
        for name in availableCrates {
            all.append(contentsOf: loadCrateTracks(name: name))
        }
        return LibraryViewModel.deduplicatedForSmartCrates(all)
    }

    static func deduplicatedForSmartCrates(_ tracks: [LoadedTrack]) -> [LoadedTrack] {
        var seen = Set<String>()
        var result: [LoadedTrack] = []
        result.reserveCapacity(tracks.count)
        for track in tracks where seen.insert(track.track.fileURL.standardizedFileURL.path).inserted {
            result.append(track)
        }
        return result
    }

    /// The context these crates need, and only that. The two expensive
    /// lookups are handed over from the last background pass; a crate that
    /// wants one before the pass has run evaluates to nothing, which the
    /// sidebar shows as a dash rather than a zero.
    func ruleContext(for crates: [SmartCrate]) -> RuleContext {
        let requirements = RuleContext.requirements(for: crates)
        return RuleContext(
            statsByPath: listeningStore?.allStats ?? [:],
            coveredTrackIDs: RuleContext.coveredTrackIDs(in: localIndex),
            missingPaths: requirements.contains(.fileExistence) ? scannedMissingPaths : nil,
            duplicatePaths: requirements.contains(.duplicates) ? scannedDuplicatePaths : nil,
            now: Date()
        )
    }

    /// Cheap crates recompute now; deferred ones keep whatever the last scan
    /// gave them.
    func recomputeSmartCrateCounts() {
        guard !smartCrates.isEmpty else { smartCrateCounts = [:]; return }
        let library = allLocalTracks()
        var counts = smartCrateCounts
        for crate in smartCrates {
            let requirements = RuleContext.requirements(for: [crate])
            let deferred = !requirements.isEmpty
            let haveScan = (!requirements.contains(.fileExistence) || scannedMissingPaths != nil)
                && (!requirements.contains(.duplicates) || scannedDuplicatePaths != nil)
            guard !deferred || haveScan else { continue }   // keep the last known count
            counts[crate.name] = SmartCrateEvaluator.members(
                of: crate, in: library, context: ruleContext(for: [crate])
            ).count
        }
        // Drop counts for crates that no longer exist.
        let live = Set(smartCrates.map(\.name))
        smartCrateCounts = counts.filter { live.contains($0.key) }
    }
}
```

- [ ] **Step 5: Add the stored properties**

In `LibraryViewModel.swift`, beside `@Published private(set) var crateTrackCounts`:

```swift
    // Written by LibraryViewModel+SmartCrates. Deliberately not `private(set)`:
    // Swift confines a `private(set)` write to the declaring file, and the
    // extension that maintains these lives in its own.
    @Published var smartCrates: [SmartCrate] = []
    /// A name missing from this map has never been counted, which the sidebar
    /// draws as a dash. Zero means the crate is genuinely empty.
    @Published var smartCrateCounts: [String: Int] = [:]
    /// The last file-existence pass, `nil` until one has run. Filled by part
    /// two's health scan; until then, every crate reading it stays uncounted.
    var scannedMissingPaths: Set<String>?
    /// The last duplicate pass, `nil` until one has run.
    var scannedDuplicatePaths: Set<String>?
```

- [ ] **Step 6: Add the listening-store accessor**

`ListeningStore` exposes `ratingsByPath` but not the whole record. Add this
beside it in `Sources/CrateDiggerCore/Services/ListeningStore.swift`:

```swift
    /// Every record, for callers that need more than one field. The rule
    /// evaluator reads play count, skips, last played and date added, so
    /// going through `ratingsByPath` and three siblings would be four passes
    /// over the same dictionary.
    public var allStats: [String: ListeningStats] { byPath }
```

- [ ] **Step 7: Run the tests**

Run: `scripts/test.sh --filter SmartCrateSourceTests`
Expected: PASS, 3 tests.

Run: `swift build`
Expected: `Build complete!`. If the compiler reports a non-exhaustive switch
over `LibrarySource`, add a `.smartCrate` arm at each site it names; every one
should behave the way its `.localCrate` neighbour does.

- [ ] **Step 8: Run the whole suite**

Run: `scripts/test.sh`
Expected: 0 failures.

- [ ] **Step 9: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift \
        Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+SmartCrates.swift \
        Sources/CrateDiggerCore/Services/ListeningStore.swift \
        Tests/CrateDiggerAppTests/SmartCrateSourceTests.swift
git commit -m "$(cat <<'EOF'
feat(crates): a smart crate is a source like any other

Its own LibrarySource case, part of the local library, so a live search
carries into it and it remembers its own browser view. Everything
downstream sees a list of tracks, so convert, transfer and queue work
unchanged.

Counts come in two tiers: crates reading only tags, specs and listening
data recompute with the index, and crates reading file existence or
duplicates keep their last known count until the background pass lands.
A count that has never been computed is absent rather than zero.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: The sidebar rows

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Main/SourcesSidebar.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift`
  (call `refreshSmartCrates()` wherever `refreshCrateCounts()` is called)

**Interfaces:**
- Consumes: Task 7's `smartCrates`, `smartCrateCounts`, `deleteSmartCrate`.
- Produces: `SourcesSidebar.smartCrateLabel(_:)`, and the
  `editingSmartCrate` binding Task 9 presents its sheet from.

- [ ] **Step 1: Add the row builder**

In `SourcesSidebar.swift`, beside `crateLabel(_:)`:

```swift
    /// A smart crate row. Same section and same shape as an ordinary crate;
    /// the filled bolt is the only tell that it fills itself.
    @ViewBuilder
    private func smartCrateLabel(_ crate: SmartCrate) -> some View {
        let count = model.smartCrateCounts[crate.name]
        sidebarItem(
            icon: Image(systemName: "bolt.square"),
            title: crate.name,
            // A dash, not a zero: this crate has never been counted, which is
            // a different thing from a crate that is genuinely empty.
            count: count.map(String.init) ?? "—",
            selected: isSelectedSmartCrate(crate.name),
            action: { model.selectSource(.smartCrate(name: crate.name)) }
        )
        .contextMenu {
            Button("Edit Rules…") { editingSmartCrate = crate }
            Button("Duplicate") {
                var copy = crate
                copy.name = model.uniqueSmartCrateName(basedOn: crate.name)
                model.saveSmartCrate(copy)
            }
            Divider()
            Button("Delete", role: .destructive) { model.deleteSmartCrate(name: crate.name) }
        }
    }

    private func isSelectedSmartCrate(_ name: String) -> Bool {
        if case .smartCrate(let current) = model.currentSource { return current == name }
        return false
    }
```

Add the state beside the other `@State` properties at the top of the view:

```swift
    @State private var editingSmartCrate: SmartCrate?
```

- [ ] **Step 2: List them in the crates section**

In the crates section, immediately after the `ForEach` that draws
`model.availableCrates`, add:

```swift
                        ForEach(model.smartCrates) { crate in
                            smartCrateLabel(crate)
                        }
```

- [ ] **Step 3: Add the create affordance**

In the crates section header's trailing control, beside the existing add
button that sets `showingCrateSheet`, add a second button:

```swift
                        Button {
                            editingSmartCrate = SmartCrate(name: model.uniqueSmartCrateName(basedOn: "Smart Crate"))
                        } label: {
                            Image(systemName: "bolt.badge.plus")
                        }
                        .buttonStyle(.carbonHover)
                        .carbonTip("New smart crate: a crate that fills itself from rules")
```

- [ ] **Step 4: Add the name helper**

In `LibraryViewModel+SmartCrates.swift`:

```swift
    /// "Smart Crate", then "Smart Crate 2", and so on. The name is the file
    /// name and the row, so two crates cannot share one.
    func uniqueSmartCrateName(basedOn base: String) -> String {
        let taken = Set(smartCrates.map(\.name))
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }
```

- [ ] **Step 5: Refresh where crates refresh**

Find every call to `refreshCrateCounts()` in `LibraryViewModel.swift` and add
`refreshSmartCrates()` beside it. Also call `recomputeSmartCrateCounts()` at
the end of `recomputeSortedCollections()`, so a rescan updates the counts.

- [ ] **Step 6: Build and run the app**

Run: `swift build && .build/arm64-apple-macosx/debug/CrateDiggerApp`

Confirm by eye: the crates section shows a bolt button in its header; pressing
it opens nothing yet (Task 9 supplies the sheet); no smart crates are listed
because none exist.

Then create one by hand and confirm it appears:

The crates folder is chosen by the user and stored as a security-scoped
bookmark, so read it off the app rather than guessing: **Settings, then the
crates index folder**, or find it with
`find ~ -name "library.cdtracks" -maxdepth 6 2>/dev/null`.

```bash
CRATES="<the folder holding library.cdtracks>"
cat > "$CRATES/Lossless.cdsmart" <<'JSON'
{
  "match" : "all",
  "name" : "Lossless",
  "rules" : [ { "field" : "format", "op" : "is", "value" : { "text" : "FLAC" } } ]
}
JSON
```

Relaunch. The row appears with a live count, and clicking it browses only FLAC.

- [ ] **Step 7: Run the whole suite**

Run: `scripts/test.sh`
Expected: 0 failures.

- [ ] **Step 8: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Main/SourcesSidebar.swift \
        Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift \
        Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+SmartCrates.swift
git commit -m "$(cat <<'EOF'
feat(crates): smart crates in the sidebar

Same section as your other crates, same order, same row. A filled bolt is
the only tell that this one fills itself, and a count that has never been
computed draws as a dash rather than a zero.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: The rule editor

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/Sheets/SmartCrateEditor.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Main/SourcesSidebar.swift`
  (present the sheet)

**Interfaces:**
- Consumes: everything above.
- Produces: `SmartCrateEditor(crate:existing:onDismiss:)`.

- [ ] **Step 1: Write the editor**

Create `Sources/CrateDiggerApp/UI/Carbon/Sheets/SmartCrateEditor.swift`:

```swift
import CrateDiggerCore
import SwiftUI

/// Writes a smart crate's rules. The live count at the foot is the point: a
/// rule set you cannot see the effect of is one you have to save to test.
struct SmartCrateEditor: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    /// The name the crate had when the sheet opened, so a rename moves the
    /// file rather than leaving the original behind.
    let originalName: String?
    @State private var draft: SmartCrate
    let onDismiss: () -> Void

    init(crate: SmartCrate, existing: Bool, onDismiss: @escaping () -> Void) {
        self.originalName = existing ? crate.name : nil
        self._draft = State(initialValue: crate)
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().overlay(theme.hair)
            matchRow
            rulesList
            Spacer(minLength: 0)
            Divider().overlay(theme.hair)
            footer
        }
        .padding(16)
        .frame(width: 560, height: 420)
        .background(theme.chassis)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(theme.keyLamp).frame(width: 7, height: 7)
            Text("SMART CRATE")
                .font(CarbonFont.mono(11, weight: .bold))
                .tracking(2)
                .foregroundStyle(theme.ink2)
            Spacer(minLength: 8)
            TextField("Crate name", text: $draft.name)
                .textFieldStyle(.plain)
                .font(CarbonFont.sans(13, weight: .semibold))
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(width: 240)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.paper))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.hair))
        }
    }

    private var matchRow: some View {
        HStack(spacing: 8) {
            Text("MATCH")
                .font(CarbonFont.mono(8.5, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(theme.ink4)
            ForEach(MatchMode.allCases, id: \.rawValue) { mode in
                KeyButton(style: draft.match == mode ? .selected : .normal,
                          action: { draft.match = mode }) {
                    Text(mode.title)
                }
                .frame(width: 54, height: 20)
            }
            Text("of the following rules")
                .font(CarbonFont.mono(9))
                .foregroundStyle(theme.ink4)
            Spacer(minLength: 0)
        }
    }

    private var rulesList: some View {
        ScrollView(.vertical) {
            VStack(spacing: 6) {
                ForEach(Array(draft.rules.enumerated()), id: \.offset) { index, _ in
                    ruleRow(index)
                }
                HStack {
                    KeyButton(action: addRule) { Text("+ RULE") }
                        .frame(width: 78, height: 20)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func ruleRow(_ index: Int) -> some View {
        let rule = draft.rules[index]
        return HStack(spacing: 6) {
            menuField(rule.field.title, width: 130) {
                ForEach(RuleField.allCases, id: \.rawValue) { field in
                    Button(field.title) { setField(field, at: index) }
                }
            }
            menuField(rule.op.title, width: 130) {
                ForEach(rule.field.kind.operators, id: \.rawValue) { op in
                    Button(op.title) { setOperator(op, at: index) }
                }
            }
            if rule.op.needsValue {
                valueField(index)
            } else {
                Spacer(minLength: 0)
            }
            Button(action: { draft.rules.remove(at: index) }) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.ink4)
            }
            .buttonStyle(.carbonHover)
        }
    }

    @ViewBuilder
    private func valueField(_ index: Int) -> some View {
        let rule = draft.rules[index]
        switch rule.field.kind {
        case .date where rule.op == .inLastDays || rule.op == .notInLastDays:
            HStack(spacing: 4) {
                TextField("30", text: valueText(index))
                    .textFieldStyle(.plain)
                    .frame(width: 50)
                Text("days").font(CarbonFont.mono(9)).foregroundStyle(theme.ink4)
                Spacer(minLength: 0)
            }
        default:
            TextField(placeholder(for: rule.field), text: valueText(index))
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity)
        }
    }

    private func placeholder(for field: RuleField) -> String {
        switch field.kind {
        case .number: return "0"
        case .date:   return "2024-01-01"
        default:      return "value"
        }
    }

    /// One text binding for every value shape, parsed on write. A field the
    /// user has half-typed keeps its text rather than snapping back to zero,
    /// which is why the raw string is held per row.
    @State private var rawValues: [Int: String] = [:]

    private func valueText(_ index: Int) -> Binding<String> {
        Binding(
            get: { rawValues[index] ?? Self.display(draft.rules[index].value) },
            set: { text in
                rawValues[index] = text
                draft.rules[index].value = Self.parse(text, for: draft.rules[index])
            }
        )
    }

    static func display(_ value: RuleValue) -> String {
        switch value {
        case .blank:         return ""
        case .text(let v):   return v
        case .number(let v): return v == v.rounded() ? String(Int(v)) : String(v)
        case .days(let v):   return String(v)
        case .date(let v):   return ISO8601DateFormatter.dayOnly.string(from: v)
        }
    }

    static func parse(_ text: String, for rule: SmartRule) -> RuleValue {
        switch rule.field.kind {
        case .number:
            return .number(Double(text) ?? 0)
        case .date:
            if rule.op == .inLastDays || rule.op == .notInLastDays {
                return .days(Int(text) ?? 0)
            }
            return .date(ISO8601DateFormatter.dayOnly.date(from: text) ?? Date())
        default:
            return .text(text)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(matchSummary)
                .font(CarbonFont.mono(9, weight: .bold))
                .foregroundStyle(theme.ink3)
            Spacer(minLength: 8)
            KeyButton(action: onDismiss) { Text("CANCEL") }
                .frame(width: 74, height: 22)
            KeyButton(style: canSave ? .glowingFilled : .disabled, action: save) { Text("SAVE") }
                .frame(width: 74, height: 22)
        }
    }

    /// Recomputed as you edit rather than on save. At library size this is a
    /// filter over an array already in memory.
    private var matchSummary: String {
        guard !draft.rules.isEmpty else { return "NO RULES YET" }
        let count = SmartCrateEvaluator.members(
            of: draft, in: model.allLocalTracks(), context: model.ruleContext(for: [draft])
        ).count
        return count == 1 ? "1 RECORD" : "\(count) RECORDS"
    }

    private var canSave: Bool {
        let trimmed = draft.name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let clash = model.smartCrates.contains { $0.name == trimmed && $0.name != originalName }
        return !clash
    }

    // MARK: - Edits

    private func addRule() {
        draft.rules.append(SmartRule(.genre, .equals, .text("")))
    }

    /// Changing the field can strand the operator, so it falls back to the
    /// new kind's first, and the value is re-shaped to match.
    private func setField(_ field: RuleField, at index: Int) {
        var rule = draft.rules[index]
        rule.field = field
        if !field.kind.operators.contains(rule.op) {
            rule.op = field.kind.operators[0]
        }
        rule.value = rule.op.needsValue ? Self.parse("", for: rule) : .blank
        rawValues[index] = nil
        draft.rules[index] = rule
    }

    private func setOperator(_ op: RuleOperator, at index: Int) {
        var rule = draft.rules[index]
        rule.op = op
        rule.value = op.needsValue ? Self.parse(rawValues[index] ?? "", for: rule) : .blank
        draft.rules[index] = rule
    }

    private func save() {
        var crate = draft
        crate.name = crate.name.trimmingCharacters(in: .whitespaces)
        model.saveSmartCrate(crate, replacing: originalName)
        onDismiss()
    }

    @ViewBuilder
    private func menuField<Content: View>(_ label: String, width: CGFloat,
                                          @ViewBuilder content: () -> Content) -> some View {
        Menu { content() } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(CarbonFont.mono(9))
                    .foregroundStyle(theme.ink2)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(theme.ink4)
            }
            .padding(.horizontal, 7)
            .frame(width: width, height: 22)
            .background(KeyChrome())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
}

extension ISO8601DateFormatter {
    /// Dates in a rule are days, not instants: nobody writes a smart crate
    /// about a Tuesday afternoon.
    static let dayOnly: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()
}
```

- [ ] **Step 2: Present it**

In `SourcesSidebar.swift`, on the outermost `VStack` of `body`:

```swift
        .sheet(item: $editingSmartCrate) { crate in
            SmartCrateEditor(
                crate: crate,
                existing: model.smartCrates.contains { $0.name == crate.name },
                onDismiss: { editingSmartCrate = nil }
            )
            .environmentObject(model)
        }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`.

If the compiler objects that `SmartCrate` is not `Identifiable` for
`sheet(item:)`, it already is via `id: String { name }` from Task 1. If it
objects that `Binding<SmartCrate?>` needs `Equatable`, it has that too.

- [ ] **Step 4: Drive it in the app**

Run: `swift build && .build/arm64-apple-macosx/debug/CrateDiggerApp`

Check by hand, in this order:

1. The bolt button in the crates header opens the editor with an empty crate.
2. Adding a rule of Format is FLAC shows a live record count at the foot.
3. Switching MATCH between ALL and ANY changes the count with two rules set.
4. Changing a rule's field from Genre to Rating swaps the operator menu to the
   number set and clears the stale value rather than keeping "Jazz".
5. Choosing "is empty" hides the value field.
6. SAVE is disabled while the name is blank or clashes with an existing crate.
7. Saving lists the crate in the sidebar with a matching count; clicking it
   browses exactly those records.
8. Edit Rules on the row reopens the sheet with the rules in it; renaming and
   saving moves the row rather than producing a second one.
9. Delete removes the row and the file.

- [ ] **Step 5: Run the whole suite**

Run: `scripts/test.sh`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Sheets/SmartCrateEditor.swift \
        Sources/CrateDiggerApp/UI/Carbon/Main/SourcesSidebar.swift
git commit -m "$(cat <<'EOF'
feat(crates): the smart crate rule editor

A match toggle, a list of rule rows, and a live count of what matches at
the foot. The count recomputes as you edit rather than on save, because a
rule set you cannot see the effect of is one you have to save to test.

Changing a rule's field re-shapes its operator and value rather than
leaving a number rule holding the word Jazz.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Documentation

**Files:**
- Modify: `CLAUDE.md` (the Sources model section)
- Modify: `CHANGELOG.md` (the 2.0.0 section's Added list)

- [ ] **Step 1: Document the source**

In `CLAUDE.md`, in "Sources model", add to the `LibrarySource` case list
`smartCrate(name:)`, and add a bullet after the Crates bullet:

```markdown
- **Smart crates** are the same idea with a rule set instead of a membership
  list: a `<name>.cdsmart` JSON file in the same crates folder, evaluated by
  `SmartCrateEvaluator` over every crate's tracks. Rules always match *tracks*;
  a count that reads better as albums is counted by the caller. Two fields,
  `fileExists` and `isDuplicate`, cannot be evaluated from memory, so
  `RuleContext.requirements(for:)` decides whether to build those lookups at
  all and the sidebar shows a **dash, not a zero**, for a crate that has never
  been counted. Adding a rule field is one case in `RuleField` plus one line in
  its `kind`; the editor's menus read the same table.
```

- [ ] **Step 2: Add the changelog entry**

At the top of the `### Added` list in the `## 2.0.0` section:

```markdown
- **Crates that fill themselves.** A smart crate is a rule set rather than a
  list of songs, and it sits in the same sidebar as your other crates. Match
  all or any of a list of rules over anything CrateDigger knows: format,
  bitrate, year, genre, album artist, rating, play count, when you last played
  it, when you added it, whether it has a cover, whether the file is still
  there. The editor shows a live count as you type, so you can see what a rule
  catches before you save it. It stays current on its own.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md CHANGELOG.md
git commit -m "$(cat <<'EOF'
docs: smart crates

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Done when

- `scripts/test.sh` reports 0 failures, with roughly 45 new tests across
  `SmartCrateModelTests`, `RuleContextTests`, `SmartCrateEvaluatorTests`,
  `SmartCrateStoreTests` and `SmartCrateSourceTests`.
- A smart crate created in the editor appears in the sidebar, browses the right
  records, and survives a relaunch.
- Its count is live for rules over tags, specs and listening data.
- A crate whose rules read file existence or duplicates shows a dash until a
  scan has run, and never shows a misleading zero.
- Converting, transferring and queueing from a smart crate behave exactly as
  they do from an ordinary one.

## What part two adds

Part two (spec Part C) is the HEALTH screen: a new `OLEDView` case and lamp
token, a panel of five built-in `SmartCrate` values, OPEN / KEEP / FIX on each
row, the background scan that fills `scannedMissingPaths` and
`scannedDuplicatePaths`, and the retirement of `LibraryCleanupView`. It needs
nothing from this plan beyond what Task 7 already exposes.
