# PodBox Phase 1 (Recognise PodBox, Guard Every Write, Stop the Junk) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A mounted PodBox iPod is identified with its model, build and library layout; every byte CrateDigger writes to or deletes from a device passes one guarded door; macOS `._` files stop being created and proven ones can be removed; the user is told the next step on the iPod and can eject.

**Architecture:** New Core types only, in `Services/DeviceFiles/` (policy, IO primitives, journal, executor, AppleDouble sweep, session gate) and `Services/PodBox/` (firmware probe, next steps), each pure or driven by an injected `FileManager` and proven on a temp-dir `FakeIPod`. A new `LibraryViewModel+PodBox.swift` wires the probe at mount, routes the existing device copy sites through the door, and ends every device write with `finishDeviceSession`.

**Tech Stack:** Swift, SwiftPM, XCTest (`scripts/test.sh`), Darwin `copyfile`/`listxattr`/`rename`, AppKit + SwiftUI.

**Spec:** `docs/superpowers/specs/2026-11-11-podbox-integration-design.md`. Read "Safety", "Manual checks" and "Phase 1" before any task. The spec's Phase 1a code blocks are the signatures; this plan only adds what they leave open. Facts about the device are in `.superpowers/podbox-research.md` ("the brief") in the `device-duplicates` worktree's copy of the repo and are quoted here where a test needs them.

## Global Constraints

