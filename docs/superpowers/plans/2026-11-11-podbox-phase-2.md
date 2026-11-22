# PodBox Phase 2 (Artist Pictures and Folder Layout) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A PodBox iPod gets an artist picture for every artist CrateDigger can match with confidence or the owner picks by hand, written where PodBox looks first and never over the owner's own images; and a new PodBox profile can use the `Album Artist / YYYY Album` layout PodBox reads best.

**Architecture:** Pure Core in `Services/PodBox/`: a port of PodBox's name fold and hash, a simulation of the player's picture lookup, a budget for its `/Artwork` cap, a picture store in the library's index folder, sources behind a fetch protocol, and a planner that emits `DeviceFileOperation`s for Phase 1's `DeviceFileExecutor`. The layout preset is a small Core enum that seeds a profile's existing `FolderTemplateConfig`. The view model wires a finder run after each transfer and an Artist Pictures sheet.

**Tech Stack:** Swift, SwiftPM, XCTest (`scripts/test.sh`), ImageIO/CoreGraphics, `URLSession` behind a protocol, AppKit sheet hosting SwiftUI.

**Spec:** `docs/superpowers/specs/2026-11-11-podbox-integration-design.md`. Read "Safety", decisions D1 to D5, "Phase 2" and the layout parts of "Phase 4". The algorithm for the name fold is Appendix A of `.superpowers/podbox-research.md` ("the brief"); Task 2 quotes what it needs. This plan depends on `docs/superpowers/plans/2026-11-11-podbox-phase-1.md` ("Phase 1").

## Global Constraints

- Work only in the podbox worktree (`/Volumes/EX_3/Code/CrateDigger/.claude/worktrees/podbox`, branch `feat/podbox`). Never `cd` to another checkout.
- Never push/tag/bump versions.
- A real iPod is mounted at /Volumes/IPOD. Never write, rename or delete anything under /Volumes outside this repo, and never run the app's transfer, cleanup or picture-writing against a real device. Tests use temp directories or the FakeIPod fixture.
- Build with `swift build`, test with `scripts/test.sh --filter <Class>`, full `scripts/test.sh` green before each commit.
- Commit messages end with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`. Stage only files you changed.
- No em dashes in user-facing copy.
- Network code is behind a protocol with a fake in tests and tests never hit the network.
- No personal data in requests to outside services. A request carries an artist name and a generic client name (`User-Agent: CrateDigger`), nothing else: no user name, email, library path, device name or volume UUID.
- Decidable logic lives in `CrateDiggerCore` with an XCTest; view-model code only wires.
- Every picture write and delete goes through Phase 1's `DeviceFileExecutor`; no code here calls a file-system mutator on a device path (Phase 1's `DeviceWriteDoorLintTests` covers `Services/PodBox`).
- Nothing is written to a device at mount, and pictures need the device matched by volume UUID (`DeviceSessionGate`, `.writeExtras`).
- `PodBoxPreferences.artistPictures` is `.off` for every existing and new profile until the owner has passed check M5. No task here turns it on by default.
- Anything that writes the library index starts with `guard !refuseWhileLibraryDisconnected()`.
- No GPL source enters the repo. The fold is written from the brief's description; only output values from PodBox's C may be committed.
- An existing profile's folder template is never changed by this plan.

## Review Focus

1. **A name PodBox cannot key or that folds to another artist's key** (`!!!`, `Björk` beside `Bjork`, `The The`, a name in Cyrillic or kanji). Expected: no crash, one file per key, a name with key 0 reported as unnameable, non-Latin names kept. Tests: `testZeroKeyNames`, `testNonLatinNamesKeepTheirCodePoints` (Task 2), `testTwoNamesOneKeyPlanOneFile`, `testZeroKeyNameIsUnnameable` (Task 8).
2. **A self-titled album** (`Weezer/Weezer/cover.jpg`). The player would take the album cover as the portrait; CrateDigger must not count that cover as "already has a picture". Test: `testAlbumCoverInSelfTitledFolderDoesNotBlock` (Task 3).
3. **A service that answers 200 with something else** (Deezer's `{"error":{"code":4}}`, an HTML error page, an empty list, its no-image placeholder). Expected: no picture, no crash, a quota error stops the run and keeps what was found. Tests: `testQuotaErrorBody`, `testHTMLBodyThrowsParseError`, `testPlaceholderRejected` (Task 6), `testQuotaStopsTheRunAndKeepsEarlierResults` (Task 6).
4. **An image that is not what was asked for** (120 px, 20,000 px wide, 3:1 banner, CMYK JPEG, animated GIF, PNG with alpha, zero bytes, truncated). Expected: nil, or a 400 px square sRGB baseline JPEG of at most 100 KB; never a hang or a huge allocation. Tests in `ArtistPictureImageTests` (Task 4).
5. **The owner's own picture already on the iPod, including one the owner made by editing ours.** Expected: never overwritten, reported as already having a picture or as foreign. Tests: `testOwnersPeopleFileBlocksOurs`, `testOurPictureEditedOnDeviceIsNotReplaced` (Task 8).

---

### Task 1: FAT-safe names (Core-only)

**Depends on:** nothing.

**Files:**
- Create: `Sources/CrateDiggerCore/Services/DeviceFiles/FATName.swift`
- Test: `Tests/CrateDiggerCoreTests/FATNameTests.swift`

**Produces:** `FATName.component(_:extension:)`, `fitsPlayerPath(_:prefix:)`, `collides(_:_:)` as in the spec.

Pinned details: NFC first. `?` and `*` removed; `"` → `'`; `<`, `>`, `|` → `-`; `/`, `\`, `:` → `-`; U+0000 to U+001F and U+007F → `_`; then trailing dots and spaces trimmed from the stem; a leading dot is removed. Reserved stems `CON PRN AUX NUL COM1`…`COM9 LPT1`…`LPT9` (any case) get a trailing `_`. The whole component (stem + `.` + extension) is at most 255 UTF-16 units, truncating the stem on a grapheme boundary. Empty stem → nil. `fitsPlayerPath`: UTF-8 byte count of `(prefix ?? "/<HDD0>") + "/" + relativePath` ≤ 252. `collides`: equal after NFC and case folding.

- [ ] **Step 1: Failing tests:** `testIllegalCharactersReplaced` (`Who's Next?` → `Who's Next`; `AC/DC` → `AC-DC`; `a<b>c|d"e*` → `a-b-c-d'e`), `testTrailingDotsAndSpacesTrimmed` (`R.E.M.` → `R.E.M`), `testLeadingDotRemoved`, `testReservedNames` (`con` → `con_`, `LPT1` with extension `jpg` → `LPT1_.jpg`), `testControlCharacters`, `testOutputIsNFC` (decomposed `Björk` in → precomposed out), `testTruncatesOnGraphemeBoundaryKeepingExtension` (300 `é` + flag emoji), `testNothingLeftGivesNil` (`???`, `...`), `testFitsPlayerPathBoundary` (252 yes, 253 no), `testCollidesIgnoresCaseAndNormalisation`.
- [ ] **Step 2 to 4:** fail, implement, filter then full suite pass.
- [ ] **Step 5:** Commit `feat(devices): FAT-safe file name rules`.

### Task 2: PodBox's name fold and hash (Core-only)

**Depends on:** Task 1.

