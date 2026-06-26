# Album Version Groups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user keep multiple format/edition versions of one album as distinct, grouped "release" entries that sort by an original release year and are never treated as duplicates.

**Architecture:** A new Core `AlbumGroup` model + `AlbumGroupStore` (JSON in `PreferencesStore`, non-destructive) records which scanned albums are versions of one release, keyed by the existing `AlbumFolderKey`. `LibraryIndex.build` folds grouped albums into a synthesised parent "release" `Album` that carries the member pressings in a new `versions` field. The browser renders the release as an expandable row (Option B); a confirm sheet captures the canonical original year. The duplicate-finder is made version-aware.

**Tech Stack:** Swift 5.9, Swift Package Manager, AppKit + SwiftUI (macOS 13+), XCTest.

## Global Constraints

- macOS 13+, Swift tools 5.9. Two targets: `CrateDiggerCore` (pure, unit-tested) and `CrateDiggerApp` (AppKit/SwiftUI). Keep testable logic in Core.
- Run tests with `scripts/test.sh` (never bare `swift test`). One class: `scripts/test.sh --filter <Class>`. One method: `scripts/test.sh --filter <Class>/<method>`.
- Build with `swift build`. App binary: `.build/arm64-apple-macosx/debug/CrateDiggerApp`.
- **Non-destructive:** never retag or move the user's audio files. Grouping is overlay-only.
- **Local albums only** in v1 (no Remote/CD/Playlist/Radio grouping); single artist per group.
- Album grouping is **manual** — no automatic detection.
- Version identity is the existing `AlbumFolderKey` (artist/title/year), made `Codable`. (The spec's "VersionRef" collapses to `AlbumFolderKey` directly — one fewer type, same behavior.)
- A release needs **≥ 2 live member pressings**; otherwise it dissolves to plain albums.
- Effective sort year of an album = `originalYear ?? year`.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Before Task 1:** branch off `main` — `git checkout -b feat/album-version-groups`. (The working tree also has prior uncommitted selection/menu work and the spec doc; commit or stash those first so feature commits stay clean.)

---

## File Structure

Core (new): `Models/AlbumGroup.swift`, `Services/AlbumGroupStore.swift`, `Services/VersionLabel.swift`.
Core (modified): `Services/OutputPathPlanner.swift` (`AlbumFolderKey: Codable`), `Models/Album.swift` (additive fields), `Services/LibraryIndex.swift` (folding + sort + lookup), `Services/LibraryCleanupService.swift` (version-aware dupes), `Services/PreferencesStore.swift` (`albumGroupsData`).
App (new): `UI/Carbon/Library/LibraryViewModel+Versions.swift`, `UI/Carbon/Sheets/GroupAlbumsSheetController.swift`.
App (modified): `UI/Carbon/Library/LibraryViewModel.swift` (build rewire, `selectedAlbum`), `UI/Carbon/Main/Browser/BrowserPane.swift` (release rendering), `UI/Carbon/Main/Browser/BrowserContextMenu.swift` (menu items).
Tests (new): `AlbumGroupTests`, `AlbumGroupStoreTests`, `VersionLabelTests`. Tests (extended): `LibraryIndexTests`, `LibraryCleanupServiceTests`.

---

## Task 1: `AlbumGroup` model + `AlbumFolderKey: Codable`

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/OutputPathPlanner.swift:90`
- Create: `Sources/CrateDiggerCore/Models/AlbumGroup.swift`
- Test: `Tests/CrateDiggerCoreTests/AlbumGroupTests.swift`

**Interfaces:**
- Produces: `AlbumFolderKey: Codable`; `struct VersionMember { var key: AlbumFolderKey; var editionLabel: String? }`; `struct AlbumGroup: Codable, Sendable, Hashable, Identifiable { var id, name, artistID: String; var originalYear: Int?; var primaryKey: AlbumFolderKey; var members: [VersionMember] }`.

- [ ] **Step 1: Write the failing test**

Create `Tests/CrateDiggerCoreTests/AlbumGroupTests.swift`:

```swift
#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class AlbumGroupTests: XCTestCase {
    func testAlbumGroupCodableRoundTrip() throws {
        let key = AlbumFolderKey(artistBucket: "Daft Punk", album: "Discovery", year: "2001")
        let jp = AlbumFolderKey(artistBucket: "Daft Punk", album: "Discovery (JP)", year: "2001")
        let group = AlbumGroup(
            id: "g1", name: "Discovery", artistID: "daft punk", originalYear: 1999,
            primaryKey: key,
            members: [VersionMember(key: key, editionLabel: "US FLAC"),
                      VersionMember(key: jp, editionLabel: "JP FLAC")]
        )
        let data = try JSONEncoder().encode(group)
        let back = try JSONDecoder().decode(AlbumGroup.self, from: data)
        XCTAssertEqual(back, group)
        XCTAssertEqual(back.members.count, 2)
        XCTAssertEqual(back.primaryKey, key)
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter AlbumGroupTests`
Expected: FAIL — `AlbumGroup` and `VersionMember` are undefined (compile error).

- [ ] **Step 3: Make `AlbumFolderKey` Codable**

In `Sources/CrateDiggerCore/Services/OutputPathPlanner.swift:90`, add `Codable` to the conformance:

```swift
public struct AlbumFolderKey: Hashable, Sendable, Codable {
```

(All three stored properties are `String`, so `Codable` is synthesized.)

- [ ] **Step 4: Create the model**

Create `Sources/CrateDiggerCore/Models/AlbumGroup.swift`:

```swift
import Foundation

/// One member pressing of a release: a pointer to a scanned album (by its
/// `AlbumFolderKey`) plus the user's editable edition label ("Gold CD", "JP Vinyl").
public struct VersionMember: Codable, Sendable, Hashable {
    public var key: AlbumFolderKey
    public var editionLabel: String?

    public init(key: AlbumFolderKey, editionLabel: String? = nil) {
        self.key = key
        self.editionLabel = editionLabel
    }
}

/// A user-defined grouping of several pressings of the same release (e.g. CD,
/// Vinyl, FLAC, Remaster). Persisted by `AlbumGroupStore`; folded into the browser
/// by `LibraryIndex.build`. Identity of each member is the existing `AlbumFolderKey`,
/// so grouping is a non-destructive overlay on the scanned library.
public struct AlbumGroup: Codable, Sendable, Hashable, Identifiable {
    /// Stable id (UUID string) generated at creation.
    public var id: String
    /// Display title of the release ("Wish You Were Here").
    public var name: String
    /// Owning artist (groups never span artists in v1).
    public var artistID: String
    /// Canonical original release year — drives sorting, regardless of pressing years.
    public var originalYear: Int?
    /// Which member is cover + default playback (matches one member's `key`).
    public var primaryKey: AlbumFolderKey
    /// The pressings, in display order.
    public var members: [VersionMember]

    public init(id: String, name: String, artistID: String, originalYear: Int?,
                primaryKey: AlbumFolderKey, members: [VersionMember]) {
        self.id = id
        self.name = name
        self.artistID = artistID
        self.originalYear = originalYear
        self.primaryKey = primaryKey
        self.members = members
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `scripts/test.sh --filter AlbumGroupTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/CrateDiggerCore/Models/AlbumGroup.swift Sources/CrateDiggerCore/Services/OutputPathPlanner.swift Tests/CrateDiggerCoreTests/AlbumGroupTests.swift
git commit -m "feat(core): AlbumGroup model + Codable AlbumFolderKey

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `AlbumGroupStore` persistence

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/PreferencesStore.swift` (`Key` enum ~line 53; new computed var near line 423)
- Create: `Sources/CrateDiggerCore/Services/AlbumGroupStore.swift`
- Test: `Tests/CrateDiggerCoreTests/AlbumGroupStoreTests.swift`

**Interfaces:**
- Consumes: `AlbumGroup` (Task 1); `PreferencesStore(defaults:)` init.
- Produces: `PreferencesStore.albumGroupsData: Data?`; `AlbumGroupStore` with `init(prefs:)`, `all() -> [AlbumGroup]`, `save(_:)`, `@discardableResult upsert(_:) -> [AlbumGroup]`, `@discardableResult remove(id:) -> [AlbumGroup]`.

- [ ] **Step 1: Write the failing test**

Create `Tests/CrateDiggerCoreTests/AlbumGroupStoreTests.swift`:

```swift
#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class AlbumGroupStoreTests: XCTestCase {
    private func freshStore() -> AlbumGroupStore {
        let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        return AlbumGroupStore(prefs: PreferencesStore(defaults: d))
    }

    private func make(_ id: String) -> AlbumGroup {
        let k = AlbumFolderKey(artistBucket: "A", album: "Rec \(id)", year: "2001")
        return AlbumGroup(id: id, name: "Rec", artistID: "a", originalYear: 1999,
                          primaryKey: k, members: [VersionMember(key: k)])
    }

    func testEmptyByDefault() {
        XCTAssertTrue(freshStore().all().isEmpty)
    }

    func testSaveAndLoadRoundTrip() {
        let s = freshStore()
        s.save([make("g1"), make("g2")])
        XCTAssertEqual(s.all().map(\.id), ["g1", "g2"])
    }

    func testUpsertReplacesById() {
        let s = freshStore()
        s.upsert(make("g1"))
        var g = make("g1"); g.name = "Renamed"
        s.upsert(g)
        XCTAssertEqual(s.all().count, 1)
        XCTAssertEqual(s.all().first?.name, "Renamed")
    }

    func testRemove() {
        let s = freshStore()
        s.save([make("g1"), make("g2")])
        s.remove(id: "g1")
        XCTAssertEqual(s.all().map(\.id), ["g2"])
    }

    func testSavingEmptyClearsStorage() {
        let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let prefs = PreferencesStore(defaults: d)
        AlbumGroupStore(prefs: prefs).save([make("g1")])
        AlbumGroupStore(prefs: prefs).save([])
        XCTAssertNil(prefs.albumGroupsData)
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter AlbumGroupStoreTests`
Expected: FAIL — `AlbumGroupStore` / `albumGroupsData` undefined.

- [ ] **Step 3: Add the PreferencesStore key + data accessor**

In `Sources/CrateDiggerCore/Services/PreferencesStore.swift`, inside the `private enum Key` block (near the `streamSources` key, ~line 53) add:

```swift
        static let albumGroups = "cratedigger.library.albumGroups"
```

Then add a computed var (place it right after the `streamSourcesData` var, ~line 423):

```swift
    /// Raw JSON of `[AlbumGroup]`. `AlbumGroupStore` owns (de)serialization.
    public var albumGroupsData: Data? {
        get { defaults.data(forKey: Key.albumGroups) }
        set {
            if let data = newValue {
                defaults.set(data, forKey: Key.albumGroups)
            } else {
                defaults.removeObject(forKey: Key.albumGroups)
            }
        }
    }
```

- [ ] **Step 4: Create the store**

Create `Sources/CrateDiggerCore/Services/AlbumGroupStore.swift`:

```swift
import Foundation

/// Persistence for the user's album version groups. Stores the list as a small
/// JSON blob in `PreferencesStore` (app-global config, like `StreamStore` — not a
/// per-folder `.cdlib`). Corrupt or missing data reads as an empty list. The user's
/// audio files are never touched; a group is purely an overlay.
public final class AlbumGroupStore {
    private let prefs: PreferencesStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(prefs: PreferencesStore = .shared) {
        self.prefs = prefs
    }

    public func all() -> [AlbumGroup] {
        guard let data = prefs.albumGroupsData else { return [] }
        return (try? decoder.decode([AlbumGroup].self, from: data)) ?? []
    }

    public func save(_ groups: [AlbumGroup]) {
        if groups.isEmpty {
            prefs.albumGroupsData = nil
        } else {
            prefs.albumGroupsData = try? encoder.encode(groups)
        }
    }

    /// Insert or replace a group by id; returns the new list.
    @discardableResult
    public func upsert(_ group: AlbumGroup) -> [AlbumGroup] {
        var list = all()
        if let i = list.firstIndex(where: { $0.id == group.id }) {
            list[i] = group
        } else {
            list.append(group)
        }
        save(list)
        return list
    }

    @discardableResult
    public func remove(id: String) -> [AlbumGroup] {
        let list = all().filter { $0.id != id }
        save(list)
        return list
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `scripts/test.sh --filter AlbumGroupStoreTests`
Expected: PASS (all 5 methods).

- [ ] **Step 6: Commit**

```bash
git add Sources/CrateDiggerCore/Services/AlbumGroupStore.swift Sources/CrateDiggerCore/Services/PreferencesStore.swift Tests/CrateDiggerCoreTests/AlbumGroupStoreTests.swift
git commit -m "feat(core): AlbumGroupStore JSON persistence

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `Album` additive fields + `with(editionLabel:)`

**Files:**
- Modify: `Sources/CrateDiggerCore/Models/Album.swift`
- Test: `Tests/CrateDiggerCoreTests/AlbumGroupTests.swift` (add a method)

**Interfaces:**
- Produces: `Album` gains `versions: [Album]?`, `originalYear: Int?`, `editionLabel: String?`, computed `isVersionGroup: Bool`, and `func with(editionLabel: String?) -> Album`. New init params are optional with defaults (existing call sites unaffected).

- [ ] **Step 1: Write the failing test**

Append to `Tests/CrateDiggerCoreTests/AlbumGroupTests.swift` (inside the class):

```swift
    func testAlbumVersionFieldsAndWithEdition() {
        let plain = Album(id: "a", artistID: "x", artistName: "X", title: "T",
                          year: 2001, artworkHash: nil, tracks: [])
        XCTAssertFalse(plain.isVersionGroup)
        XCTAssertNil(plain.editionLabel)

        let labeled = plain.with(editionLabel: "JP Vinyl")
        XCTAssertEqual(labeled.editionLabel, "JP Vinyl")
        XCTAssertEqual(labeled.id, "a")

        let release = Album(id: "g", artistID: "x", artistName: "X", title: "T",
                            year: 2001, artworkHash: nil, tracks: [],
                            versions: [plain], originalYear: 1975)
        XCTAssertTrue(release.isVersionGroup)
        XCTAssertEqual(release.originalYear, 1975)
        XCTAssertEqual(release.versions?.count, 1)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter AlbumGroupTests/testAlbumVersionFieldsAndWithEdition`
Expected: FAIL — `versions` / `originalYear` / `editionLabel` / `isVersionGroup` / `with` undefined.

- [ ] **Step 3: Add fields, init params, and helpers**

In `Sources/CrateDiggerCore/Models/Album.swift`, add the three stored properties after `mediaFormat` (line 12):

```swift
    public let mediaFormat: MediaFormat?
    /// Non-nil when this `Album` is a grouped *release*: its member pressings.
    public let versions: [Album]?
    /// Canonical original release year for a grouped release (drives sorting).
    public let originalYear: Int?
    /// Edition label for a *member* pressing ("Gold CD"); nil otherwise.
    public let editionLabel: String?
```

Extend the initializer signature (append the three params with defaults so existing callers keep compiling) and assign them:

```swift
    public init(
        id: String,
        artistID: String,
        artistName: String,
        title: String,
        year: Int?,
        artworkHash: String?,
        tracks: [LoadedTrack],
        booklet: AlbumBooklet? = nil,
        mediaFormat: MediaFormat? = nil,
        versions: [Album]? = nil,
        originalYear: Int? = nil,
        editionLabel: String? = nil
    ) {
        self.id = id
        self.artistID = artistID
        self.artistName = artistName
        self.title = title
        self.year = year
        self.artworkHash = artworkHash
        self.tracks = tracks
        self.booklet = booklet
        self.mediaFormat = mediaFormat
        self.versions = versions
        self.originalYear = originalYear
        self.editionLabel = editionLabel
    }
```

Add computed property + copy helper after `isMultiDisc` (anywhere in the struct body, e.g. after line 53):

```swift
    /// True when this album is a grouped release holding member pressings.
    public var isVersionGroup: Bool { versions != nil }

    /// A copy of this album carrying the given edition label (used when folding a
    /// pressing into a release's `versions`).
    public func with(editionLabel: String?) -> Album {
        Album(id: id, artistID: artistID, artistName: artistName, title: title,
              year: year, artworkHash: artworkHash, tracks: tracks, booklet: booklet,
              mediaFormat: mediaFormat, versions: versions, originalYear: originalYear,
              editionLabel: editionLabel)
    }
```

- [ ] **Step 4: Run test + full Core suite to verify no call sites broke**

Run: `scripts/test.sh --filter AlbumGroupTests`
Expected: PASS.
Run: `swift build`
Expected: Build succeeds (additive optional params don't break existing `Album(...)` calls).

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Models/Album.swift Tests/CrateDiggerCoreTests/AlbumGroupTests.swift
git commit -m "feat(core): Album version-group fields + with(editionLabel:)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: `VersionLabel.formatBadge`

**Files:**
- Create: `Sources/CrateDiggerCore/Services/VersionLabel.swift`
- Test: `Tests/CrateDiggerCoreTests/VersionLabelTests.swift`

**Interfaces:**
- Consumes: `Album`, `AudioTrack` (`formatName`, `sampleRateHz`, `bitrateKbps`), `MediaFormat`.
- Produces: `enum VersionLabel { static func formatBadge(for album: Album) -> String }`.

- [ ] **Step 1: Write the failing test**

Create `Tests/CrateDiggerCoreTests/VersionLabelTests.swift`:

```swift
#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class VersionLabelTests: XCTestCase {
    private func album(format: String?, bitrate: Int?, sampleRate: Int?,
                       media: MediaFormat? = nil) -> Album {
        let t = AudioTrack(fileURL: URL(fileURLWithPath: "/tmp/x.\(format ?? "bin")"),
                           title: "S", artist: "A", album: "R",
                           formatName: format, bitrateKbps: bitrate, sampleRateHz: sampleRate)
        return Album(id: "a", artistID: "a", artistName: "A", title: "R", year: 2001,
                     artworkHash: nil, tracks: [LoadedTrack(track: t, metadata: ConversionMetadata())],
                     mediaFormat: media)
    }

    func testLosslessShowsSampleRate() {
        XCTAssertEqual(VersionLabel.formatBadge(for: album(format: "flac", bitrate: 900, sampleRate: 96000)),
                       "FLAC · 96 kHz")
    }

    func testLosslessNoSampleRate() {
        XCTAssertEqual(VersionLabel.formatBadge(for: album(format: "alac", bitrate: nil, sampleRate: nil)),
                       "ALAC")
    }

    func testLossyShowsBitrate() {
        XCTAssertEqual(VersionLabel.formatBadge(for: album(format: "mp3", bitrate: 320, sampleRate: 44100)),
                       "MP3 · 320")
    }

    func testMediaFormatSuffix() {
        XCTAssertEqual(VersionLabel.formatBadge(for: album(format: "flac", bitrate: nil, sampleRate: 44100, media: .vinyl)),
                       "FLAC · 44 kHz · Vinyl")
    }

    func testUnknownFormat() {
        XCTAssertEqual(VersionLabel.formatBadge(for: album(format: nil, bitrate: nil, sampleRate: nil)),
                       "—")
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter VersionLabelTests`
Expected: FAIL — `VersionLabel` undefined.

- [ ] **Step 3: Implement**

Create `Sources/CrateDiggerCore/Services/VersionLabel.swift`:

```swift
import Foundation

/// Derives the auto-generated format/quality badge shown on a version sub-row
/// (e.g. "FLAC · 96 kHz", "MP3 · 320", "ALAC · CD"). The user's editable edition
/// label ("Gold CD", "JP Vinyl") is stored separately on `VersionMember`.
public enum VersionLabel {
    private static let lossless: Set<String> = ["flac", "alac", "wav", "aiff", "pcm", "ape"]

    public static func formatBadge(for album: Album) -> String {
        let track = album.tracks.first?.track
        guard let rawFormat = track?.formatName, !rawFormat.isEmpty else { return "—" }

        let codec = rawFormat.uppercased()
        let isLossless = lossless.contains(rawFormat.lowercased())

        var parts: [String] = [codec]
        if isLossless {
            if let hz = track?.sampleRateHz, hz > 0 {
                parts.append("\(Int((Double(hz) / 1000).rounded())) kHz")
            }
        } else if let kbps = track?.bitrateKbps, kbps > 0 {
            parts.append("\(kbps)")
        }
        if let media = album.mediaFormat {
            parts.append(media.rawValue)
        }
        return parts.joined(separator: " · ")
    }
}
```

(`MediaFormat.rawValue` is "CD"/"Vinyl"/"Digital".)

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter VersionLabelTests`
Expected: PASS (all 5).

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/VersionLabel.swift Tests/CrateDiggerCoreTests/VersionLabelTests.swift
git commit -m "feat(core): VersionLabel.formatBadge derivation

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: `LibraryIndex` folding + effective-year sort + `albumOrVersion`

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/LibraryIndex.swift` (`build`, `sortedAlbums` year comparator, add `albumOrVersion`)
- Test: `Tests/CrateDiggerCoreTests/LibraryIndexTests.swift` (add methods)

**Interfaces:**
- Consumes: `AlbumGroup` (Task 1), `Album.with(editionLabel:)` / `isVersionGroup` (Task 3), `AlbumFolderKey` (Task 1).
- Produces: `LibraryIndex.build(from loaded: [LoadedTrack], groups: [AlbumGroup] = []) -> LibraryIndex` (new defaulted second param — existing `build(from:)` calls keep working with no folding); `LibraryIndex.albumOrVersion(id: String) -> Album?`. Grouped releases appear in `artists[].albums` (and thus `allAlbums`); `allTracks` is unchanged.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/CrateDiggerCoreTests/LibraryIndexTests.swift` (inside the class). Add this helper first (top of class):

```swift
    private func loaded(album: String, format: String, title: String = "One More Time",
                        artist: String = "Daft Punk", year: Int = 2001) -> LoadedTrack {
        let url = URL(fileURLWithPath: "/tmp/\(album)/\(title).\(format)")
        let t = AudioTrack(fileURL: url, title: title, artist: artist, album: album,
                           formatName: format, bitrateKbps: 900, sampleRateHz: 44100, year: year)
        return LoadedTrack(track: t, metadata: ConversionMetadata())
    }
```

Then the tests:

```swift
    func testFoldsGroupedVersionsIntoOneRelease() {
        let planner = OutputPathPlanner()
        let us = loaded(album: "Discovery", format: "flac")
        let jp = loaded(album: "Discovery (JP)", format: "flac")
        let kUS = planner.albumFolderKey(for: us)
        let kJP = planner.albumFolderKey(for: jp)
        let group = AlbumGroup(id: "g1", name: "Discovery", artistID: "daft punk",
                               originalYear: 1999, primaryKey: kUS,
                               members: [VersionMember(key: kUS, editionLabel: "US"),
                                         VersionMember(key: kJP, editionLabel: "JP")])
        let index = LibraryIndex.build(from: [us, jp], groups: [group])

        let albums = index.allAlbums
        XCTAssertEqual(albums.count, 1)
        let release = albums[0]
        XCTAssertTrue(release.isVersionGroup)
        XCTAssertEqual(release.title, "Discovery")
        XCTAssertEqual(release.originalYear, 1999)
        XCTAssertEqual(release.versions?.count, 2)
        XCTAssertEqual(release.versions?.compactMap(\.editionLabel).sorted(), ["JP", "US"])
        XCTAssertEqual(index.allTracks.count, 2)
    }

    func testDissolvesGroupWithFewerThanTwoLiveMembers() {
        let planner = OutputPathPlanner()
        let us = loaded(album: "Discovery", format: "flac")
        let kUS = planner.albumFolderKey(for: us)
        let ghost = AlbumFolderKey(artistBucket: "Daft Punk", album: "Gone", year: "2001")
        let group = AlbumGroup(id: "g1", name: "Discovery", artistID: "daft punk",
                               originalYear: 1999, primaryKey: kUS,
                               members: [VersionMember(key: kUS), VersionMember(key: ghost)])
        let index = LibraryIndex.build(from: [us], groups: [group])
        XCTAssertEqual(index.allAlbums.count, 1)
        XCTAssertFalse(index.allAlbums[0].isVersionGroup)
    }

    func testReleaseSortsByOriginalYear() {
        let planner = OutputPathPlanner()
        let newer = loaded(album: "Random Access Memories", format: "flac", title: "Giorgio", year: 2013)
        let cd = loaded(album: "Discovery", format: "flac", year: 2001)
        let vinyl = loaded(album: "Discovery (Vinyl)", format: "flac", year: 2016)
        let kCD = planner.albumFolderKey(for: cd)
        let kVinyl = planner.albumFolderKey(for: vinyl)
        let group = AlbumGroup(id: "g1", name: "Discovery", artistID: "daft punk",
                               originalYear: 1999, primaryKey: kCD,
                               members: [VersionMember(key: kCD), VersionMember(key: kVinyl)])
        let index = LibraryIndex.build(from: [newer, cd, vinyl], groups: [group])
        let titles = index.artists[0].albums.map(\.title)
        // Release (originalYear 1999) sorts before RAM (2013).
        XCTAssertEqual(titles, ["Discovery", "Random Access Memories"])
    }

    func testAlbumOrVersionFindsPressing() {
        let planner = OutputPathPlanner()
        let us = loaded(album: "Discovery", format: "flac")
        let jp = loaded(album: "Discovery (JP)", format: "flac")
        let kUS = planner.albumFolderKey(for: us)
        let kJP = planner.albumFolderKey(for: jp)
        let group = AlbumGroup(id: "g1", name: "Discovery", artistID: "daft punk",
                               originalYear: 1999, primaryKey: kUS,
                               members: [VersionMember(key: kUS), VersionMember(key: kJP)])
        let index = LibraryIndex.build(from: [us, jp], groups: [group])
        let release = index.allAlbums[0]
        let pressing = release.versions![0]
        XCTAssertEqual(index.albumOrVersion(id: release.id)?.id, release.id)
        XCTAssertEqual(index.albumOrVersion(id: pressing.id)?.id, pressing.id)
        XCTAssertNil(index.albumOrVersion(id: "nope"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh --filter LibraryIndexTests`
Expected: FAIL — `build(from:groups:)` and `albumOrVersion` undefined.

- [ ] **Step 3: Add the `groups` param + folding post-pass**

In `Sources/CrateDiggerCore/Services/LibraryIndex.swift`, change the `build` signature (line ~81) and, while building albums, capture an `albumByKey` map. Replace the signature line and the album-construction loop's bookkeeping:

```swift
    public static func build(from loaded: [LoadedTrack],
                             groups: [AlbumGroup] = []) -> LibraryIndex {
        guard !loaded.isEmpty else { return .empty }

        let planner = OutputPathPlanner()

        var groupsByKey: [AlbumFolderKey: [LoadedTrack]] = [:]
        var insertionOrder: [AlbumFolderKey] = []
        for track in loaded {
            let key = planner.albumFolderKey(for: track)
            if groupsByKey[key] == nil { insertionOrder.append(key) }
            groupsByKey[key, default: []].append(track)
        }

        var albumsByArtistID: [String: [Album]] = [:]
        var artistDisplayName: [String: String] = [:]
        var albumByKey: [AlbumFolderKey: Album] = [:]
```

Then, in the existing `for key in insertionOrder` loop, after the `let album = Album(...)` is constructed and before/after `albumsByArtistID[artistID, default: []].append(album)`, record it by key:

```swift
            albumByKey[key] = album
            albumsByArtistID[artistID, default: []].append(album)
```

(Rename the existing local `groups` dictionary to `groupsByKey` as shown so it doesn't clash with the new `groups` parameter — update the two references to it inside the loop accordingly.)

After the album loop and before building `artists`, insert the folding pass:

```swift
        // Fold user-defined version groups: replace member pressings with one
        // synthesised "release" album that carries them in `versions`.
        if !groups.isEmpty {
            var consumed = Set<String>()
            var releasesByArtist: [String: [Album]] = [:]
            for group in groups {
                let liveMembers: [Album] = group.members.compactMap { member in
                    albumByKey[member.key]?.with(editionLabel: member.editionLabel)
                }
                guard liveMembers.count >= 2 else { continue }
                let primary = albumByKey[group.primaryKey] ?? albumByKey[group.members.first!.key]
                guard let primary else { continue }
                for member in group.members {
                    if let a = albumByKey[member.key] { consumed.insert(a.id) }
                }
                let release = Album(
                    id: "group::\(group.id)",
                    artistID: primary.artistID,
                    artistName: primary.artistName,
                    title: group.name,
                    year: primary.year,
                    artworkHash: primary.artworkHash,
                    tracks: primary.tracks,
                    booklet: primary.booklet,
                    mediaFormat: primary.mediaFormat,
                    versions: liveMembers,
                    originalYear: group.originalYear
                )
                releasesByArtist[primary.artistID, default: []].append(release)
            }
            for (artistID, releases) in releasesByArtist {
                var kept = (albumsByArtistID[artistID] ?? []).filter { !consumed.contains($0.id) }
                kept.append(contentsOf: releases)
                albumsByArtistID[artistID] = kept
            }
        }
```

- [ ] **Step 4: Use the effective year in sorting**

Find `sortedAlbums(_:by:ascending:)` (line ~229). In its `.year` comparator, compare `originalYear ?? year` instead of `year` on both sides. Locate the year-field branch and replace each `album.year` read used for the year comparison with `(album.originalYear ?? album.year)`. For example, if the comparator reads:

```swift
        case .year:
            return { lhs, rhs in
                // ... existing nil-last logic using lhs.year / rhs.year ...
            }
```

change the two values it compares to `let l = lhs.originalYear ?? lhs.year` and `let r = rhs.originalYear ?? rhs.year`, keeping the existing nil-last + tiebreak logic otherwise. (`sortAlbums`, used inside `build`, calls this with `.year`, so releases get placed by original year automatically.)

- [ ] **Step 5: Add `albumOrVersion(id:)`**

Next to the existing `func album(id:)` (line ~316), add:

```swift
    /// Find a top-level album by id, or a member pressing nested inside a grouped
    /// release. Used so selecting a version sub-row resolves to that pressing.
    public func albumOrVersion(id: String) -> Album? {
        for artist in artists {
            for album in artist.albums {
                if album.id == id { return album }
                if let v = album.versions?.first(where: { $0.id == id }) { return v }
            }
        }
        return nil
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `scripts/test.sh --filter LibraryIndexTests`
Expected: PASS (existing + 4 new). Also run the full suite to confirm nothing regressed:
Run: `scripts/test.sh`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/CrateDiggerCore/Services/LibraryIndex.swift Tests/CrateDiggerCoreTests/LibraryIndexTests.swift
git commit -m "feat(core): fold album version groups in LibraryIndex + original-year sort

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Version-aware `findDuplicates`

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/LibraryCleanupService.swift` (`findDuplicates`)
- Test: `Tests/CrateDiggerCoreTests/LibraryCleanupServiceTests.swift` (add methods)

**Interfaces:**
- Consumes: `LibraryIndex` with grouped releases (Task 5), `Album.isVersionGroup` / `versions`.
- Produces: `findDuplicates(in:)` no longer flags two tracks that belong to *different* member pressings of the same release; intra-pressing duplicates and ungrouped near-duplicates still surface. Signature unchanged.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/CrateDiggerCoreTests/LibraryCleanupServiceTests.swift` (inside the class). Helper + tests:

```swift
    private func grouped() throws -> (LibraryIndex, [LoadedTrack]) {
        // Two pressings of Discovery, each with "One More Time".
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func mk(_ album: String, _ fmt: String) throws -> LoadedTrack {
            let url = dir.appendingPathComponent("\(album)-\(fmt).\(fmt)")
            try "x".write(to: url, atomically: true, encoding: .utf8)
            let t = AudioTrack(fileURL: url, title: "One More Time", artist: "Daft Punk",
                               album: album, formatName: fmt, bitrateKbps: 900, sampleRateHz: 44100)
            return LoadedTrack(track: t, metadata: ConversionMetadata())
        }
        let us = try mk("Discovery", "flac")
        let jp = try mk("Discovery (JP)", "alac")
        let planner = OutputPathPlanner()
        let group = AlbumGroup(id: "g1", name: "Discovery", artistID: "daft punk",
                               originalYear: 1999, primaryKey: planner.albumFolderKey(for: us),
                               members: [VersionMember(key: planner.albumFolderKey(for: us)),
                                         VersionMember(key: planner.albumFolderKey(for: jp))])
        return (LibraryIndex.build(from: [us, jp], groups: [group]), [us, jp])
    }

    func testGroupedVersionsNotFlaggedAsDuplicates() throws {
        let (index, _) = try grouped()
        let dupes = LibraryCleanupService(fileManager: .default).findDuplicates(in: index)
        XCTAssertEqual(dupes.count, 0)
    }

    func testDuplicateWithinSinglePressingStillFlagged() throws {
        // Same pressing ("Discovery") contains "One More Time" twice.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func mk(_ album: String, _ file: String) throws -> LoadedTrack {
            let url = dir.appendingPathComponent(file)
            try "x".write(to: url, atomically: true, encoding: .utf8)
            let t = AudioTrack(fileURL: url, title: "One More Time", artist: "Daft Punk",
                               album: album, formatName: "flac", bitrateKbps: 900, sampleRateHz: 44100)
            return LoadedTrack(track: t, metadata: ConversionMetadata())
        }
        let a = try mk("Discovery", "a.flac")
        let b = try mk("Discovery", "b.flac")          // duplicate inside the same pressing
        let jp = try mk("Discovery (JP)", "jp.flac")
        let planner = OutputPathPlanner()
        let group = AlbumGroup(id: "g1", name: "Discovery", artistID: "daft punk",
                               originalYear: 1999, primaryKey: planner.albumFolderKey(for: a),
                               members: [VersionMember(key: planner.albumFolderKey(for: a)),
                                         VersionMember(key: planner.albumFolderKey(for: jp))])
        let index = LibraryIndex.build(from: [a, b, jp], groups: [group])
        let dupes = LibraryCleanupService(fileManager: .default).findDuplicates(in: index)
        XCTAssertEqual(dupes.count, 1)
    }
```

(The existing `testFindDuplicatesPriority` already covers "ungrouped near-dupes still found.")

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh --filter LibraryCleanupServiceTests`
Expected: FAIL — `testGroupedVersionsNotFlaggedAsDuplicates` finds 1 group (current behavior flags across versions).

- [ ] **Step 3: Make `findDuplicates` version-aware**

In `Sources/CrateDiggerCore/Services/LibraryCleanupService.swift`, replace the body of `findDuplicates(in:)` (lines ~27-50) so the dedup key gains a per-pressing suffix for grouped tracks:

```swift
    public func findDuplicates(in index: LibraryIndex) -> [DuplicateGroup] {
        // Tracks inside a grouped release must only ever match duplicates within the
        // SAME member pressing — never across versions of the same release.
        var versionAlbumOfTrack: [UUID: String] = [:]
        for album in index.allAlbums where album.isVersionGroup {
            for version in album.versions ?? [] {
                for loaded in version.tracks {
                    versionAlbumOfTrack[loaded.track.id] = version.id
                }
            }
        }

        var grouped: [String: [LoadedTrack]] = [:]
        for loadedTrack in index.allTracks {
            let artist = loadedTrack.track.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let title = loadedTrack.track.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !title.isEmpty else { continue }
            let suffix = versionAlbumOfTrack[loadedTrack.track.id].map { " :: \($0)" } ?? ""
            let key = "\(artist) - \(title)\(suffix)"
            grouped[key, default: []].append(loadedTrack)
        }

        var duplicateGroups: [DuplicateGroup] = []
        for (_, tracks) in grouped where tracks.count > 1 {
            let sortedTracks = tracks.sorted { lhs, rhs in isBetterTrack(lhs: lhs, rhs: rhs) }
            if let best = sortedTracks.first {
                duplicateGroups.append(DuplicateGroup(bestTrack: best, worstTracks: Array(sortedTracks.dropFirst())))
            }
        }
        return duplicateGroups.sorted {
            $0.bestTrack.track.title.localizedCaseInsensitiveCompare($1.bestTrack.track.title) == .orderedAscending
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh --filter LibraryCleanupServiceTests`
Expected: PASS (existing priority test + 2 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/LibraryCleanupService.swift Tests/CrateDiggerCoreTests/LibraryCleanupServiceTests.swift
git commit -m "feat(core): version-aware duplicate finder

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: View-model store, index rewire, and grouping actions

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Versions.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` (add `albumGroupStore`; add `buildIndex` helper; rewire the 13 `LibraryIndex.build(from:` call sites; update `selectedAlbum`)

**Interfaces:**
- Consumes: `AlbumGroupStore`, `AlbumGroup`, `VersionMember`, `AlbumFolderKey`, `OutputPathPlanner`, `LibraryIndex.albumOrVersion`.
- Produces (on `LibraryViewModel`): `albumGroupStore`; `func buildIndex(_ tracks: [LoadedTrack]) -> LibraryIndex`; `var canGroupSelection: Bool`; `func versionKey(for album: Album) -> AlbumFolderKey`; `func commitGroup(id:name:originalYear:primaryKey:members:)`; `func ungroupRelease(_ release: Album)`; `func setPrimaryVersion(_ pressing: Album, in release: Album)`; `func setEditionLabel(_ label: String?, for pressing: Album, in release: Album)`; `func removeFromGroup(_ pressing: Album, release: Album)`; `func selectedAlbumsForGrouping() -> [Album]`.

This task wires everything; the actual grouping UI (sheet, menu) comes in Tasks 8–10. After this task the model compiles and existing behavior is unchanged (no groups exist yet), so verification is build-only.

- [ ] **Step 1: Add the store + central index builder**

In `LibraryViewModel.swift`, near the other service lets, add:

```swift
    let albumGroupStore = AlbumGroupStore()
```

Add the helper (place it near the other index plumbing, e.g. just above the first `LibraryIndex.build` usage):

```swift
    /// Build a browsable index, folding in the user's album version groups. All
    /// index construction goes through here so grouping applies uniformly. Grouping
    /// only takes effect where ≥2 member pressings are present, so non-local indexes
    /// (CD/playlist/remote) are unaffected — their keys never match local groups.
    func buildIndex(_ tracks: [LoadedTrack]) -> LibraryIndex {
        LibraryIndex.build(from: tracks, groups: albumGroupStore.all())
    }
```

- [ ] **Step 2: Rewire every `LibraryIndex.build(from:)` call**

Replace each occurrence of `LibraryIndex.build(from: X)` in `LibraryViewModel.swift` with `buildIndex(X)`. There are 13 (lines ~735, 739, 742, 941, 989, 1099, 1178, 1222, 1255, 1530, 1724, 1726, 2262, 2280 in the pre-edit file). Use a search to confirm none remain:

Run: `grep -n "LibraryIndex.build(from:" Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift`
Expected after edit: no matches (all now go through `buildIndex`).

- [ ] **Step 3: Resolve pressing ids in `selectedAlbum`**

Replace the `selectedAlbum` computed var (lines ~661-665) with one that resolves nested pressings:

```swift
    var selectedAlbum: Album? {
        if let id = selectedAlbumID, let found = index.albumOrVersion(id: id) { return found }
        return selectedArtist?.albums.first
    }
```

- [ ] **Step 4: Create the actions extension**

Create `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Versions.swift`:

```swift
import AppKit
import CrateDiggerCore

/// Album version-group actions: grouping multiple albums into one release,
/// editing/ungrouping, and the helpers the browser + sheet rely on. Grouping is
/// non-destructive — it only writes to `AlbumGroupStore`; files are untouched.
@MainActor
extension LibraryViewModel {

    private var versionPlanner: OutputPathPlanner { OutputPathPlanner() }

    /// The stable identity used to reference a pressing inside a group.
    func versionKey(for album: Album) -> AlbumFolderKey? {
        // A grouped release has no single key; use its primary pressing.
        let source = album.isVersionGroup ? album.versions?.first : album
        guard let track = source?.tracks.first else { return nil }
        return versionPlanner.albumFolderKey(for: track)
    }

    /// Albums currently multi-selected (for "Group Albums"). Resolves the selected
    /// album ids to top-level albums in the current index.
    func selectedAlbumsForGrouping() -> [Album] {
        let ids = selectedAlbumIDs.isEmpty ? Set([selectedAlbumID].compactMap { $0 }) : selectedAlbumIDs
        return index.allAlbums.filter { ids.contains($0.id) }
    }

    /// Enabled when 2+ plain (non-grouped) local albums of the same artist are selected.
    var canGroupSelection: Bool {
        guard isLocalSource else { return false }
        let albums = selectedAlbumsForGrouping().filter { !$0.isVersionGroup }
        guard albums.count >= 2 else { return false }
        return Set(albums.map(\.artistID)).count == 1
    }

    /// True for the library sources where grouping applies.
    private var isLocalSource: Bool {
        switch currentSource {
        case .localAll, .localCrate, .prepCrate: return true
        default: return false
        }
    }

    /// Create or update a group, persist it, and rebuild the local index.
    func commitGroup(id: String, name: String, originalYear: Int?,
                     primaryKey: AlbumFolderKey, members: [VersionMember]) {
        guard members.count >= 2 else { return }
        let artistID = members.first.flatMap { albumForKey($0.key)?.artistID } ?? ""
        let group = AlbumGroup(id: id, name: name, artistID: artistID,
                               originalYear: originalYear, primaryKey: primaryKey, members: members)
        albumGroupStore.upsert(group)
        reloadAfterGroupChange()
    }

    func ungroupRelease(_ release: Album) {
        guard let groupID = groupID(of: release) else { return }
        albumGroupStore.remove(id: groupID)
        reloadAfterGroupChange()
    }

    func setPrimaryVersion(_ pressing: Album, in release: Album) {
        mutateGroup(of: release) { group in
            if let track = pressing.tracks.first {
                group.primaryKey = versionPlanner.albumFolderKey(for: track)
            }
        }
    }

    func setEditionLabel(_ label: String?, for pressing: Album, in release: Album) {
        guard let track = pressing.tracks.first else { return }
        let key = versionPlanner.albumFolderKey(for: track)
        mutateGroup(of: release) { group in
            if let i = group.members.firstIndex(where: { $0.key == key }) {
                group.members[i].editionLabel = label?.isEmpty == true ? nil : label
            }
        }
    }

    func removeFromGroup(_ pressing: Album, release: Album) {
        guard let track = pressing.tracks.first else { return }
        let key = versionPlanner.albumFolderKey(for: track)
        mutateGroup(of: release) { group in
            group.members.removeAll { $0.key == key }
        }
    }

    // MARK: - Helpers

    func groupID(of release: Album) -> String? {
        guard release.id.hasPrefix("group::") else { return nil }
        return String(release.id.dropFirst("group::".count))
    }

    private func albumForKey(_ key: AlbumFolderKey) -> Album? {
        index.allTracks.first.flatMap { _ in
            index.allAlbums.first { album in
                guard let t = (album.isVersionGroup ? album.versions?.first?.tracks.first : album.tracks.first)
                else { return false }
                return versionPlanner.albumFolderKey(for: t) == key
            }
        }
    }

    private func mutateGroup(of release: Album, _ body: (inout AlbumGroup) -> Void) {
        guard let id = groupID(of: release),
              var group = albumGroupStore.all().first(where: { $0.id == id }) else { return }
        body(&group)
        if group.members.count < 2 {
            albumGroupStore.remove(id: id)        // dissolves to plain albums
        } else {
            albumGroupStore.upsert(group)
        }
        reloadAfterGroupChange()
    }

    /// Rebuild the visible local index after a group change.
    private func reloadAfterGroupChange() {
        clearMultiSelection()
        selectSource(currentSource)
    }
}
```

(If `OutputPathPlanner()` is expensive to construct repeatedly, the executor may cache one on the model; functionally it is a cheap value type.)

- [ ] **Step 5: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds. (No behavior change yet — no groups exist and nothing calls the new actions.)

- [ ] **Step 6: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Versions.swift
git commit -m "feat(app): version-group store, index folding wire-up, grouping actions

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Group/Edit sheet + present actions

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/Sheets/GroupAlbumsSheetController.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Versions.swift` (add `beginGroupAlbums()`, `editGroup(_:)`)
- Modify: `Sources/CrateDiggerApp/UI/MainWindowController.swift` (present the sheet — follow the existing sheet-presentation pattern, e.g. how `ConversionOptionsSheetController` is shown)

**Interfaces:**
- Consumes: `commitGroup(...)`, `selectedAlbumsForGrouping()`, `versionKey(for:)`, `VersionLabel.formatBadge`.
- Produces: `GroupAlbumsSheetController` with a `Result` payload `{ name: String; originalYear: Int?; primaryKey: AlbumFolderKey; members: [VersionMember] }` and an `onDecision: (Result?) -> Void` closure; `LibraryViewModel.beginGroupAlbums()` and `editGroup(_ release: Album)`.

- [ ] **Step 1: Build the sheet controller**

Create `Sources/CrateDiggerApp/UI/Carbon/Sheets/GroupAlbumsSheetController.swift`. Model it on an existing sheet (open `ConversionOptionsSheetController.swift` first to match chrome/styling conventions). Minimum viable contents:

```swift
import AppKit
import CrateDiggerCore

/// Confirm/edit sheet for an album version group: set the release name, the
/// original release year (used for sorting), pick the primary pressing, and edit
/// each pressing's edition label. Pre-filled so it's usually glance-and-confirm.
final class GroupAlbumsSheetController: NSViewController {

    struct VersionRow {
        let album: Album
        let key: AlbumFolderKey
        let formatBadge: String
        var editionLabel: String
    }

    struct Result {
        let name: String
        let originalYear: Int?
        let primaryKey: AlbumFolderKey
        let members: [VersionMember]
    }

    var onDecision: ((Result?) -> Void)?

    private var rows: [VersionRow]
    private var primaryKey: AlbumFolderKey
    private let nameField = NSTextField()
    private let yearField = NSTextField()
    // One text field per row for the edition label; primary chosen via radio/popup.
    private var editionFields: [NSTextField] = []
    private var primaryPopup = NSPopUpButton()

    init(name: String, originalYear: Int?, rows: [VersionRow], primaryKey: AlbumFolderKey) {
        self.rows = rows
        self.primaryKey = primaryKey
        super.init(nibName: nil, bundle: nil)
        nameField.stringValue = name
        yearField.stringValue = originalYear.map(String.init) ?? ""
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        // Build a vertical stack: name field, year field, a row per version with its
        // format badge + edition text field, a "primary" picker, and Cancel/Group
        // buttons wired to cancel()/confirm(). Match the Carbon sheet styling used by
        // the sibling controllers in this folder.
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 360))
        // ... lay out controls (executor: mirror ConversionOptionsSheetController) ...
    }

    @objc private func cancel() { onDecision?(nil) }

    @objc private func confirm() {
        let year = Int(yearField.stringValue.trimmingCharacters(in: .whitespaces))
        let members = zip(rows, editionFields).map { row, field in
            VersionMember(key: row.key,
                          editionLabel: field.stringValue.isEmpty ? nil : field.stringValue)
        }
        onDecision?(Result(name: nameField.stringValue, originalYear: year,
                           primaryKey: primaryKey, members: members))
    }
}
```

(The executor fleshes out `loadView()` layout to match the existing Carbon sheets — labels, the primary `NSPopUpButton` populated from `rows`, and the two buttons. Keep the controller free of business logic beyond assembling `Result`.)

- [ ] **Step 2: Add present actions on the view-model**

Append to `LibraryViewModel+Versions.swift`:

```swift
    /// Open the group sheet for the current multi-selection.
    func beginGroupAlbums() {
        let albums = selectedAlbumsForGrouping().filter { !$0.isVersionGroup }
        guard albums.count >= 2 else { return }
        let rows: [GroupAlbumsSheetController.VersionRow] = albums.compactMap { album in
            guard let key = versionKey(for: album) else { return nil }
            return .init(album: album, key: key,
                         formatBadge: VersionLabel.formatBadge(for: album), editionLabel: "")
        }
        guard rows.count >= 2 else { return }
        let suggestedName = albums.map(\.title).min(by: { $0.count < $1.count }) ?? albums[0].title
        let suggestedYear = albums.compactMap(\.year).min()
        presentGroupSheet(id: UUID().uuidString, name: suggestedName, year: suggestedYear,
                          rows: rows, primaryKey: rows[0].key)
    }

    /// Re-open the sheet to edit an existing release.
    func editGroup(_ release: Album) {
        guard let id = groupID(of: release),
              let group = albumGroupStore.all().first(where: { $0.id == id }) else { return }
        let rows: [GroupAlbumsSheetController.VersionRow] = (release.versions ?? []).compactMap { v in
            guard let key = versionKey(for: v) else { return nil }
            let existing = group.members.first { $0.key == key }?.editionLabel ?? ""
            return .init(album: v, key: key,
                         formatBadge: VersionLabel.formatBadge(for: v), editionLabel: existing)
        }
        presentGroupSheet(id: id, name: group.name, year: group.originalYear,
                          rows: rows, primaryKey: group.primaryKey)
    }

    private func presentGroupSheet(id: String, name: String, year: Int?,
                                   rows: [GroupAlbumsSheetController.VersionRow],
                                   primaryKey: AlbumFolderKey) {
        let sheet = GroupAlbumsSheetController(name: name, originalYear: year,
                                               rows: rows, primaryKey: primaryKey)
        sheet.onDecision = { [weak self] result in
            guard let self, let result else { return }
            self.commitGroup(id: id, name: result.name, originalYear: result.originalYear,
                             primaryKey: result.primaryKey, members: result.members)
        }
        NotificationCenter.default.post(name: .init("CrateDiggerPresentSheet"), object: sheet)
    }
```

- [ ] **Step 3: Present the sheet from the window controller**

In `MainWindowController.swift`, observe `"CrateDiggerPresentSheet"` and call `contentViewController?.presentAsSheet(controller)` — copy the exact mechanism the file already uses for other `NSViewController` sheets (search the file for `presentAsSheet`). If the project already routes sheet presentation through a single helper, register this controller type there instead and skip the notification.

- [ ] **Step 4: Build + manual verify**

Run: `swift build`
Expected: succeeds.
Manual (run the debug binary, local library):
- Select 2+ albums of one artist → trigger `beginGroupAlbums()` (wired in Task 10) → sheet appears pre-filled with name + earliest year; each row shows a format badge + an edition field; a primary picker lists the pressings.
- Set year "1975", label two rows, confirm → no crash. (Visible result lands with Task 9.)

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Sheets/GroupAlbumsSheetController.swift Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Versions.swift Sources/CrateDiggerApp/UI/MainWindowController.swift
git commit -m "feat(app): GroupAlbums confirm/edit sheet

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 9: Browser rendering — expandable release rows

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Main/Browser/BrowserPane.swift` (`AlbumColumn`)

**Interfaces:**
- Consumes: `Album.isVersionGroup` / `versions` / `editionLabel`, `VersionLabel.formatBadge`, `model.isAlbumSelected`, `model.selectAlbum`, the multi-select wiring.
- Produces: grouped releases render as a parent row with a disclosure chevron + "N versions"; expanded, member pressings render as indented sub-rows with badge + edition label; selecting a sub-row drives the Track column.

- [ ] **Step 1: Add expansion state + sub-row rendering to `AlbumColumn`**

In `BrowserPane.swift`'s `AlbumColumn`, add view-local expansion state and branch the `ForEach` body on `album.isVersionGroup`:

```swift
private struct AlbumColumn: View {
    @EnvironmentObject private var model: LibraryViewModel
    var flat: Bool = false
    @State private var expandedReleaseIDs: Set<String> = []

    private var albums: [Album] { flat ? model.allAlbumsSorted : model.visibleAlbums }

    var body: some View {
        ColumnList(
            title: "Album",
            trailing: String(format: "%02d", flat ? albums.count : (model.selectedArtist?.albumCount ?? 0)),
            headerAccessory: model.showSortControls ? AnyView(AlbumSortControl()) : nil
        ) {
            ForEach(albums) { album in
                if album.isVersionGroup {
                    releaseRow(album)
                    if expandedReleaseIDs.contains(album.id) {
                        ForEach(album.versions ?? []) { version in
                            versionRow(version, in: album)
                        }
                    }
                } else {
                    plainRow(album)
                }
            }
        }
    }

    private func plainRow(_ album: Album) -> some View {
        AlbumRow(
            album: album,
            selected: model.isAlbumSelected(album.id),
            isPlayingHere: isPlayingAlbum(album),
            onSelect: {
                let m = NSEvent.modifierFlags
                model.selectAlbum(album, command: m.contains(.command), shift: m.contains(.shift),
                                  ordered: albums.filter { !$0.isVersionGroup }, flat: flat)
            }
        )
        .contextMenu { BrowserContextMenu.album(album, model: model) }
    }

    private func releaseRow(_ release: Album) -> some View {
        AlbumRow(
            album: release,
            selected: model.isAlbumSelected(release.id),
            isPlayingHere: isPlayingAlbum(release),
            badge: "\(release.versions?.count ?? 0) ver",
            disclosed: expandedReleaseIDs.contains(release.id),
            onDisclose: {
                if expandedReleaseIDs.contains(release.id) { expandedReleaseIDs.remove(release.id) }
                else { expandedReleaseIDs.insert(release.id) }
            },
            onSelect: {
                let m = NSEvent.modifierFlags
                model.selectAlbum(release, command: m.contains(.command), shift: m.contains(.shift),
                                  ordered: albums, flat: flat)
            }
        )
        .contextMenu { BrowserContextMenu.release(release, model: model) }
    }

    private func versionRow(_ version: Album, in release: Album) -> some View {
        VersionSubRow(
            badge: VersionLabel.formatBadge(for: version),
            edition: version.editionLabel,
            selected: model.selectedAlbumID == version.id,
            onSelect: { model.selectedAlbumID = version.id }
        )
        .contextMenu { BrowserContextMenu.version(version, release: release, model: model) }
    }

    private func isPlayingAlbum(_ album: Album) -> Bool {
        guard let nowID = model.nowPlayingTrack?.track.id else { return false }
        let pool = album.isVersionGroup ? (album.versions ?? []).flatMap { $0.tracks } : album.tracks
        return pool.contains { $0.track.id == nowID }
    }
}
```

- [ ] **Step 2: Extend `AlbumRow` with optional badge/disclosure, and add `VersionSubRow`**

In `Rows/AlbumRow.swift`, add optional `badge: String? = nil`, `disclosed: Bool? = nil`, `onDisclose: (() -> Void)? = nil` parameters; render a chevron (`disclosed == true ? "chevron.down" : "chevron.right"`) calling `onDisclose` when `disclosed != nil`, and a trailing pill when `badge != nil`. Keep all existing call sites working (new params default to nil). Create `Rows/VersionSubRow.swift`:

```swift
import CrateDiggerCore
import SwiftUI

/// One pressing under an expanded release row: an indented row showing the
/// auto format badge and the user's edition label.
struct VersionSubRow: View {
    @Environment(\.carbon) private var theme
    let badge: String
    let edition: String?
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Spacer().frame(width: 18)
                Text(badge)
                    .font(CarbonFont.mono(9.5, weight: .semibold))
                    .foregroundStyle(selected ? theme.selectionInk : theme.ink2)
                if let edition, !edition.isEmpty {
                    Text(edition)
                        .font(CarbonFont.mono(9.5))
                        .foregroundStyle(selected ? theme.selectionInk.opacity(0.8) : theme.ink3)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(selected ? theme.orange.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 3: Build + manual verify**

Run: `swift build`
Expected: succeeds.
Manual (debug binary): after grouping two albums (Task 8 + Task 10 menu), the release shows one row with a chevron + "2 ver"; expanding lists both pressings with `FLAC · …` badges + edition labels; clicking a pressing shows its tracks in the Track column; the release sits at its original-year position.

- [ ] **Step 4: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Main/Browser/BrowserPane.swift Sources/CrateDiggerApp/UI/Carbon/Main/Browser/Rows/AlbumRow.swift Sources/CrateDiggerApp/UI/Carbon/Main/Browser/Rows/VersionSubRow.swift
git commit -m "feat(app): expandable version-group rows in the album browser

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 10: Context-menu actions for grouping

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Main/Browser/BrowserContextMenu.swift`

**Interfaces:**
- Consumes: `model.canGroupSelection`, `beginGroupAlbums`, `editGroup`, `ungroupRelease`, `setPrimaryVersion`, `setEditionLabel`, `removeFromGroup`, `addItemsToCrate`, `addSelectionToCrate`.
- Produces: `BrowserContextMenu.album` gains **Group N Albums…**; new `BrowserContextMenu.release(_:model:)` and `BrowserContextMenu.version(_:release:model:)` builders used by Task 9.

- [ ] **Step 1: Add "Group Albums" to the album menu**

In `BrowserContextMenu.album(_:model:)`, after the existing "Select All" button, add:

```swift
        if model.canGroupSelection {
            Button("Group \(model.selectedAlbumsForGrouping().filter { !$0.isVersionGroup }.count) Albums…") {
                model.beginGroupAlbums()
            }
        }
```

- [ ] **Step 2: Add the release and version menus**

Add two new builders to the `BrowserContextMenu` enum:

```swift
    /// Menu for a grouped release (parent row).
    @ViewBuilder
    static func release(_ release: Album, model: LibraryViewModel) -> some View {
        if !model.availableCrates.isEmpty {
            Menu("Add Primary Version to Crate") {
                ForEach(model.availableCrates, id: \.self) { crate in
                    Button(crate) {
                        model.addItemsToCrate(release.tracks.map { "track::" + $0.track.id.uuidString },
                                              crateName: crate)
                    }
                }
            }
        }
        Button("Edit Group…") { model.editGroup(release) }
        Button("Ungroup") { model.ungroupRelease(release) }
    }

    /// Menu for a single pressing (sub-row) inside a release.
    @ViewBuilder
    static func version(_ version: Album, release: Album, model: LibraryViewModel) -> some View {
        if !model.availableCrates.isEmpty {
            Menu("Add This Version to Crate") {
                ForEach(model.availableCrates, id: \.self) { crate in
                    Button(crate) {
                        model.addItemsToCrate(version.tracks.map { "track::" + $0.track.id.uuidString },
                                              crateName: crate)
                    }
                }
            }
        }
        Button("Set as Primary") { model.setPrimaryVersion(version, in: release) }
        Button("Edit Edition Label…") { model.promptEditionLabel(for: version, in: release) }
        Divider()
        Button("Remove from Group") { model.removeFromGroup(version, release: release) }
    }
```

- [ ] **Step 3: Add the edition-label prompt helper**

In `LibraryViewModel+Versions.swift`, add a small `NSAlert`-with-text-field prompt (mirror `promptRemoveTrackFromLibrary`'s `NSAlert` usage) that calls `setEditionLabel`:

```swift
    func promptEditionLabel(for pressing: Album, in release: Album) {
        let alert = NSAlert()
        alert.messageText = "Edition label"
        alert.informativeText = "e.g. Gold CD, JP Vinyl, 2011 Remaster"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = pressing.editionLabel ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            setEditionLabel(field.stringValue, for: pressing, in: release)
        }
    }
```

- [ ] **Step 4: Build + manual verify**

Run: `swift build`
Expected: succeeds.
Manual end-to-end (debug binary, local library with a real duplicate-format album):
1. Multi-select 2 albums of one artist → right-click → "Group 2 Albums…" → sheet → set year/labels → confirm.
2. Release row appears at its original-year slot with a chevron + "2 ver"; expand → two pressings with badges + labels.
3. Right-click a pressing → Set as Primary / Edit Edition Label… / Add This Version to Crate / Remove from Group all work.
4. Right-click the release → Edit Group… / Ungroup / Add Primary Version to Crate work; Ungroup restores two plain albums.
5. Cleanup → Find Duplicates does **not** list the grouped pressings' shared tracks.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Main/Browser/BrowserContextMenu.swift Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Versions.swift
git commit -m "feat(app): group/ungroup/edit context-menu actions for versions

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Multiple distinct versions, never flattened → Tasks 3, 5 (release holds pressings; `allTracks` intact). ✓
- Expandable Option-B presentation → Task 9. ✓
- Canonical original-year sort → Task 5 (effective-year comparator). ✓
- Version-aware duplicate finder → Task 6. ✓
- Non-destructive persistence → Tasks 2, 7 (store only; no file writes). ✓
- Manual grouping + confirm sheet → Tasks 8, 10. ✓
- Auto format badge + editable edition label → Tasks 4, 8, 10. ✓
- Crates store pressings/primary → Task 10 (`Add This Version` / `Add Primary Version`). ✓
- Local-only, single-artist, ≥2 members, dissolve → Tasks 5, 7 (`canGroupSelection`, fold guard, `mutateGroup` dissolve). ✓
- Self-healing dead refs → Task 5 (folding drops unmatched keys). ✓

**Placeholder scan:** Core tasks contain complete code. The only intentionally-deferred detail is `GroupAlbumsSheetController.loadView()` AppKit layout (Task 8 Step 1) and the `AlbumRow` chevron/badge rendering (Task 9 Step 2) — both are described with exact parameters and a sibling file to mirror, consistent with the project's manually-verified UI layer; no behavioral logic is hidden there.

**Type consistency:** `AlbumFolderKey` is the version identity throughout (`VersionMember.key`, `AlbumGroup.primaryKey`, `versionKey(for:)`, sheet `Result.primaryKey`). `build(from:groups:)`, `albumOrVersion(id:)`, `isVersionGroup`, `with(editionLabel:)`, `formatBadge(for:)`, `buildIndex(_:)`, `canGroupSelection`, `commitGroup(id:name:originalYear:primaryKey:members:)` are defined once and consumed with matching signatures. Release ids use the `"group::<uuid>"` convention in Task 5 and are parsed back by `groupID(of:)` in Task 7.

---

## Notes for the executor

- App-layer tasks (7–10) cannot be unit-tested (no `LibraryViewModel`/UI harness — see CLAUDE.md). Their gate is `swift build` + the manual checklist; this matches the project norm.
- Test the easy win first: after Task 6, the duplicate-finder safety is fully covered by Core tests even before any UI exists.
- The Daft Punk / Pink Floyd scenarios from the spec make good manual fixtures.