- Work only in the podbox worktree (`/Volumes/EX_3/Code/CrateDigger/.claude/worktrees/podbox`, branch `feat/podbox`). Never `cd` to another checkout.
- Never push/tag/bump versions.
- A real iPod is mounted at /Volumes/IPOD. Never write, rename or delete anything under /Volumes outside this repo, and never run the app's transfer, cleanup or picture-writing against a real device. Tests use temp directories or the FakeIPod fixture.
- Build with `swift build`, test with `scripts/test.sh --filter <Class>`, full `scripts/test.sh` green before each commit.
- Commit messages end with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`. Stage only files you changed.
- No em dashes in user-facing copy.
- Network code is behind a protocol with a fake in tests and tests never hit the network. (Phase 1 has no network code. Do not add any.)
- No personal data in requests to outside services.
- Decidable logic lives in `CrateDiggerCore` with an XCTest; view-model code only wires.
- The spec's invariants I1 to I12 bind every task. In particular: nothing under `.rockbox`, `.rockbox_backup`, `.backup`, `iPod_Control`, `.Trashes`, `.Spotlight-V100`, `.fseventsd` is ever written or deleted, and mounting a device only reads.
- Tasks 1 to 7 create new files only. They must not edit any existing source file (the duplicates work is still changing `ExternalDeviceProfile.swift`, `FolderCoverArtWriter.swift` and the `UI/ExternalDevices` files). Tasks 8 to 11 are wiring and state what they need first.
- Fixtures are literals in the test source. Nothing is read from the real iPod to build a test.
- When launching the app, set `CRATEDIGGER_CRATES_DIR` to a scratch folder. Do not launch it with `CRATEDIGGER_PODBOX_DRYRUN` pointed at `/Volumes/IPOD`; that is the owner's check M1.

## Review Focus

1. **FAT aliases of a denied folder.** FAT drops trailing dots and spaces and ignores case, so `.rockbox.`, `.ROCKBOX` and `.rockbox ` are the player's folder. Expected: refused. Test: `testDeniesTrailingDotSpaceAndCaseAliases` (Task 2).
2. **A symlink or `..` that leads out of the allowed area** (an exFAT or HFS device can hold symlinks). Expected: refused before any IO. Tests: `testDeniesTraversalAndAbsolutePaths` (Task 2), `testSymlinkOutOfMusicFolderIsRefused` (Task 4).
3. **The device disappears mid-session** (cable pulled, wrong iPod plugged back). Expected: remaining operations report `refusedWrongVolume` or `failed`, nothing crashes, no temp file is left on a root that still exists. Tests: `testVolumeChangedBetweenPlanAndApplyRefusesEverything`, `testRootVanishedMidApplyFailsRemainingOps` (Task 4).
4. **A journal cut off mid-line by a crash.** Expected: good lines load, the broken tail is ignored, the files it described read as not ours. Test: `testTruncatedLastLineIsIgnoredAndOwnershipFailsSafe` (Task 3).
5. **Garbage where the probe expects text** (binary `rockbox-info.txt`, a 5 MB `config.cfg`, a 3-byte `format.dat`, CRLF). Expected: a `DeviceFirmware` with nils, never a throw or a hang. Tests: `testGarbageFilesNeverThrow`, `testOversizeConfigIsCapped` (Task 1).

---

### Task 1: FakeIPod, firmware model and probe (Core-only)

**Files:**
- Create: `Tests/CrateDiggerCoreTests/FakeIPod.swift`
- Create: `Sources/CrateDiggerCore/Models/DeviceFirmware.swift`
- Create: `Sources/CrateDiggerCore/Services/PodBox/DeviceFirmwareProbe.swift`
- Test: `Tests/CrateDiggerCoreTests/DeviceFirmwareProbeTests.swift`, `DeviceCapabilitiesTests.swift`, `FakeIPodTests.swift`

**Interfaces, Produces:** every type in the spec's first Phase 1a code block (`RockboxFlavour`, `RockboxBuildInfo`, `PodBoxConfig`, `PlayLogMode`, `DeviceFirmware`, `DeviceCapabilities`, `DeviceFirmwareProbe`), with `DeviceFirmware.knownLayout = 5` as a static on `DeviceFirmware`, plus:

```swift
// Test target only
final class FakeIPod {
    let root: URL                                   // a fresh temp dir; removed in deinit
    enum Flavour { case podBox(layout: UInt16), podBoxNotBooted, stockRockbox, unknownRockbox, noRockbox }
    init(flavour: Flavour = .podBox(layout: 5), musicSubpath: String = "Music") throws
    @discardableResult func addAlbum(category: String?, artist: String, folder: String,
                                     tracks: [String], cover: Bool = true, appleDoubleTwins: Bool = false) throws -> URL
    @discardableResult func addFile(_ relativePath: String, _ data: Data) throws -> URL
    static func appleDoubleBytes(size: Int = 4096) -> Data   // 00 05 16 07 00 02 00 00, then zero padding
    func manifest() throws -> [String: String]               // protected trees: relative path -> "size:sha256:mtime"
    func assertPlayerStateUntouched(since before: [String: String], file: StaticString = #filePath, line: UInt = #line)
}
```

Pinned details:
- `FakeIPod(.podBox)` writes: `.rockbox/library/format.dat` (the 28 bytes `4c 59 4f 54 05 00 01 00 00 00 00 00` then sixteen `ff`, with the layout bytes from the parameter), `.rockbox/rockbox-info.txt` and `.rockbox/config.cfg` (the brief's verbatim texts, below), `.rockbox/default-config.cfg` (`database artist art: on\ndatabase album art: on\n`), `.rockbox/trim.config`, `.rockbox/docs/settings-help.txt`, `.rockbox/library/database/database_idx.tcd`, `.rockbox/library/user/plays.dat`, `.rockbox/library/user/playback.log` (the brief's 224-byte sample), `.rockbox/library/user/player_name.txt` (`PodBox`), `.rockbox/library/cache/unreadable.txt`, `.rockbox/library/cache/art/stamps.dat`, `.rockbox_backup/x.txt`, `.backup/x.zip`, `iPod_Control/iTunes/iTunesDB`, `Playlists/Pl.m3u8` (UTF-8 BOM + `/<HDD0>/Music/Classics/David Gilmour/2008 Live in Gdańsk/02 - Wearing the Inside Out.m4a\n`). `.podBoxNotBooted` omits `library/`. `.stockRockbox` has `.rockbox/rocks/` and `.rockbox/rockbox-info.txt` only. `.unknownRockbox` has an empty `.rockbox/`.
- Protected trees for `manifest()`: `.rockbox`, `.rockbox_backup`, `.backup`, `iPod_Control`, plus the root file `.scrobbler.log` when present.
- `rockbox-info.txt` literal: `Target: ipodvideo\nTarget id: 15\nTarget define: -DIPOD_VIDEO\nMemory: 64\nCPU: arm\nManufacturer: ipod\nVersion: -261108\nBinary: rockbox.ipod\nFeatures: albumart:tagcache:usbstack\n`.
- `config.cfg` literal: first line `# .cfg file created by rockbox -261108 - http://www.rockbox.org`, blank line, then `statusbar: off`, `theme: /.rockbox/themes/scrim.cfg`, `database artist art: on`.
- `playback.log` literal: `# Started Ver. -261108 / Time 261111-222243\n1794435900:28746:291757:/<HDD0>/Music/Classics/Beach House/2010 Teen Dream/01 - Zebra.m4a\n1794436675:33158:291757:/<HDD0>/Music/Classics/Beach House/2010 Teen Dream/01 - Zebra.m4a\n`.
- `PodBoxConfig` defaults table: `play log` = `on`, `playlist catalog directory` = `/Playlists`, `database scan paths` = `/`, `year from folder` = `off`, `skip ipod games` = `on`, `database artist art` = `on`, `database album art` = `on`, `featured artists` = `off`, `playlist engine` = `off`. `playlistDirectory` strips the leading `/`. Layers: table, then `default-config.cfg`, then `config.cfg`. Duplicate key: last wins.
- `RockboxBuildInfo.modelName`: `ipodvideo` → `iPod Video`, `ipod6g` → `iPod Classic`, other → `iPod (<target>)`, nil → `iPod`.
- `buildDate` parses a trailing `-YYMMDD` as 20YY; `-261108` → year 2026, month 11, day 8, `gitHash == nil`. `abc1234-250101` → hash `abc1234`. `v4.0`, `unknown` → no date.
- `summaryLine`: `PodBox · iPod Video · build 8 Nov 2026 · library layout 5`; not booted → `PodBox, not started yet · iPod Video`; stock or unknown → `Rockbox · <model>`; date formatted `d MMM yyyy` in `en_US_POSIX`.
- `probe` read caps: 28 bytes, 16 KB, 64 KB per config, 256 KB `unreadable.txt`, first 64 KB of the first `*.m3u8` in the playlist folder and of `playback.log`, first 4 KB of `.rockbox/.playlist_control`. Opens with `FileHandle(forReadingFrom:)` only. Ignores `config.cfg.new`.
- `playerPathPrefix`: first line matching `^/<[A-Z]+[0-9]+>/`, returned without the trailing slash; log lines are searched after their third colon, `.playlist_control` lines after `P:<n>:`.
- `appleDoubleCount`: lines whose last path component starts with `._`.
- `DeviceCapabilities.init(firmware:fileSystem:)`: the spec's capability table; `lyricsSidecar` and `playbackLogImport` only for PodBox layout exactly 5 (layout above 5 keeps `centralPeopleArtwork` and `coverSidecar`, loses `playbackLogImport`); `playlistCatalog` needs a non-nil prefix and a playlist directory whose first component is not a denied tree name.

- [ ] **Step 1: Failing tests.** `FakeIPodTests`: `testManifestCoversProtectedTreesOnly`, `testAssertUntouchedFailsWhenARockboxFileChanges` (use `XCTExpectFailure`), `testAppleDoubleBytesHaveMagicAndVersion`. `DeviceFirmwareProbeTests`: `testRealFormatDatGivesLayoutFive`, `testChecksumIsNotVerified`, `testShortEmptyAndWrongMagicGiveNil`, `testBuildInfoFromDeviceText` (target `ipodvideo`, version `-261108`, date 2026-11-08, model `iPod Video`), `testStockVersionForms`, `testCRLFAndUnknownKeysTolerated`, `testConfigLayering` (default-config `database artist art: on` overridden by config `off`), `testConfigDefaultsWhenKeysAbsent` (`playLogMode == .on`, `playlistDirectory == "Playlists"`), `testPrefixFromPlaylistLine`, `testPrefixFromLogLine`, `testPrefixFromPlaylistControlLine` (all `/<HDD0>`), `testNoPrefixWhenAbsent`, `testFlavourPodBox`, `testFlavourNotBooted`, `testFlavourStock`, `testFlavourUnknown`, `testNoRockboxGivesNil`, `testAppleDoubleCountFromUnreadableText` (three lines, two `._`, expect 2), `testProbeOfFakeIPodSummaryLine` (`PodBox · iPod Video · build 8 Nov 2026 · library layout 5`), `testProbeLeavesPlayerStateUntouched`, `testGarbageFilesNeverThrow`, `testOversizeConfigIsCapped` (Review Focus 5). `DeviceCapabilitiesTests`: one test per row of the spec's table, plus `testNoPlaylistCapabilityWithoutPrefix`, `testPlaylistFolderInsideRockboxGivesNoCapability`, `testLayoutSixKeepsFileFeaturesLosesReadBack`.
- [ ] **Step 2:** `scripts/test.sh --filter DeviceFirmwareProbeTests` fails to compile.
- [ ] **Step 3:** Implement the three source files and the helper.
- [ ] **Step 4:** The three filters pass; full `scripts/test.sh` passes.
- [ ] **Step 5:** Commit `feat(podbox): detect firmware, build and library layout`.

### Task 2: Write policy (Core-only)

**Files:**
- Create: `Sources/CrateDiggerCore/Services/DeviceFiles/DeviceWritePolicy.swift`
- Test: `Tests/CrateDiggerCoreTests/DeviceWritePolicyTests.swift`

**Interfaces, Produces:** `DeviceFileRole`, `DeviceDeleteReason`, `DeviceWritePolicy`, `DeviceWritePolicyError.forbidden(String)` exactly as the spec's block and role table, plus:

```swift
public extension DeviceWritePolicy {
    /// NFC, case-folded, components trimmed of trailing dots and spaces. The journal uses the same key.
    static func key(forRelativePath path: String) -> String
    /// Relative path of `url` under `root` after resolving symlinks; nil when it leaves the root.
    static func relativePath(of url: URL, under root: URL) -> String?
}
```

Pinned details:
- Check order: empty, absolute (`/` prefix) or any `..` or `.` component → forbidden; then any component whose key equals a denied tree name → forbidden; then the root file `.scrobbler.log` → forbidden; then role not in `enabledRoles` → forbidden; then the role's area and name rule.
- Denied tree names are matched on **every** component's position 0 only (a folder called `Music/.rockbox` is odd but not the player's); the exception role `knownArtists` matches the one exact key `.rockbox/library/user/known_artists.txt` and is not in the default `enabledRoles`.
- `audio` at the volume root is allowed only when `musicSubpath` is empty. With an empty music subpath the denied trees still win.
- `temp`: the name must end `.cdtmp` and the name without that suffix must itself pass as `audio` or `cover` (or any other enabled role) at that path.
- `checkDelete`: `.userReplace` → the `audio` rule; `.appleDouble` → last component starts with `._`, longer than two characters, and no denied tree; `.ownedByCrateDigger` → passes if any enabled role's write rule passes; `.staleTemp` → the `temp` rule.
- Pure: no file-system access in `checkWrite`/`checkDelete`. `relativePath(of:under:)` is the only function that touches disk.