**Files:**
- Create: `Sources/CrateDiggerCore/Services/PodBox/PodBoxArtName.swift`
- Create: `scripts/podbox-artname-vectors.sh`
- Create (if the script succeeds): `Tests/CrateDiggerCoreTests/Fixtures/podbox-artname-vectors.json`
- Test: `Tests/CrateDiggerCoreTests/PodBoxArtNameTests.swift`

**Produces:** `PodBoxArtName.folded`, `key`, `altKey`, `matches`, `fileStem(for:)` as in the spec.

The algorithm (from the brief's Appendix A; write the Swift from this, not from PodBox's source):
- 32-bit hash, start `0x811C9DC5 ^ 0x5A5A5A5A`, per kept code point `h = (h ^ c) &* 16_777_619`. Result: 0 if nothing was kept, 1 if `h == 0`, else `h`.
- `key(name)`: if the UTF-8 is longer than 5 bytes and ends with `, the` (ASCII case-insensitive), drop those 5 bytes. If what remains is longer than 4 bytes and starts with `the ` (case-insensitive), skip 4 bytes. Fold every remaining code point.
- Fold one code point `c`: U+FF01…FF5E → subtract 0xFEE0 first. Then: ASCII `A-Z` → lowercase; `a-z`, `0-9` → kept; `&` → `a`, `n`, `d`; other ASCII → dropped. U+0080…00BF dropped. U+0300…036F, U+2000…2BFF, U+3000…303F, U+FE00…FE0F dropped. U+00C0…017F → the table below (`-` drops, lowercase letter kept, uppercase letter emits its pair). Anything else kept unchanged (not lowercased).
- Table, 32 characters per row from the row's first code point:
  - U+00C0 `aaaaaaAceeeeiiiidnooooo-ouuuuyTS`
  - U+00E0 `aaaaaaAceeeeiiiidnooooo-ouuuuyTy`
  - U+0100 `aaaaaaccccccccddddeeeeeeeeeegggg`
  - U+0120 `gggghhhhiiiiiiiiiiIIjjkkklllllll`
  - U+0140 `lllnnnnnnnnnooooooOOrrrrrrssssss`
  - U+0160 `ssttttttuuuuuuuuuuuuwwyyyzzzzzzs`
  - pairs: `A` → `ae`, `O` → `oe`, `S` → `ss`, `T` → `th`, `I` → `ij`
- `altKey(name)`: 0 unless the name has exactly one comma. Otherwise hash the text after the comma (skipping one following space) with the `the ` rule, then the text before the comma without it.
- `matches(a, b)`: any non-zero of `{key(a), altKey(a)}` equals any non-zero of `{key(b), altKey(b)}`.
- `folded(name)`: the code points `key` would hash, as a `String`.
- `fileStem(for:)`: nil when `key(name) == 0`. Else `FATName.component(name, extension: nil)` when that is non-nil and its `key` equals `key(name)`; else `folded(name)`.

The brief's prose says Ø folds to `oe`; the table says `o` (index 24 of the first two rows). **Follow the table.** The vectors decide.

`scripts/podbox-artname-vectors.sh` (dev tool, never run by the build or the tests): downloads `apps-ipod/metadata/art_name.c` from `https://raw.githubusercontent.com/anthonyfletcher/podbox/f0850c4647e7c1cfde11ffc89ab40b55f8aa5635/` into a temp directory outside the repo, compiles it with a small C driver and a stub UTF-8 decoder written in the script, and prints JSON `[{"name":…,"key":…,"altKey":…}]` for a fixed corpus embedded in the script: the names in the tests below, one name per table column for all six rows, one per dropped range, `Ø`, `ø`, `Œ`, fullwidth `ＡＢＣ`, `КИНО`, `Кино`, `椎名林檎`, `Sigur Rós`, `Herbert, Frank`, `Beatles, The`, `!!!`, `The `, `The The`. The corpus contains no name taken from the owner's library. The request sends no headers beyond curl's defaults.