- [ ] **Step 1: Failing tests:** `testAllowsAudioUnderMusicFolder` (`Music/A/B/01.m4a`), `testAllowsCoverBesideAudio`, `testDeniesCoverNamedOtherwise` (`Music/A/B/folder.png` as `.cover`), `testDeniesAudioOutsideMusicFolder` (`Other/x.mp3`), `testDeniesNonAudioExtensionAsAudio` (`Music/x.dat`), `testDeniesEveryDeniedTree` (one path per tree, as write and as each delete reason), `testDeniesScrobblerLog`, `testDeniesTrailingDotSpaceAndCaseAliases` (`.ROCKBOX/config.cfg`, `.rockbox./x.mp3`, `.rockbox /x.mp3`, `IPOD_CONTROL/x.mp3`) (Review Focus 1), `testDeniesTraversalAndAbsolutePaths` (`Music/../.rockbox/x.mp3`, `/Music/x.mp3`, `Music/./x.mp3`) (Review Focus 2), `testEmptyMusicSubpathAllowsRootAudioButNotRockbox`, `testRootAudioDeniedWhenMusicSubpathSet`, `testTempAllowedOnlyBesideAllowedTarget` (`Music/A/01.m4a.cdtmp` yes, `Music/A/x.dat.cdtmp` no), `testDisabledRoleRefused` (`Artwork/People/Radiohead.jpg` as `.artistPicture` with default roles), `testArtistPictureWhenEnabled` (allowed top level; `Artwork/People/sub/x.jpg` and `x.png` refused), `testKnownArtistsIsTheOnlyRockboxException`, `testAppleDoubleDeleteAnywhereOutsideDeniedTrees` (`Notes/._a.txt` yes, `.rockbox/themes/._x.cfg` no, `._` alone no), `testUserReplaceOnlyAudioUnderMusic`, `testKeyFoldsCaseNFCAndTrailingDots`, `testGeneratedPathsNeverReachDeniedTrees` (500 paths built from a seeded generator over components `{Music, .rockbox, .ROCKBOX, .., ., a, b.mp3, ._x.m4a, iPod_Control}`; for each, if `checkWrite` or `checkDelete` passes, assert no component key equals a denied name).
- [ ] **Step 2:** Run, see the compile failure.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Filter and full suite pass.
- [ ] **Step 5:** Commit `feat(devices): allowlist policy for every device write and delete`.

### Task 3: IO primitives and the journal (Core-only)

**Files:**
- Create: `Sources/CrateDiggerCore/Services/DeviceFiles/DeviceFileIO.swift`
- Create: `Sources/CrateDiggerCore/Services/DeviceFiles/DeviceWriteJournal.swift`
- Test: `Tests/CrateDiggerCoreTests/DeviceFileIOTests.swift`, `DeviceWriteJournalTests.swift`

**Interfaces, Consumes:** `DeviceWritePolicy.key(forRelativePath:)` (Task 2).

**Produces:** `DeviceFileIO`, `DeviceFileRecord`, `DeviceWriteJournal` as in the spec, with these additions:

```swift
public extension DeviceFileIO {
    static let tempSuffix = ".cdtmp"
    static func isAppleDoubleHeader(_ header: Data) -> Bool          // 8 bytes: 00 05 16 07 00 02 00 00
    static func sha256(of url: URL) throws -> String                 // streamed, lowercase hex
}
public extension DeviceWriteJournal {
    var folder: URL { get }                                           // <dir>/<profileID>/
    func backUp(fileAt url: URL, relativePath: String, sessionID: UUID) throws -> String
}
```

Pinned details:
- `DeviceFileIO` is the only file in the repo allowed to mutate a device path (Task 7 enforces it). It does no policy checking; callers check first.
- `copyDataOnly`: `copyfile(src, dst + ".cdtmp", nil, COPYFILE_DATA)`, `fsync` the temp, `rename` over the destination, set the destination's modification date to the source's, `stripExtendedAttributes`, `removeProvenTwin`. On any failure remove the temp and rethrow. It creates no directories.
- `writeAtomically`: same temp, `fsync`, rename, strip, twin sequence from `Data`. Never `Data.write(options: .atomic)`.
- `removeProvenTwin(of:)`: looks for `._<name>` beside the file; deletes it only if it is a regular file (`lstat`) of 26 bytes to 128 KB whose first 8 bytes pass `isAppleDoubleHeader`. Returns whether it deleted.
- `remove`: `unlink`; `ENOENT` is success.
- Journal default directory: `<Application Support>/CrateDigger/DeviceJournal`. File `journal.jsonl`, one JSON `DeviceFileRecord` per line, ISO 8601 dates, appended with a `FileHandle` and synchronised. Backups under `backups/<sessionID>/<relativePath>`.
- `ownedRecord(forKey:)`: the last record for that key, returned only when its kind is `created` or `replaced`; a later `deleted` record means nil. `tempIntent` records are ignored by it.
- Loading tolerates blank lines and a broken last line.

- [ ] **Step 1: Failing tests.** `DeviceFileIOTests` (temp dirs): `testCopyDataOnlyCopiesBytesAndKeepsSourceDate`, `testCopyDataOnlyDropsExtendedAttributes` (set `com.example.test` on the source with `setxattr`, assert `listxattr` on the copy is empty), `testCopyLeavesNoTempFile`, `testCopyFailureRemovesTemp` (destination folder missing → throws, no `.cdtmp` anywhere), `testWriteAtomicallyReplacesExisting`, `testRemoveProvenTwinDeletesRealTwin`, `testRemoveProvenTwinKeepsLookAlike` (a `._x.m4a` holding `ftyp` bytes), `testRemoveProvenTwinKeepsOversize` (129 KB with the magic), `testRemoveMissingFileIsNotAnError`, `testSHA256KnownValue` (`"abc"` → `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`). `DeviceWriteJournalTests`: `testAppendThenOwnedRecord`, `testDeletedAfterCreatedIsNotOwned`, `testKeyIsCaseAndNFCInsensitive`, `testTempIntentIsNotOwnership`, `testRecordsBySession`, `testBackUpWritesUnderSessionFolder`, `testReloadFromDiskSeesEarlierRecords`, `testTruncatedLastLineIsIgnoredAndOwnershipFailsSafe` (append two records, chop the file mid second line, reload: first owned, second nil, a further append still works) (Review Focus 4), `testMissingJournalMeansNothingOwned`.
- [ ] **Step 2:** Run, see failures.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Filters and full suite pass.
- [ ] **Step 5:** Commit `feat(devices): safe copy and write primitives, and a journal of what was written`.

### Task 4: The executor (Core-only)

**Files:**
- Create: `Sources/CrateDiggerCore/Services/DeviceFiles/DeviceFileExecutor.swift`
- Test: `Tests/CrateDiggerCoreTests/DeviceFileExecutorTests.swift`

**Interfaces, Consumes:** Task 2 policy, Task 3 IO and journal, Task 1 `FakeIPod`.

**Produces:** `DeviceFileContents`, `DeviceFileOperation`, `DeviceFileOutcome`, `DeviceFileExecutor` as in the spec, with one added initialiser parameter:

```swift
public init(volumeRoot: URL, expectedVolumeUUID: String?, policy: DeviceWritePolicy,
            journal: DeviceWriteJournal, fileManager: FileManager = .default,
            volumeUUID: @escaping (URL) -> String? = DeviceFileExecutor.systemVolumeUUID,
            freeSpace: @escaping (URL) -> Int64? = DeviceFileExecutor.systemFreeSpace)
public static func systemVolumeUUID(_ root: URL) -> String?    // URLResourceKey.volumeUUIDStringKey
public static func systemFreeSpace(_ root: URL) -> Int64?      // volumeAvailableCapacityKey
public static let freeSpaceMargin: Int64 = 8 * 1024 * 1024
```