- [ ] **Step 1: Failing tests:** `testWorkedExamples` (`folded` of `N*E*R*D`, `N.E.R.D`, `NERD` all `nerd`; `AC/DC`, `AC_DC`, `AC-DC`, `ACDC` all `acdc`; `Björk` → `bjork`; `The Beatles`, `Beatles`, `Beatles, The` all `beatles`; `Simon & Garfunkel` → `simonandgarfunkel`), `testTheThe` (`The The` → `the`), `testLoneTheIsUntouched` (`The ` → `the`), `testAltKeyReversesOneComma` (`matches("Herbert, Frank", "Frank Herbert")`), `testAltKeyZeroWithoutExactlyOneComma`, `testFullwidthFolds` (`ＡＢＣ` → `abc`), `testCombiningMarksDropped` (NFD `Björk` key equals NFC key), `testLatinPairs` (`Æ` → `ae`, `ß` → `ss`, `Þ` → `th`, `Œ` → `oe`, `Ĳ` → `ij`), `testOSlashFollowsTheTable` (`Ø` → `o`), `testNonLatinNamesKeepTheirCodePoints` (`key("КИНО") != key("Кино")`, both non-zero) (Review Focus 1), `testZeroKeyNames` (`!!!`, empty, `&&&` is not zero) (Review Focus 1), `testFinishMapsZeroHashToOne` (unit-test the finish step directly), `testKeyOfFNV` (`key("a") == ((0x811C9DC5 ^ 0x5A5A5A5A ^ 0x61) &* 16777619)`), `testFoldedIsAFixedPoint` (`folded(folded(x)) == folded(x)` and same key, over the corpus), `testFileStemKeepsTheKey` (for every corpus name with a non-zero key, `key(fileStem) == key(name)`), `testFileStemFallsBackToFold` (a 400-character name), `testVectorsFromPodBoxSource` (loads the JSON fixture relative to `#filePath`; `XCTSkip` when the file is absent; otherwise every entry's key and alt key match).
- [ ] **Step 2:** Run, see failures.
- [ ] **Step 3:** Implement `PodBoxArtName` and write the script.
- [ ] **Step 4:** Run the script once. If it downloads and compiles, commit its JSON output as the fixture; if the vectors disagree with the port, the C output wins: fix the port (and `testOSlashFollowsTheTable` if Ø is the difference) and note it in the commit body. If the download or compile fails, do not block: leave the fixture absent (the test skips) and say so in the commit body.
- [ ] **Step 5:** Filter and full suite pass. Commit `feat(podbox): port the art name fold and hash`.

### Task 3: What the player would find, and the `/Artwork` budget (Core-only)

**Depends on:** Task 2.

**Files:**
- Create: `Sources/CrateDiggerCore/Services/PodBox/PodBoxArtLookup.swift`
- Create: `Sources/CrateDiggerCore/Services/PodBox/PodBoxArtworkBudget.swift`
- Test: `Tests/CrateDiggerCoreTests/PodBoxArtLookupTests.swift`, `PodBoxArtworkBudgetTests.swift`

**Produces:**

```swift
public struct DeviceArtTree: Sendable {
    public let peopleFiles: [String]                  // names in /Artwork/People, hidden files excluded
    public let coverFiles: [String]                   // names in /Artwork/Covers
    public let folderImages: [String: [String]]       // device-relative folder -> image file names in it
    public let foldersWithAudio: Set<String>          // folders that directly hold audio
    public let artistsByFolder: [String: Set<String>] // folder -> folded keys of the artists whose albums lie under it
    public init(peopleFiles:coverFiles:folderImages:foldersWithAudio:artistsByFolder:)
    /// One walk of the music folder and /Artwork, plus the catalog for artistsByFolder. Read-only.
    public static func scan(volumeRoot: URL, musicSubpath: String, catalog: [LoadedTrack],
                            fileManager: FileManager = .default) -> DeviceArtTree
    public static func person(for track: LoadedTrack) -> String?   // album artist, else artist; nil for skipped names
}
public enum PodBoxArtLookup {
    public static let imageExtensions = ["jpeg", "jpg", "bmp", "png", "gif", "webp"]
    /// Device-relative path of the image the player would use, by its three steps. nil = none.
    public static func artistPicture(for name: String, albumFolders: [String], tree: DeviceArtTree) -> String?
}
public struct PodBoxArtworkBudget: Sendable {
    public static let files = 1_900, nameBytes = 44 * 1024, people = 8_192
    public init(existingNames: [String])                           // People + Covers, anyone's
    public var remainingFiles: Int { get }
    public var remainingNameBytes: Int { get }
    public mutating func take(fileName: String) -> Bool            // false when it would exceed either limit
}
```

Pinned details:
- Step 1: a `peopleFiles` entry whose stem `matches` the name and whose extension is in `imageExtensions` → `Artwork/People/<file>`.
- Step 2: for each album folder, that folder and up to three levels above it (never above the music folder): if the folder's own name `matches` the person and it holds `cover.<ext>` or `folder.<ext>` (cover first, extensions in list order) → that image.
- Step 3: the album folder's parent, then grandparent: `cover`/`folder` there, unless `artistsByFolder[folder].count > 1`.
- In steps 2 and 3 a folder in `foldersWithAudio` is skipped entirely: its images are album covers.
- `person(for:)` skips names whose trimmed, case-folded value is `various artists`, `unknown artist`, `<untagged>` or empty.
- Budget: name bytes are counted as UTF-8 length of the full file name plus 1. `take` on a full budget changes nothing and returns false.

- [ ] **Step 1: Failing tests** (trees built in memory; `scan` tested on a `FakeIPod`): `testPeopleFileWins`, `testPeopleFileMatchesByAltKey` (`Herbert, Frank.jpg` for `Frank Herbert`), `testPeopleFileWithWrongExtensionIgnored` (`.txt`), `testArtistFolderImageFoundThroughCategoryLevel` (`Music/Rock/AC-DC/folder.jpg` for `AC/DC` with album folder `Music/Rock/AC-DC/1980 Back in Black`), `testCoverPreferredOverFolder`, `testCategoryFolderWithManyArtistsIgnored` (`Music/Rock/folder.jpg`), `testAlbumCoverInSelfTitledFolderDoesNotBlock` (`Music/Weezer/Weezer/cover.jpg`, audio in it → nil) (Review Focus 2), `testNamedFolderMoreThanThreeLevelsUpIgnored`, `testNeverLooksAboveTheMusicFolder`, `testNoPictureGivesNil`, `testScanBuildsTreeFromFakeIPod` (and `assertPlayerStateUntouched`), `testPersonSkipsVariousAndUnknown`, `testPersonFallsBackToArtist`. Budget: `testCountsExistingFilesOfAnyOwner`, `testStopsAtFileLimit` (1,899 existing: one take succeeds, the next fails), `testStopsAtNameBytes`, `testFailedTakeChangesNothing`.
- [ ] **Step 2 to 4:** fail, implement, filters then full suite pass.
- [ ] **Step 5:** Commit `feat(podbox): simulate the player's artist picture lookup and its artwork cap`.

### Task 4: Preparing a picture (Core-only)

**Depends on:** nothing.

**Files:**
- Create: `Sources/CrateDiggerCore/Services/PodBox/ArtistPictureImage.swift`
- Test: `Tests/CrateDiggerCoreTests/ArtistPictureImageTests.swift`

**Produces:** `ArtistPictureImage.cropRect(for:)`, `prepare(_:)` as in the spec, plus `public static let edge = 400, minimumSource = 300, maximumBytes = 100 * 1024, maximumSourcePixels = 12_000`.

Pinned details: decode with ImageIO using a thumbnail request (`kCGImageSourceThumbnailMaxPixelSize` 1200, transform applied) so a huge source is never fully decoded; read the pixel size from properties first and return nil when the short side is under 300, either side is over 12,000, or the aspect is wider or taller than 2:1. `cropRect`: the largest centred square for landscape and square; for portrait, full width, with the square's top at `(height - width) / 3`. Draw into a 400 × 400 sRGB context with no alpha (white behind transparency), first frame only. Encode JPEG with ImageIO, no metadata dictionary, not progressive, starting at quality 0.85 and stepping down by 0.1 until ≤ 100 KB (floor 0.35; nil if still over).

- [ ] **Step 1: Failing tests** (inputs drawn in the test with CoreGraphics): `testSquareSourceGives400SquareJPEG`, `testOutputIsBaselineNotProgressive` (scan for marker `FF C0`, assert no `FF C2`), `testOutputHasNoEXIF` (no `FF E1` segment), `testOutputAtMost100KB` (noise image), `testPortraitCropIsBiasedToTheTopThird` (`cropRect(600×900)` == `(0, 100, 600, 600)`), `testLandscapeCropIsCentred` (`cropRect(900×600)` == `(150, 0, 600, 600)`), `testTooSmallIsNil` (299 px short side), `testBannerIsNil` (1500×500), `testGiantIsNilWithoutDecoding` (a header claiming 20,000 px; use a small real image and inject the size check via an internal `prepare(_:reportedSize:)`), `testAlphaPNGGetsWhiteBackground`, `testCMYKJPEGBecomesSRGB`, `testAnimatedGIFUsesFirstFrame`, `testZeroBytesAndTruncatedAreNil`, `testSameInputGivesSameBytes` (all Review Focus 4).
- [ ] **Step 2 to 4:** fail, implement, filter then full suite pass.
- [ ] **Step 5:** Commit `feat(podbox): prepare artist pictures as small square JPEGs`.

### Task 5: Picture store and PodBox preferences (Core-only)

**Depends on:** Task 2. Edits `ExternalDeviceProfile.swift` and `LibraryIndexCopy.swift`; both are settled on this branch (duplicates Task 2 is in).

**Files:**
- Create: `Sources/CrateDiggerCore/Services/PodBox/ArtistPictureStore.swift`
- Create: `Sources/CrateDiggerCore/Models/PodBoxPreferences.swift`
- Modify: `Sources/CrateDiggerCore/Models/ExternalDeviceProfile.swift` (one stored property, `CodingKeys`, `init(from:)`, the memberwise `init` with a `nil` default)
- Modify: `Sources/CrateDiggerCore/Services/LibraryIndexCopy.swift` (`LibraryIndexFiles.extensions`)
- Test: `Tests/CrateDiggerCoreTests/ArtistPictureStoreTests.swift`, `PodBoxPreferencesTests.swift`

**Produces:**

```swift
public enum ArtistPictureDestination: String, Codable, Sendable { case off, artworkFolder, artistFolders }
public struct PodBoxPreferences: Codable, Hashable, Sendable {
    public var sweepsAppleDouble: Bool                 // true
    public var artistPictures: ArtistPictureDestination   // .off
    public var findsArtistPicturesAutomatically: Bool  // true
    public var lastSeenFirmware: String?
    public var passedChecks: Set<String>               // "M5", ...
    public init()
}
// ExternalDeviceProfile
public var podBox: PodBoxPreferences?                  // decodeIfPresent
public var podBoxPreferences: PodBoxPreferences { podBox ?? PodBoxPreferences() }

public enum ArtistPictureSourceID: String, Codable, Sendable { case userFile, libraryFolder, deezer, commons, fanartTV, discogs, theAudioDB }
public struct ArtistPictureRecord: Codable, Hashable, Sendable {
    public enum Outcome: String, Codable, Sendable { case found, notFound, uncertain, rejected }
    public var foldedKey: String, displayName: String
    public var outcome: Outcome
    public var source: ArtistPictureSourceID?
    public var sourceID: String?
    public var preparedHash: String?                   // SHA-256 of the exact bytes to write
    public var pickedByUser: Bool
    public var checkedAt: Date
    public func isStale(now: Date) -> Bool             // notFound older than 30 days
}
public final class ArtistPictureStore {
    public static let fileName = "library.cdartists"
    public init(indexDirectory: URL, imageDirectory: URL? = nil, fileManager: FileManager = .default)
    // imageDirectory default: <Application Support>/CrateDigger/ArtistImages
    public func record(forName name: String) -> ArtistPictureRecord?   // by PodBoxArtName.folded
    public func preparedData(for record: ArtistPictureRecord) -> Data?
    public func set(_ record: ArtistPictureRecord, prepared: Data?) throws
    public func allRecords() -> [ArtistPictureRecord]
    public func save() throws
}
```

Pinned details: every member of `PodBoxPreferences` decodes with its default when absent. `LibraryIndexFiles.extensions` gains `cdartists`. The store keys by `PodBoxArtName.folded(name)`, so `The Beatles` and `Beatles` share a record. Prepared bytes live as `<preparedHash>.jpg` in `imageDirectory`; a record whose file is missing returns nil data (the finder then fetches again). `save` writes atomically on the Mac. The store does not check `refuseWhileLibraryDisconnected`; its callers do (Task 11).

- [ ] **Step 1: Failing tests:** `PodBoxPreferencesTests`: `testProfileSavedWithoutPodBoxDecodesNil` (literal JSON of a profile encoded on this branch before the change), `testDefaultsAreOffForPictures`, `testPartialPodBoxObjectDecodesWithDefaults` (`{"artistPictures":"artworkFolder"}`), `testRoundTrip`. `ArtistPictureStoreTests`: `testSetThenRecordByAnySpelling` (`The Beatles` then lookup `Beatles, The`), `testPreparedBytesRoundTrip`, `testMissingImageFileGivesNilData`, `testSaveAndReload`, `testNotFoundIsStaleAfterThirtyDays`, `testRejectedIsNeverStale`, `testIndexFilesIncludeCdartists`.
- [ ] **Step 2 to 4:** fail, implement, filters then full suite pass.
- [ ] **Step 5:** Commit `feat(podbox): artist picture store and per-device PodBox preferences`.

### Task 6: Finding a picture: sources, match rule, finder (Core-only)

**Depends on:** Tasks 2, 4, 5.

**Files:**
- Create: `Sources/CrateDiggerCore/Services/PodBox/ArtistPictureSources.swift` (protocols, candidate, Deezer parser and source, library-folder source)
- Create: `Sources/CrateDiggerCore/Services/PodBox/ArtistPictureFinder.swift` (matcher and finder)
- Test: `Tests/CrateDiggerCoreTests/DeezerArtistParserTests.swift`, `ArtistPictureMatcherTests.swift`, `ArtistPictureFinderTests.swift`, `LibraryFolderPictureSourceTests.swift`

**Produces:**

```swift
public protocol ArtistPictureFetching: Sendable { func data(from url: URL) async throws -> Data }
public struct URLSessionPictureFetcher: ArtistPictureFetching { public init(session: URLSession? = nil) }  // ephemeral, 15 s timeout, User-Agent "CrateDigger", no cookies
public struct ArtistPictureCandidate: Hashable, Sendable {
    public let name: String, source: ArtistPictureSourceID, sourceID: String
    public let imageURL: URL
    public var albumTitles: [String]
}
public enum ArtistPictureSourceError: Error, Equatable { case quota, malformed, http(Int) }
public protocol ArtistPictureSource: Sendable {
    var id: ArtistPictureSourceID { get }
    func candidates(for name: String) async throws -> [ArtistPictureCandidate]      // albumTitles may be empty
    func albumTitles(for candidate: ArtistPictureCandidate) async throws -> [String]
}
public enum DeezerArtistParser {
    public static func artists(_ data: Data) throws -> [ArtistPictureCandidate]     // from search/artist
    public static func albumTitles(_ data: Data) throws -> [String]                  // from artist/<id>/albums
    public static func searchURL(name: String) -> URL                                // https://api.deezer.com/search/artist?q=artist:"<name>"&limit=10
    public static func albumsURL(artistID: String) -> URL                            // https://api.deezer.com/artist/<id>/albums?limit=100
}
public struct DeezerArtistSource: ArtistPictureSource { public init(fetcher: ArtistPictureFetching, spacing: Duration = .milliseconds(200)) }
public struct LibraryFolderPictureSource {
    /// artist.jpg / artist.png / folder.jpg / folder.png in a library folder whose name matches the artist
    /// and whose albums are all that artist's. Returns the file's URL.
    public static func picture(for name: String, albumFolders: [URL], artistsByFolder: [URL: Set<String>],
                               fileManager: FileManager = .default) -> URL?
}
public enum ArtistPictureVerdict: Equatable, Sendable { case confident, uncertain, noMatch }
public enum ArtistPictureMatcher {
    public static func verdict(_ candidate: ArtistPictureCandidate, name: String, deviceAlbumTitles: [String]) -> ArtistPictureVerdict
}
public struct ArtistPictureFinding: Sendable {
    public enum Outcome: Sendable { case found(prepared: Data, candidate: ArtistPictureCandidate?, source: ArtistPictureSourceID),
                                         uncertain([ArtistPictureCandidate]), notFound }
    public let name: String, outcome: Outcome
}
public struct ArtistPictureFinder: Sendable {
    public init(sources: [ArtistPictureSource], fetcher: ArtistPictureFetching,
                perArtist: Duration = .seconds(8), perRun: Duration = .seconds(120))
    /// Serial. Stops early on .quota or when perRun elapses; names not reached are simply absent from the result.
    public func find(_ requests: [(name: String, deviceAlbumTitles: [String], libraryPicture: URL?)]) async -> [ArtistPictureFinding]
}
```

Pinned details:
- Verdict (D2): `noMatch` unless `PodBoxArtName.matches(candidate.name, name)`. `confident` when, in addition, some device album title and some candidate album title are equal after `PodBoxArtName.folded` (which ignores case, accents and punctuation) with any trailing parenthesised or bracketed suffix removed from both first (`OK Computer (Remastered)` equals `OK Computer`). Otherwise `uncertain`.
- Deezer placeholder: `picture_xl` nil, empty, or containing `/images/artist//` → the artist is dropped. `imageURL` is `picture_xl`.
- Deezer error body `{"error":{"code":4,…}}` → `.quota`; any other `error` object or non-JSON → `.malformed`.
- `DeezerArtistSource` backs off 1 s, 2 s, 4 s on `.quota` then rethrows it. The back-off delays are injectable (`init(…, backoff: [Duration])`) so tests pass `[]`.
- Finder order per name: `libraryPicture` if present (prepared from the file; counts as `found`, source `.libraryFolder`, candidate nil); then each source in order: candidates → for each name-matching candidate fetch `albumTitles` if empty → first `confident` one → fetch image → `ArtistPictureImage.prepare`; a nil prepare moves on to the next candidate. No confident hit but name-matching candidates exist → `.uncertain` (at most 5). Nothing → `.notFound`. A thrown non-quota error for one artist counts as `.notFound` for that artist.
- The finder never touches the store or the device.

- [ ] **Step 1: Failing tests** (JSON literals in the tests; a `FakeFetcher: ArtistPictureFetching` mapping URL → `Result<Data, Error>` and recording requests). Parser: `testSingleArtist`, `testSeveralArtists`, `testPlaceholderRejected`, `testEmptyResult`, `testQuotaErrorBody`, `testHTMLBodyThrowsParseError` (Review Focus 3), `testAlbumTitles`, `testSearchURLQuotesAndEncodesTheName` (`AC/DC`, `Björk`). Matcher: `testNameMismatchIsNoMatch`, `testNameMatchWithoutAlbumsIsUncertain`, `testAlbumCrossCheckIsConfident`, `testAlbumSuffixesIgnored`, `testTwoNirvanasOnlyTheOneWithOurAlbumIsConfident`, `testNameMatchUsesThePodBoxFold` (`Beatles, The`). Library source: `testFindsArtistJpgInNamedSingleArtistFolder`, `testIgnoresFolderHoldingSeveralArtists`, `testIgnoresFolderWithOtherName`. Finder: `testLibraryPictureWinsWithoutNetwork` (fetcher records zero requests), `testConfidentCandidateIsFetchedAndPrepared`, `testUncertainWhenNoAlbumMatches`, `testNotFoundWhenNoCandidates`, `testUnusableImageFallsToNextCandidate`, `testQuotaStopsTheRunAndKeepsEarlierResults` (Review Focus 3), `testOneArtistsErrorDoesNotStopTheRun`, `testRunBudgetStopsEarly` (`perRun: .zero` → empty result), `testRequestsCarryOnlyTheArtistName` (every recorded URL's host is `api.deezer.com` or the image host, and no URL contains the home directory name, `/Volumes` or `IPOD`).
- [ ] **Step 2 to 4:** fail, implement, filters then full suite pass.
- [ ] **Step 5:** Commit `feat(podbox): find artist pictures from the library and Deezer, accepting only sure matches`.

### Task 7: Wikimedia Commons source (Core-only)

**Depends on:** Task 6.

**Files:**
- Create: `Sources/CrateDiggerCore/Services/PodBox/CommonsArtistSource.swift`
- Test: `Tests/CrateDiggerCoreTests/CommonsArtistSourceTests.swift`

**Produces:**

```swift
public enum CommonsArtistParser {
    public static func musicBrainzArtists(_ data: Data) throws -> [(id: String, name: String, score: Int)]   // /ws/2/artist?query=…&fmt=json
    public static func wikidataID(fromArtist data: Data) throws -> String?    // /ws/2/artist/<id>?inc=url-rels+release-groups, the "wikidata" relation
    public static func releaseGroupTitles(fromArtist data: Data) throws -> [String]
    public static func imageFileName(fromEntity data: Data, id: String) throws -> String?   // claims.P18[0].mainsnak.datavalue.value
    public static func imageURL(fileName: String, width: Int = 800) -> URL    // https://commons.wikimedia.org/wiki/Special:FilePath/<name>?width=800
}
public struct CommonsArtistSource: ArtistPictureSource {
    public init(fetcher: ArtistPictureFetching, musicBrainzSpacing: Duration = .seconds(1))
}
```

Pinned details: `id == .commons`. `candidates(for:)`: MusicBrainz search (top 3 with score ≥ 90), then for each the artist lookup (which yields both the Wikidata ID and the release-group titles used as `albumTitles`), then the Wikidata entity (`https://www.wikidata.org/wiki/Special:EntityData/<Q>.json`); an artist with no Wikidata relation or no P18 yields no candidate. MusicBrainz calls are at least `musicBrainzSpacing` apart inside this source; the slot is claimed before sleeping. HTTP 503 is retried once after the spacing. `sourceID` is the MusicBrainz artist ID. This source is added to the finder's list after Deezer by Task 11 and used only by the background job and the sheet, never inside a transfer.

- [ ] **Step 1: Failing tests** (JSON literals, `FakeFetcher`, spacing `.zero`): `testMusicBrainzSearchParsesTopArtists`, `testLowScoreArtistsDropped`, `testWikidataRelationFound`, `testNoWikidataRelationGivesNoCandidate`, `testEntityWithoutP18GivesNoCandidate`, `testImageURLEncodesSpacesAndUnicode` (`Björk 2015.jpg`), `testCandidateCarriesReleaseGroupTitles`, `testSpacingBetweenMusicBrainzCalls` (with a 50 ms spacing, two calls' recorded times differ by at least 50 ms), `test503IsRetriedOnce`, `testMalformedJSONThrowsMalformed`.
- [ ] **Step 2 to 4:** fail, implement, filter then full suite pass.
- [ ] **Step 5:** Commit `feat(podbox): artist pictures from Wikimedia Commons via MusicBrainz`.

### Task 8: Picture planner (Core-only)

**Depends on:** Tasks 2, 3, 5; Phase 1 Tasks 2 to 4 (`DeviceWritePolicy` with roles `.artistPicture` and `.artistFolderPicture`, `DeviceWriteJournal.ownedRecord(forKey:)`, `DeviceFileOperation`, `DeviceFileExecutor`), Phase 1 Task 1 (`FakeIPod`).

**Files:**
- Create: `Sources/CrateDiggerCore/Services/PodBox/ArtistPicturePlanner.swift`
- Test: `Tests/CrateDiggerCoreTests/ArtistPicturePlannerTests.swift`

**Produces:**

```swift
public struct ArtistOnDevice: Hashable, Sendable {
    public let name: String, foldedKey: String
    public let albumFolders: [String]          // device-relative
    public let albumTitles: [String]
    public let trackCount: Int
    public static func all(in catalog: [LoadedTrack], volumeRoot: URL) -> [ArtistOnDevice]   // one per key, most tracks first; name = the most common spelling
}
public struct ArtistPicturePlan: Sendable {
    public let operations: [DeviceFileOperation]
    public let alreadyHasPicture: [String], noPictureYet: [String], overBudget: [String], unnameable: [String], foreign: [String]
}
public enum ArtistPicturePlanner {
    public static func plan(artists: [ArtistOnDevice], tree: DeviceArtTree,
                            prepared: [String: Data],               // folded key -> exact bytes
                            destination: ArtistPictureDestination,
                            ownedKeys: (String) -> DeviceFileRecord?,   // journal.ownedRecord(forKey:)
                            sha256OnDevice: (String) -> String?)        // device-relative path -> hash of the file there now
        -> ArtistPicturePlan
    /// Journal-owned picture files still matching their hash, as deletes.
    public static func removalPlan(journalRecords: [DeviceFileRecord], sha256OnDevice: (String) -> String?) -> [DeviceFileOperation]
}
```

Pinned details:
- `.off` → no operations, every artist in `noPictureYet`.
- Per artist, most tracks first: no prepared bytes → `noPictureYet`. `PodBoxArtName.fileStem` nil → `unnameable`. `PodBoxArtLookup.artistPicture` finds a file: if the journal owns it and the hash on the device equals the record's, it is ours (identical bytes → no operation; different prepared bytes → a replacing write to the same path); if the journal owns it but the hash differs → `foreign`; otherwise → `alreadyHasPicture`.
- Target, `.artworkFolder`: `Artwork/People/<stem>.jpg`, role `.artistPicture`, subject to `PodBoxArtworkBudget(existingNames: tree.peopleFiles + tree.coverFiles)`. A failed `take` → for an artist with a qualifying artist folder, fall through to the folder target; else `overBudget`.
- Target, `.artistFolders`: the album folder's parent when its name `matches` the artist, it is not in `foldersWithAudio`, `artistsByFolder` holds only this artist, and it holds no `cover.*` or `folder.*` image: `<folder>/folder.jpg`, role `.artistFolderPicture`. No such folder → the `.artworkFolder` target.
- Two names with one key never produce two operations. Operations are sorted by path. Never more than 8,192 people.

- [ ] **Step 1: Failing tests** (`FakeIPod`, real journal in a temp dir; apply plans through `DeviceFileExecutor` with the two roles enabled; each ends with `assertPlayerStateUntouched`): `testWritesToArtworkPeople`, `testFileNameKeepsThePodBoxKey` (`AC/DC` → `Artwork/People/AC-DC.jpg`, and `PodBoxArtLookup.artistPicture` then finds it), `testTwoNamesOneKeyPlanOneFile` (`Björk`, `Bjork`) (Review Focus 1), `testZeroKeyNameIsUnnameable` (`!!!`) (Review Focus 1), `testVariousArtistsNeverPlanned`, `testOwnersPeopleFileBlocksOurs` (Review Focus 5), `testOwnersArtistFolderImageBlocksOurs`, `testOurPictureEditedOnDeviceIsNotReplaced` (write ours, overwrite its bytes on the fake device, replan with new prepared bytes → `foreign`, zero operations; and the executor would refuse anyway) (Review Focus 5), `testOurUnchangedPictureIsReplacedWhenThePickChanges`, `testReplanWithEverythingPresentIsEmpty`, `testOffPlansNothing`, `testBudgetOverflowGoesToArtistFolderThenReports` (1,899 existing People files, three artists), `testOrderIsMostTracksFirstUnderBudget`, `testArtistFoldersModeFallsBackToPeopleUnderACategoryOfMany`, `testArtistFolderWithExistingImageIsNotUsed`, `testRemovalPlanOnlyOwnedAndUnedited`, `testArtistsOnDeviceGroupsSpellingsByKey`.
- [ ] **Step 2 to 4:** fail, implement, filter then full suite pass.
- [ ] **Step 5:** Commit `feat(podbox): plan artist pictures without shadowing the owner's`.

### Task 9: PodBox folder layout preset (Core-only)

**Depends on:** Task 2 (for one test).

**Files:**
- Create: `Sources/CrateDiggerCore/Services/PodBox/PodBoxLayout.swift`
- Modify: `Sources/CrateDiggerCore/Services/OutputPathPlanner.swift` only if `testMissingYearLeavesNoLeadingSpace` fails
- Test: `Tests/CrateDiggerCoreTests/PodBoxLayoutTests.swift`

**Produces:**

```swift
public enum RockboxLayoutPreset: String, Codable, CaseIterable, Sendable {
    case podBoxRecommended, artistAlbum, custom
    public var title: String                    // "PodBox recommended", "Artist / Album", "Custom"
    public var caption: String                  // "Artist / 2010 Album", "Artist / Album", "Set in the transfer panel"
    public var template: FolderTemplateConfig?  // nil for .custom
    public static func matching(_ config: FolderTemplateConfig) -> RockboxLayoutPreset
}
public enum PodBoxFolderYear { public static func parse(_ folderName: String) -> Int? }
public enum PodBoxDiscFolder { public static func isDiscFolder(_ name: String) -> Bool }
public enum PodBoxLayoutNotes {
    /// Folder names the player would read with a year the tag does not carry. (folder, parsedYear, tagYear)
    public static func misreadYears(plannedAlbumFolders: [(folder: String, tagYear: Int?)]) -> [(folder: String, parsed: Int, tag: Int?)]
}
```

Pinned details:
- `.podBoxRecommended.template` = `FolderTemplateConfig(preset: .custom, tokenOrder: [.albumArtist, .year, .album, .disabled, .disabled], separators: [.slash, .space])`. `.artistAlbum.template` = `preset: .custom, tokenOrder: [.albumArtist, .album, .disabled, .disabled, .disabled]`, no separators (what `ExternalDeviceProfile.rockboxIPod()` builds today).
- `matching`: equal token order and effective separators → that preset; anything else `.custom`.
- `PodBoxFolderYear.parse`: the first four characters are ASCII digits forming 1900…2099 and the fifth character, if any, is not an ASCII digit.
- `PodBoxDiscFolder`: case-insensitive `cd`, `disc` or `disk`, then zero or more of space, `-`, `_`, `.`, then one or more ASCII digits, then nothing.
- `misreadYears` lists a folder (last path component) when `parse` gives a year different from `tagYear` (nil counts as different).
- No profile is changed by this task. `ExternalDeviceProfile.rockboxIPod()` keeps its template.

- [ ] **Step 1: Failing tests:** `testRecommendedTemplatePlansArtistYearAlbum` (through `OutputPathPlanner` with album artist `Beach House`, year 2010, album `Teen Dream`, music root `Music` → folder `Music/Beach House/2010 Teen Dream`), `testMissingYearLeavesNoLeadingSpace` (→ `Music/Beach House/Teen Dream`), `testArtistFolderKeyEqualsTagKey` (`PodBoxArtName.key` of the planned artist folder name equals the key of `AC/DC`, `Björk`, `Simon & Garfunkel`), `testMatchingRoundTrips` (both presets), `testMatchingUnknownIsCustom`, `testYearParse` (`2010 Teen Dream` → 2010; `1106 Blue Weekend` → nil; `20101 Album` → nil; `1999` → 1999; `2100 X` → nil; `199` → nil), `testDiscFolders` (`CD1`, `Disc 2`, `disk_3`, `disc-04` yes; `Disc 1 of 2`, `Disco`, `CD`, `Disc A` no), `testMisreadYears` (album titled `1984` with tag year 1984 → none; tag year nil → listed; `1999` with tag 1982 → listed), `testExistingRockboxFactoryTemplateIsUnchanged`.
- [ ] **Step 2:** Run, see failures. If `testMissingYearLeavesNoLeadingSpace` fails after `PodBoxLayout.swift` exists, fix the separator handling in `OutputPathPlanner` so a separator beside an empty token is dropped, and run `scripts/test.sh --filter OutputPathPlannerTests`.
- [ ] **Step 3 and 4:** Implement; filter then full suite pass.
- [ ] **Step 5:** Commit `feat(podbox): a folder layout preset PodBox reads best`.

### Task 10: Readiness notes and cover guarantees (Core-only)

**Depends on:** Tasks 1, 2; Phase 1 Task 1 (`DeviceFirmware`).

**Files:**
- Create: `Sources/CrateDiggerCore/Services/PodBox/PodBoxAdvisor.swift`
- Modify: `Sources/CrateDiggerCore/Services/FolderCoverArtWriter.swift` only if a guarantee test fails
- Test: `Tests/CrateDiggerCoreTests/PodBoxAdvisorTests.swift`, extend `Tests/CrateDiggerCoreTests/FolderCoverArtWriterTests.swift` (create if absent)

**Produces:**

```swift
public struct PodBoxNote: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case macFiles, artistArtOff, musicNotScanned, playLogOff, unnameableArtists,
                                              pathTooLong, compilationWithoutAlbumArtist, embeddedArtOnly, newerLayout, notBooted }
    public let kind: Kind, text: String, items: [String], menuPath: String?
    public var id: String { kind.rawValue }
}
public enum PodBoxAdvisor {
    public static func deviceNotes(catalog: [LoadedTrack], firmware: DeviceFirmware, musicSubpath: String, volumeRoot: URL) -> [PodBoxNote]
}
```

Pinned copy (`text`, then `menuPath`):
- `macFiles` (count > 0): `PodBox is reading <N> Mac files as music.`
- `artistArtOff`: `Artist pictures are switched off on this iPod.` / `Settings ▸ Library ▸ Art Cache`
- `musicNotScanned` (scan paths not `/` and none is a prefix of `/<musicSubpath>`): `This iPod only scans <paths>. Music in /<musicSubpath> will not appear.`
- `playLogOff`: `The play log is off on this iPod, so plays cannot be imported.`
- `unnameableArtists`: `PodBox cannot match a picture to <N> artist names.` items = names
- `pathTooLong` (`!FATName.fitsPlayerPath`): `<N> files have paths too long for the player.` items = paths
- `compilationWithoutAlbumArtist` (an album folder whose tracks carry more than one artist and no album artist): `<N> compilations have no album artist and will be split by artist.` items = folders
- `embeddedArtOnly` (`art cache album source` value contains `embedded` and not `image`): `This iPod is set to use embedded covers only.` / `Settings ▸ Library ▸ Art Cache ▸ Album Art Source`
- `newerLayout`, `notBooted`: the two messages from the spec's capability table.
- Order as listed; stock or unknown Rockbox gets only `macFiles` and `pathTooLong`.

Cover guarantees: `FolderCoverArtWriter` output is baseline (no `FF C2` marker) and at most 512 KB; if the size test fails, re-encode at lower quality inside the writer.

- [ ] **Step 1: Failing tests:** one per note kind present and one absent (`testMacFilesNote`, `testNoMacFilesNoteAtZero`, `testArtistArtOff`, `testMusicOutsideScanPaths`, `testScanRootCoversEverything`, `testPlayLogOff`, `testUnnameableArtistsListed`, `testLongPathListed`, `testCompilationWithoutAlbumArtist`, `testCompilationWithAlbumArtistIsFine`, `testEmbeddedOnly`, `testNewerLayout`, `testNotBooted`, `testStockRockboxGetsOnlyGenericNotes`, `testNoEmDashInAnyText`). Cover: `testCoverIsBaselineJPEG`, `testCoverFromNoiseSourceIsUnder512KB`.
- [ ] **Step 2 to 4:** fail, implement, filters then full suite pass.
- [ ] **Step 5:** Commit `feat(podbox): readiness notes for a PodBox iPod`.

### Task 11: Pictures after a transfer, removal, reminder (wiring)

**Needs from Phase 1:** Task 8 (`deviceFirmware`, `capabilities(for:)`, `devicePolicy(for:firmware:)`, `isMatchedByUUID`), Task 10 (`finishDeviceSession`, `ejectDevice`). **Needs from the duplicates plan:** Task 5 (`currentDeviceCatalog(for:)`, `patchDeviceCatalog`), which `finishDeviceSession` already follows. Start only when Phase 1 Task 10 is on this branch.

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/ExternalDevices/LibraryViewModel+PodBox.swift`
- Create: `Sources/CrateDiggerApp/UI/ExternalDevices/LibraryViewModel+ArtistPictures.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` (stored `artistPictureStore`, `@Published var deviceNotes`, `@Published var pendingIPodStep`)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Header/OLEDDisplay.swift` (`DevicesPane` ticker)
- Create: `Sources/CrateDiggerCore/Services/PodBox/ArtistPictureSession.swift` + `Tests/CrateDiggerCoreTests/ArtistPictureSessionTests.swift`

**Produces:**

```swift
// Core: everything decidable about one run, so the view model only calls it.
public enum ArtistPictureSession {
    public struct Inputs: Sendable { artists: [ArtistOnDevice], tree: DeviceArtTree, destination: ArtistPictureDestination,
                                     automatic: Bool, matchedByUUID: Bool, hasCapability: Bool, passedM5: Bool }
    /// Names worth looking up now: no fresh store record, no picture the player already finds.
    public static func namesToFind(_ inputs: Inputs, store: ArtistPictureStore, now: Date) -> [ArtistOnDevice]
    /// Whether a transfer may write pictures at all, and the reason when not (for the summary line).
    public static func mayWrite(_ inputs: Inputs, trigger: DeviceSessionTrigger) -> (allowed: Bool, reason: String?)
    public static func record(from finding: ArtistPictureFinding, now: Date) -> (ArtistPictureRecord, Data?)
    public static func summaryLine(written: Int, plan: ArtistPicturePlan) -> String?
}
// View model
func writeArtistPictures(device: MountedDevice, profile: ExternalDeviceProfile, findMissing: Bool) async -> (written: Int, line: String?)
func removeArtistPicturesCrateDiggerAdded(profileID: UUID)
func refreshDeviceNotes(for device: MountedDevice)
```

Behaviour:
- `mayWrite`: needs `destination != .off`, `hasCapability` (`centralPeopleArtwork`), `matchedByUUID`, and `DeviceSessionGate.allows(.writeExtras, trigger:, matchedByUUID:)`. Inside a transfer (automatic) it also needs `passedM5`. Reasons, exact: `Artist pictures are off for this device.`, `This device is not PodBox.`, `Artist pictures need a device matched by its volume ID.`, `Artist pictures wait for the M5 check on this iPod.`
- `finishDeviceSession` (Phase 1) gains a step after the scoped sweep: when `mayWrite` allows, call `writeArtistPictures(findMissing: profile.podBoxPreferences.findsArtistPicturesAutomatically)`; add `.pictures` to the changes when anything was written; append its line. Failure never fails the transfer.
- `writeArtistPictures`: catalog → `ArtistOnDevice.all` → `DeviceArtTree.scan` → optional `ArtistPictureFinder` (library-folder source, then Deezer only; Commons is not used inside a transfer) → store updates (`guard !refuseWhileLibraryDisconnected()` around the store write; when the library is disconnected, skip finding and use what the store already holds) → `ArtistPicturePlanner.plan` → `DeviceFileExecutor.apply` with the policy's `enabledRoles` extended by `.artistPicture`, `.artistFolderPicture`.
- Summary line: `Wrote <N> artist pictures.` plus `, <M> already had one` / `, <K> waiting for a pick` (uncertain or not found) / `, <J> did not fit` as each is non-zero; nil when nothing was written and nothing is waiting.
- Removal: `ArtistPicturePlanner.removalPlan` applied through the executor, then the next-step lines for `.pictures`.
- Reminder: after a session that changed covers or pictures on PodBox, set `pendingIPodStep = "NEXT ON IPOD · UPDATE ART CACHE"` and remember the write time per profile in `UserDefaults` via `PreferencesStore` (key `podBoxLastArtWrite.<profileID>`); `DevicesPane`'s ticker shows it. On each mount, `stat` (never open) `.rockbox/library/cache/art/stamps.dat` and clear it when `PodBoxNextSteps.isDone`.
- `refreshDeviceNotes` runs after the probe and after each session, off the main actor, read-only.

- [ ] **Step 1: Failing Core tests** `ArtistPictureSessionTests`: `testMayWriteReasonsInOrder` (one per reason), `testTransferNeedsM5ButExplicitActionDoesNot`, `testMountNeverWrites`, `testNamesToFindSkipsFreshNotFound`, `testNamesToFindRetriesStaleNotFound`, `testNamesToFindSkipsRejectedAndFound`, `testNamesToFindSkipsArtistsThePlayerAlreadyFinds`, `testRecordFromFoundCarriesHashOfPreparedBytes`, `testRecordFromUncertainKeepsNoImage`, `testSummaryLineVariants`, `testSummaryLineHasNoEmDash`.
- [ ] **Step 2:** Implement Core, then the view model.
- [ ] **Step 3:** `swift build`; full `scripts/test.sh` passes.
- [ ] **Step 4:** Commit `feat(podbox): write artist pictures after a transfer and remind about the art cache`.

### Task 12: Artist Pictures sheet and Preferences rows (wiring)

**Needs from this plan:** Tasks 9 and 11. **Needs from the duplicates plan:** Task 8 (its edits to `DevicesPreferencesView.swift`: the Artwork control and Folder art toggle; build on that file as it stands after that task) and Task 4 (`DeviceReviewSheetController` as the pattern for an `NSViewController` hosting SwiftUI with `onDecision`).

**Files:**
- Create: `Sources/CrateDiggerApp/UI/ExternalDevices/ArtistPicturesSheetController.swift`
- Create: `Sources/CrateDiggerCore/Services/PodBox/ArtistPictureRow.swift` + `Tests/CrateDiggerCoreTests/ArtistPictureRowTests.swift`
- Modify: `Sources/CrateDiggerApp/UI/ExternalDevices/DevicesPreferencesView.swift`, `LibraryViewModel+ArtistPictures.swift`, `Sources/CrateDiggerApp/UI/Carbon/Main/SourcesSidebar.swift` (device row context menu), the file that holds `LibraryPresentations`

**Produces (Core):**

```swift
public struct ArtistPictureRow: Identifiable, Hashable, Sendable {
    public enum State: String, Sendable { case onDevice, ready, check, none, rejected, unnameable }
    public let id: String                      // folded key
    public let name: String, trackCount: Int
    public let state: State
    public let badge: String                   // "DEVICE", "DISK", "DEEZER", "COMMONS", "PICKED", "CHECK", "NONE", "NO PICTURE"
    public static func rows(artists: [ArtistOnDevice], tree: DeviceArtTree, store: ArtistPictureStore,
                            uncertain: [String: [ArtistPictureCandidate]]) -> [ArtistPictureRow]
    public static func canApply(_ rows: [ArtistPictureRow]) -> Bool    // at least one .ready
}
```

Behaviour:
- **Artist Pictures…** (device row context menu, Preferences ▸ Devices): a sheet presented from `LibraryPresentations`, a grid of the device's artists, most tracks first, each cell showing the current picture (device, store, or an empty well), the badge, and for `check` rows the candidates. Per artist: Accept (a candidate), Choose File…, No Picture (stored as `rejected`), Clear. A **Find Missing** button runs the finder with all sources (library, Deezer, Commons) as a `scan` busy job with progress and Cancel. **Apply** writes accepted pictures to the store and, when mounted, UUID matched and `artistPictures != .off`, to the device through `writeArtistPictures(findMissing: false)`; otherwise the footer says `Pictures are saved and will be written when artist pictures are on for this device.`
- A picked file goes through `ArtistPictureImage.prepare`; nil shows `That image is too small or the wrong shape. Use one at least 300 pixels on its short side.`
- DEBUG hook `CRATEDIGGER_ARTIST_PICTURES=1`: opens the sheet with twelve made-up rows covering every state, no device and no network.
- Preferences ▸ Devices, for a `rockboxIPod` profile, a new section **On the iPod**: `Artist pictures` picker (Off / In /Artwork/People / In artist folders) with the caption `Run the M5 check before turning this on.` until `passedChecks` contains `M5`; a `Verified on this iPod (M5)` toggle that adds or removes `M5`; `Find missing artist pictures automatically` toggle; `Artist Pictures…` button; `Remove artist pictures CrateDigger added` button (confirm first). Rows are hidden when the mounted device lacks `centralPeopleArtwork`; when the device is not mounted they show, disabled where they need it.
- Same view, Transfer section: a **Folder layout** picker over `RockboxLayoutPreset.allCases` with the preset's caption. It reads `RockboxLayoutPreset.matching(profile.transferSettings.templateConfig)`. Choosing a preset other than Custom sets `templateConfig` to its template, after a confirmation for a profile that already has a device catalog: `New albums will use this layout. Albums already on the device stay where they are.` Creating a new profile for a device whose probe says PodBox seeds `.podBoxRecommended`; every other new profile and every existing profile is unchanged.
- The readiness notes from `deviceNotes` appear as captions at the top of the On the iPod section.
- The sheet's look is the owner's to approve from a real capture; build a clear first version.

- [ ] **Step 1: Failing Core tests** `ArtistPictureRowTests`: `testRowForPictureAlreadyOnDevice`, `testRowReadyFromStore`, `testRowCheckWhenUncertain`, `testRowNoneWhenNothingKnown`, `testRowRejected`, `testRowUnnameable`, `testBadgesBySource`, `testRowsSortedByTrackCount`, `testCanApplyNeedsAReadyRow`.
- [ ] **Step 2:** Implement Core, then the sheet, the Preferences rows and the hook.
- [ ] **Step 3:** `swift build`; full `scripts/test.sh` passes.
- [ ] **Step 4:** Launch with a scratch crates dir and `CRATEDIGGER_ARTIST_PICTURES=1`, capture the sheet with `screencapture -l <windowID>` to `.build/podbox/artist-pictures.png`; open Preferences ▸ Devices and capture it too. Read both PNGs, fix layout defects, `pkill -f CrateDiggerApp`. Do not press Find Missing (network) or Apply in this check, and do not attach a profile to `/Volumes/IPOD`.
- [ ] **Step 5:** Commit `feat(podbox): Artist Pictures sheet, device preferences and layout preset picker`.

### Task 13: Docs

**Needs:** Tasks 11 and 12.

**Files:** `CLAUDE.md` (extend the PodBox subsection: `PodBoxArtName` is a port of the player's fold and is not `DeviceAlbumIdentity.fold`; pictures are planned against `PodBoxArtLookup` so the owner's are never shadowed; the `/Artwork` budget; `library.cdartists` in `LibraryIndexFiles`; the M5 gate; the layout preset only seeds new PodBox profiles; the two DEBUG hooks; add `+ArtistPictures` to the extension list and correct the count), `CHANGELOG.md` (`## 2.3.4`: artist pictures for PodBox, the Artist Pictures sheet, the PodBox folder layout, readiness notes), the spec only where a built name differs from it.

- [ ] **Step 1:** Write. **Step 2:** Full `scripts/test.sh` passes. **Step 3:** Commit `docs: PodBox artist pictures and folder layout`.

---

## After this plan

The owner runs M5 (and notes M12) from the spec on the real iPod, then turns `Verified on this iPod (M5)` on. No agent runs it.