Pinned details (the spec's seven write steps and the delete rules, in that order), plus:
- Volume check happens once at the top of `apply` and again before each operation. `expectedVolumeUUID == nil` skips the comparison but still requires the root to exist.
- Before the policy check, resolve the operation's parent folder with `DeviceWritePolicy.relativePath(of:under:)`; nil (a symlink out of the root) → `refusedPolicy`.
- Before the first write of a session append one `tempIntent` record per planned temp path. A `.cdtmp` already sitting at a planned temp path is removed only when an earlier `tempIntent` record names it; otherwise the operation is `refusedForeign`.
- Intermediate directories are created with `DeviceFileIO.createDirectory`, only for a path the policy has passed.
- `replacesForeign: true` is honoured only for role `.cover`; for any other role it is ignored and a foreign file is refused.
- The backup of a replaced or deleted file is written before the file is touched; a backup failure is `failed` and the file is left.
- `.delete(reason: .appleDouble)`: re-run the full proof at apply time (regular file, 26 bytes to 128 KB, 8-byte header) → else `refusedNotAppleDouble`.
- `.delete(reason: .userReplace)`: policy only, no journal requirement, no backup (the duplicates spec: Replace deletes).
- One journal append per applied operation, after the file change. Outcomes array is index-aligned with `ops`.
- `sha256` is recorded for every role except `.audio`.

- [ ] **Step 1: Failing tests** (each builds a `FakeIPod`, takes `manifest()` first and ends with `assertPlayerStateUntouched`): `testWriteCreatesFileAndJournalRecord`, `testIdenticalBytesAreUnchangedAndDateIsKept`, `testForeignFileIsRefused`, `testOwnedFileIsReplacedAndBackedUp`, `testOwnedFileEditedSinceReadsAsForeign`, `testFileRemovedByOwnerIsRecreated`, `testRenameWithoutJournalRecordReadsAsForeignNextTime` (write with a journal whose `append` throws via a subclass or a read-only journal folder; a second executor with a fresh journal refuses), `testCoverMayReplaceForeignAndBacksItUp`, `testReplacesForeignIgnoredForOtherRoles`, `testPolicyRefusalDoesNoIO` (`.rockbox/x.mp3`), `testSymlinkOutOfMusicFolderIsRefused` (`Music/link` → `../.rockbox`, write `Music/link/x.mp3`) (Review Focus 2), `testVolumeChangedBetweenPlanAndApplyRefusesEverything` (inject a `volumeUUID` closure returning another value) (Review Focus 3), `testRootVanishedMidApplyFailsRemainingOps` (closure removes the root after the first op; later outcomes are `refusedWrongVolume` or `failed`, no crash) (Review Focus 3), `testNoSpaceRefusesBeforeWriting` (inject `freeSpace` = 1 MB), `testFailedWriteLeavesNoTemp`, `testStaleTempWithIntentIsRemoved`, `testStaleTempWithoutIntentIsForeign`, `testOwnedDeleteNeedsMatchingHash`, `testOwnedDeleteBacksUpFirst`, `testAppleDoubleDeleteReprovesAtApply` (overwrite the twin with `ftyp` bytes after planning → `refusedNotAppleDouble`), `testDeleteOfMissingFileIsAlreadyGone`, `testUserReplaceDeletesAudioWithoutJournal`, `testApplyingSamePlanTwiceChangesNothing` (second run all `unchanged`, modification dates equal), `testAudioRecordHasNoHash`.
- [ ] **Step 2:** Run, see failures.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Filter and full suite pass.
- [ ] **Step 5:** Commit `feat(devices): one executor for device writes, with ownership and backups`.

### Task 5: AppleDouble sweep plan (Core-only)

**Files:**
- Create: `Sources/CrateDiggerCore/Services/DeviceFiles/AppleDoubleSweeper.swift`
- Test: `Tests/CrateDiggerCoreTests/AppleDoubleSweeperTests.swift`

**Interfaces, Consumes:** `DeviceFileIO.isAppleDoubleHeader`, `DeviceWritePolicy.deniedTrees`, `DeviceFileOperation.delete(relativePath:reason:)`, `FakeIPod`.

**Produces:** `AppleDoubleSweepPlan`, `AppleDoubleSweeper` as in the spec, with:

```swift
public init(fileManager: FileManager = .default)
public static let minimumSize = 26
public static let defaultMediaExtensions: Set<String>
// LibraryScanService.defaultSupportedExtensions + jpg jpeg png bmp gif webp m3u m3u8 lrc lrc8 snc epub pdf cue
public enum LeftAloneReason: String { case notMedia = "not media", tooLarge = "too large", notAppleDouble = "not AppleDouble", notRegularFile = "not a file" }
```

Pinned details:
- `plan` never deletes. It walks with hidden files included (the twins are hidden), does not descend into a denied tree at the volume root, reads 8 bytes per `._` file.
- A candidate satisfies the spec's whole proof (D20, D21). The media test is on the extension of the name after `._`.
- `leftAlone` is keyed by `LeftAloneReason.rawValue`. `sizeHistogram` buckets candidates by size rounded up to a power of two.
- `operations` is one `.delete(relativePath:, reason: .appleDouble)` per candidate, sorted by path.
- `scope: nil` walks the whole volume; otherwise each scope folder non-recursively plus nothing else (a session passes exactly the folders it wrote to).

- [ ] **Step 1: Failing tests:** `testFindsTwinsOfAudio`, `testOrphanTwinQualifies` (no sibling file), `testRealAudioNamedLikeATwinSurvives`, `testDirectoryNamedLikeATwinSurvives`, `testSymlinkSurvives`, `testTenByteFileSurvives`, `testAppleSingleMagicSurvives` (`00 05 16 00`), `testWrongVersionSurvives` (`00 05 16 07 00 01 00 00`), `testOversizeTwinIsLeftAndCounted` (129 KB → `leftAlone["too large"] == 1`), `testNonMediaTwinIsLeftAndCounted` (`Notes/._todo.txt`), `testNothingUnderDeniedTreesIsListed` (twins planted in `.rockbox/themes`, `.rockbox_backup`, `iPod_Control`, `.Trashes`), `testScopedPlanIsNotRecursive`, `testWholeVolumePlanFindsTwinsInPlaylistsAndArtwork`, `testPlanDeletesNothing` (file count before equals after), `testPlanThenExecutorRemovesExactlyTheCandidates` (apply through Task 4's executor; player state untouched; every real file still present), `testUnreadableTwinIsLeftAlone` (permissions 000 → counted `not AppleDouble`, no throw).
- [ ] **Step 2:** Run, see failures.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Filter and full suite pass.
- [ ] **Step 5:** Commit `feat(devices): plan removal of proven macOS metadata files`.

### Task 6: Session gate and next steps (Core-only)

**Files:**
- Create: `Sources/CrateDiggerCore/Services/DeviceFiles/DeviceSessionGate.swift`
- Create: `Sources/CrateDiggerCore/Services/PodBox/PodBoxNextSteps.swift`
- Test: `Tests/CrateDiggerCoreTests/DeviceSessionGateTests.swift`, `PodBoxNextStepsTests.swift`

**Interfaces, Consumes:** `DeviceFirmware` (Task 1). **Produces:** `DeviceSessionTrigger`, `DeviceAction`, `DeviceSessionGate.allows`, `DeviceWriteChanges`, `PodBoxNextSteps.after`, `PodBoxNextSteps.isDone`, as in the spec.

Pinned details:
- Gate table: `mount` → only `.probe`. `userAction` → `.probe`, `.transferAudio`, `.sweep` always; `.writeExtras`, `.importPlays`, `.scrobble` only when `matchedByUUID`.
- `after` returns lines in this order, exact copy, PodBox flavour only:
  1. audio or playlists: `Eject the iPod. PodBox adds the new music when it restarts. If it does not appear: Settings ▸ Library ▸ Maintenance ▸ Update Database.`
  2. covers or pictures: `Then on the iPod: Settings ▸ Library ▸ Maintenance ▸ Update Art Cache.`
  3. cleanup: `The unreadable-files list clears at the next scan.`
  4. audio and `config.value("playlist engine") == "on"`: `Update Sound Analysis measures the new tracks.`
  - Lyrics alone → empty. Empty changes → empty.
  - Covers or pictures without audio: line 1 is replaced by `Eject the iPod.`
- Any other Rockbox flavour, or `firmware == nil`, with non-empty changes: the single line `Eject the device before unplugging.`
- `isDone`: both non-nil and `playerFileModified > lastWrite + 60 s`.

- [ ] **Step 1: Failing tests:** `DeviceSessionGateTests`: `testMountAllowsOnlyProbe` (all six actions), `testUserActionWithoutUUIDAllowsTransferAndSweepOnly`, `testUserActionWithUUIDAllowsEverything`. `PodBoxNextStepsTests`: `testAudioOnly`, `testAudioAndCovers` (two lines in order), `testCoversOnlyStartsWithEject`, `testCleanupOnly`, `testLyricsOnlyIsEmpty`, `testEngineOnAddsSoundAnalysis`, `testStockRockboxGetsOneLine`, `testNoFirmwareGetsOneLine`, `testNoChangesIsEmpty`, `testNoLineContainsAnEmDash`, `testIsDoneNeedsMoreThanAMinute`, `testIsDoneFalseWhenEitherMissing`.
- [ ] **Step 2:** Run, see failures. **Step 3:** Implement. **Step 4:** Filters and full suite pass.
- [ ] **Step 5:** Commit `feat(podbox): gate device actions by trigger, and say what to do on the iPod`.

### Task 7: Door lint and FAT sandbox (Core-only)

**Files:**
- Create: `Tests/CrateDiggerCoreTests/DeviceWriteDoorLintTests.swift`
- Create: `scripts/fat-sandbox.sh`
- Create: `Tests/CrateDiggerCoreTests/FATSandboxTests.swift`

**Interfaces, Consumes:** Tasks 3 to 5. **Produces:** `DeviceWriteDoorLintTests.guardedPaths` and `.allowedLines` (static arrays that Task 9 extends).

Pinned details:
- The lint locates the repo root from `#filePath`, reads every `.swift` file under each guarded path and fails, naming file and line, on any line containing `copyItem(`, `moveItem(`, `removeItem(`, `trashItem(`, `createFile(`, `.write(to:`, `FileHandle(forWritingTo`, `FileHandle(forUpdating` or `replaceItem`. Comment lines are skipped. `allowedLines` is a list of `(fileSuffix, substring, reason)` exemptions.
- `guardedPaths` in this task: `Sources/CrateDiggerCore/Services/DeviceFiles` (excluding `DeviceFileIO.swift`, and `DeviceWriteJournal.swift` which writes on the Mac), `Sources/CrateDiggerCore/Services/PodBox`. `Services/DeviceTransfer`, `FolderCoverArtWriter.swift` and `UI/ExternalDevices` are added by Task 9, when they comply.
- `scripts/fat-sandbox.sh up <dir>`: `hdiutil create -size 64m -fs MS-DOS -volname CDTEST <dir>/fat.dmg` then `hdiutil attach -nobrowse -mountpoint <dir>/mnt <dir>/fat.dmg`, prints `export CRATEDIGGER_FAT_SANDBOX=<dir>/mnt`. `down <dir>` detaches and deletes the image. It refuses any `<dir>` under `/Volumes` and any `<dir>` that does not exist.
- `FATSandboxTests` call `XCTSkip` when `CRATEDIGGER_FAT_SANDBOX` is unset or its path is under `/Volumes`. Findings S1 to S6 from the spec are recorded with `XCTContext.runActivity` and printed; they assert only what the door relies on.

- [ ] **Step 1: Tests.** Lint: `testNoDirectFileMutationOutsideTheDoor`, `testLintCatchesAPlantedViolation` (run the scanner over a string containing `fm.removeItem(at: x)` and expect one hit), `testCommentsAreIgnored`. Sandbox: `testS1WhichWritesCreateTwins` (prints), `testCopyDataOnlyLeavesNoTwinOnFAT`, `testWriteAtomicallyLeavesNoTemporaryItemsFolder`, `testRenameOverExistingWorksOnFAT`, `testS5NFDNameBytes` (prints), `testS6QuestionMarkAndTrailingDot` (prints), `testExecutorSuiteOnFAT` (create/replace/unchanged/owned delete on the mounted image).
- [ ] **Step 2:** Run the lint filter: passes on Tasks 1 to 6 code (fix any real violation it finds there).
- [ ] **Step 3:** Run `scripts/fat-sandbox.sh up "$SCRATCH"` in the session scratch directory, export the variable, run `scripts/test.sh --filter FATSandboxTests`, then `down`. If a door-relied assertion fails on real FAT, fix `DeviceFileIO` and re-run Task 3's and Task 4's filters. Paste the S1, S5 and S6 printed findings into the commit body.
- [ ] **Step 4:** Full `scripts/test.sh` passes with the variable unset (sandbox tests skip).
- [ ] **Step 5:** Commit `test(devices): lint for the write door and a FAT disk-image sandbox`.

### Task 8: Probe at mount, firmware readout, dry run (wiring)

**Needs from the duplicates plan:** nothing. It edits `DevicesPreferencesView.swift` and `OLEDDisplay.swift`, which duplicates Task 8 (`DeviceArtworkReadout`, the Artwork control) also edits; if that task has not been merged into this branch yet, keep the edits to the two insertion points below so the merge is trivial.

**Files:**
- Create: `Sources/CrateDiggerApp/UI/ExternalDevices/LibraryViewModel+PodBox.swift`
- Create: `Sources/CrateDiggerCore/Services/PodBox/PodBoxDryRun.swift` + `Tests/CrateDiggerCoreTests/PodBoxDryRunTests.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` (the `@Published` storage, and the place `mountedDevices` is assigned, near the `if detected != mountedDevices` line)
- Modify: `Sources/CrateDiggerApp/UI/ExternalDevices/DevicesPreferencesView.swift` (`Section("Device")`)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Header/OLEDDisplay.swift` (`DevicesPane`, the Kind cell)
- Modify: `Sources/CrateDiggerApp/main.swift` or wherever the other `CRATEDIGGER_*` DEBUG hooks are read (grep `CRATEDIGGER_BUSY`)

**Interfaces, Consumes:** Tasks 1, 2, 5. **Produces:**

```swift
// LibraryViewModel (stored, in the main file)
@Published var deviceFirmware: [MountedDevice.ID: DeviceFirmware] = [:]
// LibraryViewModel+PodBox.swift
func refreshDeviceFirmware()                                   // detached probe per mounted device; drops entries for unmounted ones
func firmware(for device: MountedDevice) -> DeviceFirmware?
func capabilities(for device: MountedDevice) -> DeviceCapabilities   // file system via statfs f_fstypename
func devicePolicy(for profile: ExternalDeviceProfile, firmware: DeviceFirmware?) -> DeviceWritePolicy
func isMatchedByUUID(_ device: MountedDevice, _ profile: ExternalDeviceProfile) -> Bool
// Core
public enum PodBoxDryRun {
    /// Text report: firmware summary, capabilities, prefix, cleanup plan counts, left-alone counts, size table,
    /// the "names" section for M2, and the last line "0 files would be written".
    public static func report(volumeRoot: URL, musicSubpath: String, fileManager: FileManager = .default) -> String
}
```

Behaviour:
- `refreshDeviceFirmware` runs wherever `mountedDevices` changes and at launch. The probe is the only thing that happens at mount (`DeviceSessionGate.allows(.probe, trigger: .mount, …)`).
- Preferences ▸ Devices, Device section: a read-only row labelled `Firmware` showing `summaryLine`, only while that profile's device is mounted and has `.rockbox`; when `layout > 5` a caption `This iPod runs a newer PodBox library layout (N) than CrateDigger knows (5).`; when not booted `Start the iPod once so PodBox can finish setting up.`
- DEVICES screen: when the browsed device is PodBox the Kind cell value reads `PODBOX` and its sub the model name; otherwise unchanged.
- `CRATEDIGGER_PODBOX_DRYRUN=<path>` (DEBUG only): print `PodBoxDryRun.report` to stdout and exit before any window opens. `report` constructs no executor and no journal. The "names" section lists the hex bytes of every music-folder directory name containing a non-ASCII character (first 5) and every name containing `? * " < > |` or ending in a dot.

- [ ] **Step 1: Failing Core tests** `PodBoxDryRunTests` on a `FakeIPod` with twins: `testReportNamesFirmwareAndPrefix`, `testReportCountsCandidates`, `testReportEndsWithZeroFilesWritten`, `testReportLeavesEverythingUntouched` (whole-volume file count and player manifest equal before and after), `testNamesSectionListsNonASCIIAndOddNames`.
- [ ] **Step 2:** Implement Core, then the wiring and the two UI insertions.
- [ ] **Step 3:** `swift build`; full `scripts/test.sh` passes.
- [ ] **Step 4:** Build a throwaway `FakeIPod`-like folder in the scratch directory by hand (a `.rockbox/library/format.dat` with the 28 bytes, a `Music/A/B/._01.m4a` with the 8-byte header padded to 4096) and run `.build/debug/CrateDiggerApp` with `CRATEDIGGER_PODBOX_DRYRUN=<that folder>`. Confirm the report and that nothing in the folder changed. Never point it at `/Volumes`.
- [ ] **Step 5:** Commit `feat(podbox): show the iPod's firmware and add a read-only dry run`.

### Task 9: Route device copies, deletions and covers through the door (wiring)

**Needs from the duplicates plan:** Task 5 (`DeviceTransferExecutor.run(_:copy:onProgress:)` in Core, or the rewritten copy loop in `runExternalDeviceCopy` if the extraction was skipped), Task 6 (convert runs building jobs from `plan.copies`), Task 7 (SYNC loop). Start only when those three are on this branch. If `DeviceTransferExecutor` exists, its `copy:` closure and its deletion step are the two seams; otherwise the seams are the `copyItem` calls in `LibraryViewModel+ExternalDeviceTransfer.swift` (`runCopyTransferQueue`) and `LibraryViewModel+DeviceSync.swift` (two calls in `syncQueuedTransfers`).

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/FolderCoverArtWriter.swift`
- Modify: `Sources/CrateDiggerCore/Services/DeviceTransfer/DeviceTransferExecutor.swift` (if present)
- Modify: `Sources/CrateDiggerApp/UI/ExternalDevices/LibraryViewModel+ExternalDeviceTransfer.swift`, `LibraryViewModel+DeviceSync.swift`, `Sources/CrateDiggerApp/UI/Conversion/LibraryViewModel+Conversion.swift` (device runs only)
- Create: `Sources/CrateDiggerCore/Services/DeviceFiles/DeviceTransferDoor.swift` + `Tests/CrateDiggerCoreTests/DeviceTransferDoorTests.swift`
- Modify: `Tests/CrateDiggerCoreTests/DeviceWriteDoorLintTests.swift` (`guardedPaths`), `Tests/CrateDiggerCoreTests/FolderCoverArtWriterTests.swift` (extend, or create)

**Produces:**

```swift
// Core: the three things a transfer does to a device, policy first.
public struct DeviceTransferDoor: Sendable {
    public init(volumeRoot: URL, policy: DeviceWritePolicy, fileManager: FileManager = .default)
    public func copyAudio(from source: URL, to destination: URL) throws            // checkWrite(.audio) → createDirectory → copyDataOnly
    public func checkConversionDestinations(_ destinations: [URL]) throws           // every ffmpeg output path, before the run
    public func finishConvertedFile(at destination: URL)                             // strip attributes + remove proven twin
    public func removeReplacedAudio(at url: URL) throws                              // checkDelete(.userReplace) → remove
    public func writeCover(_ data: Data, to destination: URL) throws -> Bool         // checkWrite(.cover); false when bytes already identical
}
public enum DeviceTransferDoorError: Error, LocalizedError { case outsideVolume(String), forbidden(String) }
```

Behaviour:
- Every device audio copy in the three paths calls `copyAudio`. Convert runs call `checkConversionDestinations` before starting and `finishConvertedFile` on each success. Replace deletions call `removeReplacedAudio`. A policy refusal fails that item with the message `CrateDigger does not write there: <reason>` and the run continues.
- `FolderCoverArtWriter.init` gains `writeData: @escaping (Data, URL) throws -> Bool` defaulting to a closure that compares with the bytes on disk and uses `DeviceFileIO.writeAtomically`; the view model passes `door.writeCover`. The stale comment about `.atomic` goes. `written` counts only covers whose bytes changed.
- Non-device conversions and non-device cover writing are untouched.
- Extend `guardedPaths` with `Sources/CrateDiggerCore/Services/DeviceTransfer`, `Sources/CrateDiggerCore/Services/FolderCoverArtWriter.swift`, `Sources/CrateDiggerApp/UI/ExternalDevices`. Calls that touch only the Mac (staged files under Application Support, queue files) go in `allowedLines` with the reason.

- [ ] **Step 1: Failing tests.** `DeviceTransferDoorTests` on `FakeIPod`: `testCopyAudioLandsWithoutAttributesOrTwin`, `testCopyAudioIntoRockboxIsRefusedAndWritesNothing`, `testCopyAudioOutsideVolumeIsRefused`, `testConversionDestinationsAllChecked` (one bad path fails the whole check), `testFinishConvertedFileRemovesTwin`, `testRemoveReplacedAudioRefusesNonAudioAndDeniedTrees`, `testWriteCoverSkipsIdenticalBytes` (date unchanged, returns false), `testWriteCoverReplacesDifferentBytes`; each ends with `assertPlayerStateUntouched`. `FolderCoverArtWriterTests`: `testSecondRunWritesNothing`, `testNoTemporaryFileLeftInFolder`. Lint: `testNoDirectFileMutationOutsideTheDoor` now covers the new paths.
- [ ] **Step 2:** Implement Core, then swap the seams.
- [ ] **Step 3:** `swift build`; full `scripts/test.sh` passes (the lint included).
- [ ] **Step 4:** Commit `fix(devices): every device copy, delete and cover goes through the write door`.

### Task 10: Finish a session, clean up, eject (wiring)

**Needs from the duplicates plan:** Task 5 (`patchDeviceCatalog(for:adding:removingPaths:)`, `DeviceTransferSummary.statusLine`, the summary alert each path shows). **Needs from this plan:** Tasks 8 and 9.

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/ExternalDevices/LibraryViewModel+PodBox.swift`, `LibraryViewModel+ExternalDeviceTransfer.swift`, `LibraryViewModel+DeviceSync.swift`, `Sources/CrateDiggerApp/UI/Conversion/LibraryViewModel+Conversion.swift`
- Modify: `Sources/CrateDiggerApp/UI/ExternalDevices/DevicesPreferencesView.swift`, `Sources/CrateDiggerApp/UI/Carbon/Main/SourcesSidebar.swift` (device row context menu)
- Create: `Sources/CrateDiggerCore/Services/DeviceFiles/DeviceCleanupSummary.swift` + `Tests/CrateDiggerCoreTests/DeviceCleanupSummaryTests.swift`

**Produces:**

```swift
// LibraryViewModel+PodBox.swift
/// Called by every device write path right after patchDeviceCatalog. Returns the next-step lines.
func finishDeviceSession(device: MountedDevice, profile: ExternalDeviceProfile,
                         written: [URL], deleted: [URL], changes: DeviceWriteChanges) async -> [String]
func cleanUpMacFiles(device: MountedDevice, scope: [URL]?)       // plan → confirm → apply → report → offer Eject
func ejectDevice(_ device: MountedDevice)
// Core
public enum DeviceCleanupSummary {
    public static func confirmation(_ plan: AppleDoubleSweepPlan) -> (title: String, message: String)
    public static func result(removed: Int, refused: Int, leftAlone: [String: Int]) -> String
    public static func mountHint(count: Int) -> String?          // nil when 0
}
```

Behaviour:
- `finishDeviceSession`: for a volume with `appleDoubleSweep`, build `AppleDoubleSweeper().plan(scope:)` over the parent folders of `written` and `deleted`, apply it through `DeviceFileExecutor` (journal for this profile, session ID per call, `expectedVolumeUUID` from the device); add `.cleanup` to `changes` when anything was removed; return `PodBoxNextSteps.after`. It runs inside the caller's existing `transfer` busy job and never fails the transfer: errors become one summary line.
- Each device path appends the returned lines to its summary alert and offers an `Eject` button there (follow how neighbouring alerts add a second action; if `appAlert` cannot carry one, add the action to the device row instead and say so in the commit body). SYNC calls it once, after the queue drains.
- `cleanUpMacFiles`: allowed by `DeviceSessionGate` for `.sweep` on a user action. Plan stamped `beginBusyJob(.scan, on: .devices)`, apply stamped `.transfer`, both ended on every exit. Confirmation copy from `DeviceCleanupSummary.confirmation`: title `Remove Mac files from <device>?`, message `<N> Mac metadata files found. They are not music. A copy is kept on this Mac.` plus, when anything is left alone, `<M> other files are left alone.` Buttons `Remove` and `Cancel`. Zero candidates → info alert `No Mac metadata files found.`
- Result line: `Removed <N> Mac metadata files.` plus `<R> could not be verified and were left.` when R > 0, then the next-step line for cleanup.
- UI: Preferences ▸ Devices Device section gets a `Clean Up Mac Files…` button (enabled while mounted on a FAT or exFAT volume) with the caption from `mountHint`: `PodBox is reading <N> Mac files as music.`; the device row's context menu gets `Clean Up Mac Files…` and `Eject`. A device folder row in the browser gets `Clean Up Mac Files in This Folder…` (scope = that folder and its subfolders, passed as the explicit folder list).
- `ejectDevice`: `NSWorkspace.shared.unmountAndEjectDevice(at:)` off the main thread; failure shows the system's error text.
- None of this runs at mount. No dialog appears when a device is plugged in.

- [ ] **Step 1: Failing Core tests** `DeviceCleanupSummaryTests`: `testConfirmationWithCountAndLeftAlone` (1,731 candidates, 12 left alone: message contains `1,731 Mac metadata files found.` and `12 other files are left alone.`), `testConfirmationSingular` (`1 Mac metadata file found. It is not music.`), `testResultWithRefusals`, `testMountHintNilAtZero`, `testNoEmDashAnywhere`.
- [ ] **Step 2:** Implement Core, then the wiring and UI.
- [ ] **Step 3:** `swift build`; full `scripts/test.sh` passes.
- [ ] **Step 4:** Launch with a scratch crates dir, capture Preferences ▸ Devices with `screencapture -l <windowID>` to `.build/podbox/prefs.png`, read it, fix layout defects, `pkill -f CrateDiggerApp`. Do not connect a profile to `/Volumes/IPOD` or press Clean Up against it.
- [ ] **Step 5:** Commit `feat(podbox): clean up Mac files, next steps and eject after a transfer`.

### Task 11: Docs

**Needs:** Tasks 8 to 10.

**Files:** `CLAUDE.md` (a "PodBox and the device write door" subsection under Sources model: firmware is probed per mount and never saved; the denied trees; "a new device writer checks `DeviceWritePolicy`, writes through `DeviceFileIO` or `DeviceFileExecutor`, and ends with `finishDeviceSession`"; the lint test and `FakeIPod.assertPlayerStateUntouched`; the FAT sandbox script; the dry-run hook; add `+PodBox` to the `UI/ExternalDevices/` extension list and make the count 32), `CHANGELOG.md` (`## 2.3.4`, user-facing lines: PodBox is recognised; Mac metadata files are no longer left on devices and can be cleaned up; next steps and Eject after a transfer), `docs/superpowers/specs/2026-11-11-podbox-integration-design.md` (only if a built name differs from the spec's: correct the spec).

- [ ] **Step 1:** Write. **Step 2:** Full `scripts/test.sh` passes. **Step 3:** Commit `docs: PodBox detection and the device write door`.

---

## After this plan

The owner runs M1, M2, M3 and M4 from the spec on the real iPod, in that order. No agent runs them.
