# Device Transfer Duplicates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every device transfer path copies only what isn't on the device, skips what is, asks once (per album) about what differs, and folder art becomes a visible per-device switch.

**Architecture:** All decidable logic goes in `CrateDiggerCore` under `Services/DeviceTransfer/`: a matcher that classifies each album sent against the device catalog, and a resolver that turns classifications plus the user's decisions into a concrete file plan (copies, then deletions). The three view-model paths (copy, convert hand-off, offline queue/SYNC) become thin callers of the same review → sheet → resolve → execute → patch-catalog sequence in a new `LibraryViewModel+DeviceReview.swift`.

**Tech Stack:** Swift, SwiftPM, XCTest (`scripts/test.sh`), AppKit sheet hosting SwiftUI.

**Spec:** `docs/superpowers/specs/2026-11-11-device-transfer-duplicates-design.md`. Read it before any task; it is the authority where this plan is silent.

## Global Constraints

- Work only in this worktree (branch `feat/device-duplicates`, cut from `v2.3`). Never `cd` to the main checkout. Never push, tag, or bump versions.
- **A real iPod is mounted under `/Volumes`. Never write to, delete from, or run a transfer/sync against anything under `/Volumes` except this repo's own path.** Tests use `FileManager.default.temporaryDirectory`. Do not launch the app against the user's real preferences or library; when launching, set `CRATEDIGGER_CRATES_DIR` to a scratch folder.
- Build: `swift build`. Tests: `scripts/test.sh --filter <Class>`; the full `scripts/test.sh` must pass at the end of every task.
- New logic that is a decidable value lives in Core with an XCTest. View-model code only wires.
- No silent ` (2)` on a device, no pre-selected decision, no deletion the user didn't choose, art compared by pixel size and never by hash (spec anti-goals).
- Persisted types must decode files written before this change (profiles, sync queues).
- Every device writer keeps the writability and free-space preflights, starts with the existing guards, and stamps `beginBusyJob`/`endBusyJob`.
- Sheets present from the root (`presentationHostViewController`), never from `MainShell`.
- User-facing copy: plain, no em dashes. Many info messages use `appAlert = .info/.error`; follow neighbours.
- Commit after each task with a conventional message ending in `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`. Stage only files you changed.

## Review Focus

1. Tracks with no track number on either side (loose downloads): must match by folded title, never all collapse onto slot "no number".
2. Compilation with per-track artists and no album-artist tag: sent as one album must match the device's one album (identity uses the reconciled `albumFolderKeys` artist bucket, not per-track artist).
3. Device file deleted or added behind the app's back (stale catalog): file-system check before every write; a Replace whose old file is already gone must not fail the transfer.
4. Same album sent twice in one batch (duplicate source files in a crate): second copy must not be written as ` (2)` nor crash dictionary building.
5. Case-insensitive FAT/exFAT device: `Song.MP3` on device vs planned `song.mp3` is the same path.

Each has a test named in the owning task below.

---

### Task 1: Matcher (Core)

**Files:**
- Create: `Sources/CrateDiggerCore/Services/DeviceTransfer/DeviceAlbumIdentity.swift`
- Create: `Sources/CrateDiggerCore/Services/DeviceTransfer/DeviceTransferMatcher.swift`
- Test: `Tests/CrateDiggerCoreTests/DeviceTransferMatcherTests.swift`

**Interfaces — Produces:**

```swift
public struct DeviceAlbumIdentity: Hashable, Codable, Sendable {
    public let artist: String   // folded artist bucket
    public let album: String    // folded, disc suffix stripped
    /// One identity per track id, reconciled across the set via
    /// OutputPathPlanner.albumFolderKeys (year dropped, then case/diacritic folded).
    public static func identities(for tracks: [LoadedTrack]) -> [UUID: DeviceAlbumIdentity]
}

public enum DeviceAlbumStatus: String, Sendable { case new, present, gaps, differs }
public enum DeviceAlbumDifference: String, Hashable, Sendable {
    case audioForm, artSize, differentRelease, pathTaken
}

public struct DeviceAlbumComparison: Identifiable, Sendable {
    public var id: DeviceAlbumIdentity { identity }
    public let identity: DeviceAlbumIdentity
    public let displayArtist: String, displayAlbum: String
    public var status: DeviceAlbumStatus
    public var differences: Set<DeviceAlbumDifference>
    public let sent: [LoadedTrack]
    public let missing: [LoadedTrack]                      // sent, no counterpart
    public let same: [LoadedTrack]                         // sent, counterpart same form
    public let changed: [(sent: LoadedTrack, device: LoadedTrack)]
    public let deviceTracks: [LoadedTrack]                 // the compared copy, all of it
    public let deviceFolder: URL?                          // folder of the compared copy
    public let deviceCopyCount: Int
    public let sentArtPixels: Int?, deviceArtPixels: Int?  // longest side
    public let isLeftAlone: Bool                           // remembered Leave it
}

public struct DeviceTransferMatcher {
    public init()
    public func compare(
        sending: [LoadedTrack],
        catalog: [LoadedTrack],
        settings: ExternalDeviceTransferSettings,
        leftAlone: Set<DeviceAlbumIdentity>
    ) -> [DeviceAlbumComparison]   // order of first appearance in `sending`
}
```

Rules are the spec's section 1 verbatim. Pinned details:
- Slot = (disc ?? 1, trackNumber); either side lacking a number falls back to folded title within the identity.
- Copy mode (`settings.mode == .copyOriginals`): audio form = (formatName lowercased, bitrateKbps, sampleRateHz); lossless formats ignore bitrate. Convert mode: audio form never compared.
- Art: device pixels = longest side of the device copy's first track with `artworkDimensions`. Sent pixels = longest side that would land: copy mode → source art side; convert mode → by `settings.artworkMode` (Task 3 adds it; until then read `artworkMaxDimension`: nil → source side, n → min(source, n)); when folder art is on, max with min(source, `FolderCoverArtWriter.defaultMaxDimension`). A difference only when both sides are non-nil and unequal, or the device has none and something would be sent.
- Different release: any slot-matched pair with different folded titles, or both sides carry `trackTotal` and totals differ.
- Several device folders sharing an identity are separate candidates; any candidate yielding Present wins; else most matched tracks; `deviceCopyCount` reports how many.
- `isLeftAlone` albums keep their computed status; callers filter.
- Duplicate source tracks in `sending` (same file path) are de-duplicated first.

- [ ] **Step 1: Write failing tests** in `DeviceTransferMatcherTests`, one per rule, using small `LoadedTrack` fixtures built by a local helper `track(album:artist:albumArtist:disc:number:title:format:bitrate:path:art:trackTotal:)`:
  `testEmptyDeviceIsNew`, `testAllSameIsPresent`, `testSubsetOfFullDeviceAlbumIsPresent`, `testPartialDeviceAlbumIsGaps`, `testDisjointTracksOfSameAlbumAreGaps`, `testBetterFormatDiffersOnCopyDevice`, `testFormatIgnoredOnConvertDevice`, `testArtSizeDiffers`, `testSameArtSizeDifferentHashIsSame`, `testDifferentTitleAtSameSlotIsDifferentRelease`, `testDifferentTrackTotalIsDifferentRelease`, `testYearDoesNotSplitIdentity`, `testTwoCopiesOneSameIsPresent`, `testTwoCopiesPicksMostMatched`, `testNoTrackNumbersMatchByTitle` (Review Focus 1), `testCompilationWithoutAlbumArtistIsOneAlbum` (Review Focus 2), `testDuplicateSourcePathsCountedOnce` (Review Focus 4), `testLeftAloneFlagged`.
- [ ] **Step 2:** `scripts/test.sh --filter DeviceTransferMatcherTests` fails to compile.
- [ ] **Step 3:** Implement the two files.
- [ ] **Step 4:** Filter passes; full `scripts/test.sh` passes.
- [ ] **Step 5:** Commit `feat(devices): match albums sent against the device catalog`.

### Task 2: Stored settings and stores (Core)

**Files:**
- Modify: `Sources/CrateDiggerCore/Models/ExternalDeviceProfile.swift`
- Modify: the file defining `DeviceSyncQueueEntry` (find with grep)
- Modify: `Sources/CrateDiggerCore/Services/DeviceCatalogStore.swift`
- Create: `Sources/CrateDiggerCore/Services/DeviceTransfer/DeviceLeftAloneStore.swift`
- Test: `Tests/CrateDiggerCoreTests/ExternalDeviceTransferSettingsArtworkTests.swift`, extend `DeviceCatalogStoreTests`, `DeviceSyncQueueStoreTests`, new `DeviceLeftAloneStoreTests`

**Interfaces — Produces:**

```swift
// ExternalDeviceTransferSettings
public var artworkMode: ArtworkMode          // embedded art in written files
public var writesFolderCoverArt: Bool
// ExternalDeviceProfile
public var usesFolderCoverArt: Bool { transferSettings.writesFolderCoverArt }
// conversionPreset reads artworkMode; the embeddingArtwork: parameter is removed
// and every caller updated.

public enum DeviceAlbumDecision: String, Codable, Sendable { case replace, keepBoth, leave }
// DeviceSyncQueueEntry
public var decision: DeviceAlbumDecision?    // nil = none recorded

// DeviceCatalogStore
public func patch(key: String, adding: [LoadedTrack], removingPaths: Set<String>)
/// A catalog record for a file this app just wrote: the source's tags, the
/// destination URL, and the output format/bitrate/sample rate when converted.
public static func writtenTrack(source: LoadedTrack, destination: URL,
                                preset: ConversionPreset?) -> LoadedTrack

public struct DeviceLeftAloneStore {   // <AppSupport>/CrateDigger/DeviceLeftAlone/<profileID>.json
    public init(directory: URL? = nil, fileManager: FileManager = .default)
    public func load(profileID: UUID) -> Set<DeviceAlbumIdentity>
    public func insert(_ ids: Set<DeviceAlbumIdentity>, profileID: UUID)
    public func remove(_ ids: Set<DeviceAlbumIdentity>, profileID: UUID)
    public func clear(profileID: UUID)
}
```

Decode defaults (the profile decodes the settings, and only the profile knows the kind, so the migration lives in `ExternalDeviceProfile.init(from:)` or an equivalent post-decode fix-up; settings alone decode absent keys as `artworkMode` = `.preserve` when `artworkMaxDimension == nil` else `.compatReembed`, `writesFolderCoverArt` = false):
- Saved profile of kind `rockboxIPod` without the keys → `artworkMode = .none`, `writesFolderCoverArt = true`.
- Any other kind without the keys → the settings-level default above, folder art false.
- Keys present → used as stored, whatever the kind.
- The built-in Rockbox suggestion/default profiles (see `ExternalDeviceProfile.swift` around the `artworkMaxDimension: 600`/`300` initialisers and `DeviceProfileSuggester`) set Strip + folder art on explicitly.
- `patch` on a missing catalog file is a no-op (nothing to patch; next browse scans). Paths compare case-insensitively (Review Focus 5).

- [ ] **Step 1: Failing tests:** `testLegacyRockboxProfileDecodesStripPlusFolderArt`, `testLegacyGenericProfileWithCapDecodesReembedNoFolderArt`, `testLegacyGenericProfileWithoutCapDecodesKeep`, `testStoredKeysWinOverKind`, `testPresetReadsArtworkMode`, `testLegacyQueueEntryDecodesNilDecision`, `testPatchAddsAndRemoves`, `testPatchRemovalIsCaseInsensitive`, `testPatchWithoutCatalogIsNoOp`, `testWrittenTrackCarriesOutputFormat`, `testLeftAloneRoundTrip`, `testLeftAloneClear`. Legacy JSON fixtures are literal strings in the tests, copied from what today's encoder produces (encode a value on this branch before changing the type, paste it).
- [ ] **Step 2:** Run, see failures.
- [ ] **Step 3:** Implement; update all `conversionPreset(embeddingArtwork:)` and `usesFolderCoverArt` call sites so behaviour for existing profiles is unchanged.
- [ ] **Step 4:** Full `scripts/test.sh` passes.
- [ ] **Step 5:** Commit `feat(devices): store art mode, folder-art switch and review decisions`.

### Task 3: Resolver (Core)

**Files:**
- Create: `Sources/CrateDiggerCore/Services/DeviceTransfer/DeviceTransferResolver.swift`
- Test: `Tests/CrateDiggerCoreTests/DeviceTransferResolverTests.swift`

**Interfaces — Consumes:** Task 1 types, Task 2 `DeviceAlbumDecision`, `ExternalDeviceTransferPlanner`, `OutputPathPlanner` (`avoidExistingFiles: false`).

**Produces:**

```swift
public struct DeviceTransferReview: Sendable {
    public let albums: [DeviceAlbumComparison]        // all, pathTaken folded in
    public var needingDecision: [DeviceAlbumComparison] // status == .differs && !isLeftAlone
    public let newTrackCount: Int, presentTrackCount: Int
    public let gapAlbumCount: Int, leftAloneAlbumCount: Int
}

public struct DeviceTransferFilePlan: Sendable {
    public struct Copy: Hashable, Sendable {
        public let source: LoadedTrack
        public let destinationURL: URL
        public let overwrites: Bool          // destination exists and is being replaced
        public let kind: Kind                // .new, .gap, .replacement, .keptBoth
    }
    public let copies: [Copy]
    public let deletions: [URL]              // run AFTER all copies; never includes a copy's destination
    public let coverFolders: [URL: LoadedTrack]  // folders that get a cover.jpg, with the track whose art to use
    public let skippedPresent: Int, leftAlone: Int
    public let replacedAlbums: Int, keptBothAlbums: Int, gapAlbums: Int
}

public struct DeviceTransferResolver {
    public init(fileManager: FileManager = .default)
    public func review(sending: [LoadedTrack], catalog: [LoadedTrack],
                       profile: ExternalDeviceProfile, mountedAt root: URL,
                       leftAlone: Set<DeviceAlbumIdentity>) -> DeviceTransferReview
    public func resolve(_ review: DeviceTransferReview,
                        decisions: [DeviceAlbumIdentity: DeviceAlbumDecision],
                        profile: ExternalDeviceProfile, mountedAt root: URL) -> DeviceTransferFilePlan
}
```

Pinned behaviour (spec sections 1, 3):
- `review` runs the matcher, then plans New and Gaps destinations and checks the file system: a planned path that exists but belongs to no matched device track turns that album into `.differs` with `.pathTaken`. Path comparison is case-insensitive.
- New: planned by `ExternalDeviceTransferPlanner` rules with natural names.
- Gaps: written into `deviceFolder` (same file-name rule as normal planning), in folder-template mode; in `flat`/`sourceRelative`, planned normally.
- Differs + `.replace`, same release: each `changed` pair → copy to the device folder; the old file is deleted unless the new file has the same path (then `overwrites = true`). `missing` tracks are copied too. Unmatched device tracks stay.
- Differs + `.replace`, different release: every sent track is copied into the device folder; every `deviceTracks` file not overwritten is deleted.
- Differs + `.replace` with `.pathTaken` only: overwrite the taken path.
- Differs + `.keepBoth`: template mode → sibling folder named by the same rule as `nextAvailableVersionFolderName` (move that helper's logic into Core here and have the app call it); folderless modes → ` (2)` file names.
- Differs + `.leave`, or no decision for a differing album, or `isLeftAlone`: nothing planned, counted in `leftAlone`.
- Present: nothing planned, counted in `skippedPresent` (tracks).
- Deletions only ever contain audio files from `deviceTracks`. `cover.jpg` is replaced by the cover writer, not deleted.
- No two copies share a destination; a batch-internal clash on a device gets the album sent to the sheet as `.pathTaken`, not a suffix.

- [ ] **Step 1: Failing tests** against a temp-dir "device" with real (empty) files: `testNewAlbumPlansNaturalPaths`, `testGapsLandInExistingDeviceFolderEvenWhenTemplateDiffers`, `testReplaceSameReleaseSwapsOnlyMatchedTracks`, `testReplaceSamePathOverwritesAndDoesNotDelete`, `testReplaceDifferentReleaseDeletesWholeDeviceAlbum`, `testKeepBothUsesVersionFolder`, `testKeepBothFlatUsesSuffix`, `testLeaveAndUndecidedPlanNothing`, `testPresentPlansNothing`, `testTakenUnmatchedPathBecomesDiffers`, `testTakenPathCaseInsensitive` (Review Focus 5), `testDeletionsNeverIncludeNonAudioOrCopyDestinations`, `testNoDuplicateDestinations`.
- [ ] **Step 2–4:** fail, implement, pass (filter then full suite).
- [ ] **Step 5:** Commit `feat(devices): resolve review decisions into a file plan`.

### Task 4: Review sheet (App)

**Files:**
- Create: `Sources/CrateDiggerApp/UI/ExternalDevices/DeviceReviewSheetController.swift` (NSViewController hosting SwiftUI, `onDecision` closure, like `AlbumFolderReviewSheetController`)
- Create: `Sources/CrateDiggerCore/Services/DeviceTransfer/DeviceReviewRow.swift` (Core: the row's text, tested)
- Test: `Tests/CrateDiggerCoreTests/DeviceReviewRowTests.swift`

**Interfaces — Produces:**

```swift
// Core
public struct DeviceReviewRow: Identifiable, Sendable {
    public let id: DeviceAlbumIdentity
    public let title: String, artist: String
    public let onDevice: String      // "MP3 128k · 5 tracks · art 600 px"
    public let sending: String       // "FLAC 16/44.1 · 11 tracks · art 1400 px"
    public let note: String?         // "2 copies on device", "A different file already uses this name"
    public let replaceEffect: String // "Replaces 5 of 11 tracks" / "Replaces the whole album, 11 tracks removed"
    public init(_ comparison: DeviceAlbumComparison, settings: ExternalDeviceTransferSettings)
}
public struct DeviceReviewState: Sendable {   // the sheet's decidable state
    public var decisions: [DeviceAlbumIdentity: DeviceAlbumDecision]
    public func canConfirm(rows: [DeviceReviewRow]) -> Bool   // every visible row decided
    public mutating func setAll(_ d: DeviceAlbumDecision, rows: [DeviceReviewRow])
}
// App
@MainActor func presentDeviceReview(_ review: DeviceTransferReview, deviceName: String,
    settings: ExternalDeviceTransferSettings, presentingFrom host: NSViewController)
    async -> [DeviceAlbumIdentity: DeviceAlbumDecision]?   // nil = cancelled
```

Sheet content (spec section 3): title "Already on <device>"; summary line "120 new · 14 already there · 6 albums to finish"; "Set all to…" control; one row per album needing a decision with a three-way Replace / Keep both / Leave it control, none selected; a "Show N albums left alone" toggle that adds the remembered ones as rows (pre-set to Leave it, since that is their recorded answer); Cancel and a confirm button disabled until `canConfirm`. Carbon theming via `.carbonThemed`, system controls, no custom chrome beyond what sibling sheets use. Scrolls for long lists; fixed width, height capped to the window.

DEBUG hook: env `CRATEDIGGER_DEVICE_REVIEW=1` presents the sheet at launch with six fabricated rows covering each difference kind, so it can be captured without a device (pattern: the other `CRATEDIGGER_*` DEBUG hooks; grep `CRATEDIGGER_COMPACT`).

- [ ] **Step 1:** Failing `DeviceReviewRowTests`: `testQualityUpgradeRowText`, `testDifferentReleaseReplaceEffect`, `testPartialReplaceEffectCounts`, `testTwoCopiesNote`, `testPathTakenNote`, `testConvertDeviceOmitsFormatWhenNotCompared`, `testCanConfirmNeedsEveryRow`, `testSetAll`.
- [ ] **Step 2–3:** fail, implement Core, then the controller and view.
- [ ] **Step 4:** `swift build` and full tests pass. Launch with the hook and a scratch crates dir, capture the window with `screencapture -l <windowID>` to `.build/device-review/sheet.png`, look at it (Read the PNG), fix layout defects, `pkill -f CrateDiggerApp`.
- [ ] **Step 5:** Commit `feat(devices): review sheet for albums already on the device`.

### Task 5: Shared review flow + copy-mode path + catalog upkeep (App)

**Files:**
- Create: `Sources/CrateDiggerApp/UI/ExternalDevices/LibraryViewModel+DeviceReview.swift`
- Modify: `Sources/CrateDiggerApp/UI/ExternalDevices/LibraryViewModel+ExternalDeviceTransfer.swift` (`runExternalDeviceCopy`, `runCopyTransferQueue`, FIX ART)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` (device catalog helpers near `invalidateDeviceCatalog`, `selectDevice`)
- Core, if a decidable piece appears (e.g. summary text): `Sources/CrateDiggerCore/Services/DeviceTransfer/DeviceTransferSummary.swift` + test

**Interfaces — Produces (view model):**

```swift
/// Saved catalog, or a fresh whole-volume scan (same scan and key as browsing,
/// SCAN progress + busy job) when there is none. nil = cancelled/failed.
@MainActor func currentDeviceCatalog(for device: MountedDevice) async -> [LoadedTrack]?
/// review → sheet (only if needingDecision is non-empty) → remembered Leave it
/// → resolved plan. nil = user cancelled. Persists new Leave it choices and
/// removes ones the user changed.
@MainActor func reviewedDevicePlan(tracks: [LoadedTrack], profile: ExternalDeviceProfile,
    mountedRoot: URL, catalog: [LoadedTrack], presentingFrom host: NSViewController)
    async -> (plan: DeviceTransferFilePlan, review: DeviceTransferReview)?
/// After any device write: patch the saved catalog and the in-memory device
/// index cache (replaces invalidateDeviceCatalog for write paths).
@MainActor func patchDeviceCatalog(for device: MountedDevice, adding: [LoadedTrack], removingPaths: Set<String>)
// Core
public struct DeviceTransferSummary { public static func statusLine(copied:alreadyThere:gapAlbums:replaced:keptBoth:leftAlone:failed:) -> String }
```

Behaviour:
- `runExternalDeviceCopy` uses `currentDeviceCatalog` + `reviewedDevicePlan`, then executes `plan.copies` (existing copy loop; for `overwrites` remove the destination first; check `fileExists` right before each write and fail that item with "A file appeared at this name" if a non-overwrite destination is suddenly taken), then `plan.deletions` (a missing file is not an error, Review Focus 3), then covers via `writeFolderCoverArt` for `plan.coverFolders`, then `patchDeviceCatalog`, then the summary. Free-space preflight counts only `plan.copies`.
- When the plan has no copies and no deletions, show an info alert "Nothing to transfer" with the status line ("14 already there" etc.) instead of running.
- FIX ART and the existing post-SYNC invalidation stay correct: FIX ART changes art only, so it invalidates as today (art sizes in the catalog would otherwise be stale); note this in a comment.
- If the browsed source is this device, refresh it after the patch.

- [ ] **Step 1:** Failing Core test `DeviceTransferSummaryTests` (`testAllCounts`, `testOmitsZeroParts`, `testSingulars`).
- [ ] **Step 2:** Implement Core summary, then the view-model flow.
- [ ] **Step 3:** `swift build`, full `scripts/test.sh` pass.
- [ ] **Step 4:** Manual check against a **fake device**: none is possible without a mounted profile, so instead add an App-level test if `CrateDiggerAppTests` can reach the copy executor; otherwise extract the executor (copies → deletions, with the pre-write existence check) into Core as `DeviceTransferExecutor.run(_ plan:, copy:, onProgress:)` with tests `testDeletesAfterCopies`, `testMissingOldFileIsNotAFailure`, `testAppearedFileFailsThatItemOnly`, `testOverwriteReplaces`. Prefer the extraction.
- [ ] **Step 5:** Commit `fix(devices): copy only what is missing, ask about what differs`.

### Task 6: Convert-mode device runs (App)

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Conversion/LibraryViewModel+Conversion.swift`
- Modify: `Sources/CrateDiggerApp/UI/ExternalDevices/LibraryViewModel+ExternalDeviceTransfer.swift`

**Interfaces — Consumes:** Task 5's `currentDeviceCatalog`, `reviewedDevicePlan`, `patchDeviceCatalog`, `DeviceTransferExecutor`.

Behaviour: in `runConversion`, when `pendingDeviceConversion != nil`, skip the version-folder prompt and the Skip/Overwrite alert and instead build the reviewed plan. The cockpit's current `conversionSelection` is the truth for this run: build a transient `ExternalDeviceTransferSettings` from it (the inverse of `seededConversionSelection`) for the matcher and resolver. Turn `plan.copies` into `ConversionJob`s (`overwrites` → ffmpeg `-y` already replaces), run them, then for jobs that succeeded run the matching deletions (a deletion is skipped when its replacement failed), covers, catalog patch (`writtenTrack` with the preset), summary via `DeviceTransferSummary`. Non-device conversions are untouched. The per-album folder review (`applyMode == .reviewPerAlbumPreflight`) stays ahead of it for device runs and its reviewed folder names feed New albums only.
`transferToDevice` stops forcing `artworkMode = .none`; `seededConversionSelection` reads the profile's `artworkMode` (Task 2 made Rockbox profiles Strip by default, so nothing changes for them).

- [ ] **Step 1:** Core test for the selection → settings mapping if it lands in Core (`testSelectionRoundTripsThroughSettings`); else App test in `CrateDiggerAppTests`.
- [ ] **Step 2:** Implement.
- [ ] **Step 3:** `swift build`, full tests pass.
- [ ] **Step 4:** Commit `feat(devices): convert runs use the device review`.

### Task 7: Offline queue and SYNC (App)

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/ExternalDevices/LibraryViewModel+DeviceSync.swift`

Behaviour (spec section 4, offline):
- `stageForSync`: after the existing queue de-dupe, run `reviewedDevicePlan`-style review against the last-known catalog (`deviceCatalogStore.load(key: catalogKey(for: profile))`, empty when none) with the staging root standing in for the mounted root for path planning. Queue one entry per planned copy with its album's `decision` recorded (`nil` for New/Gaps); Present tracks and Leave it albums are not queued and are named in the "Queued for…" alert's count.
- `syncQueuedTransfers`: get `currentDeviceCatalog`, re-run the review on the queued tracks against the real device. Albums that need a decision and whose entries carry none (or whose stored decision no longer applies, e.g. recorded for a comparison that is now New) are shown in the sheet before anything is written; stored decisions that still fit are passed in as already-made and are not asked again. Then resolve and execute with the existing per-entry loop semantics kept: staged bytes used when baked, stale-bake re-conversion, convert-on-the-way for unbaked, checkpointed queue rewrite, staged file removed when done. Entries that resolve to nothing (Present / Leave it) leave the queue and count as "already there" / "left alone". Deletions run after their replacements succeed. Catalog patched instead of invalidated. Cancelled sheet = SYNC does nothing.
- Destination for each entry comes from the resolved plan (a Gaps entry may land in a different folder than `destinationRelativePath` recorded at queue time; update the entry or use the plan's URL).

- [ ] **Step 1:** Any decidable piece (which stored decisions still apply) goes in Core as `DeviceTransferResolver.applicableDecisions(stored:review:) -> [DeviceAlbumIdentity: DeviceAlbumDecision]` with tests `testStoredReplaceStillAppliesWhenDiffers`, `testStoredDecisionDroppedWhenAlbumNowNew`, `testNilDecisionOnDifferingAlbumNeedsAsking`.
- [ ] **Step 2:** Implement.
- [ ] **Step 3:** `swift build`, full tests pass.
- [ ] **Step 4:** Commit `feat(devices): queue and sync use the device review`.

### Task 8: Folder-art switch and art mode in the UI (App)

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/ExternalDevices/DevicesPreferencesView.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Conversion/ConvertPatchBay.swift`
- Modify: `Sources/CrateDiggerApp/UI/ConversionOptionsSheetController.swift` (`ConversionOptionsSelection.writesFolderCoverArt`, default false, decodes when absent)
- Modify: `Sources/CrateDiggerApp/UI/Conversion/LibraryViewModel+Conversion.swift` (`seededConversionSelection`, `persistSelectionToDevice`, cover writing for non-device runs)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Header/OLEDDisplay.swift` (DEVICES Artwork cell)
- Core: `Sources/CrateDiggerCore/Services/DeviceTransfer/DeviceArtworkReadout.swift` + test

**Produces (Core):**
```swift
public enum DeviceArtworkReadout {
    /// (value, sub) for the DEVICES Artwork cell.
    /// Strip + folder → ("400 px", "cover.jpg"); Keep → ("KEEP", "Embedded");
    /// Re-embed 600 → ("600 px", "Embedded"); Keep + folder → ("KEEP", "+ cover.jpg");
    /// Re-embed 600 + folder → ("600 px", "+ cover.jpg"); Strip, no folder → ("NONE", "Stripped").
    public static func cell(mode: ArtworkMode, maxDimension: Int?, folderArt: Bool) -> (value: String, sub: String)
}
```

Behaviour:
- Preferences ▸ Devices, per profile: an Artwork control (Keep / Re-embed / Strip, with the existing size field enabled for Re-embed), a "Folder art (cover.jpg)" toggle, and a "Forget albums left alone" button (calls `DeviceLeftAloneStore.clear`, disabled when empty). Choosing kind Rockbox iPod for a new profile sets Strip + folder art on.
- Patch Bay options tab: a "Folder Art" row (On / Off `PatchBayBank`) under Art Size, bound to `conversionSelection.writesFolderCoverArt`. For device runs it is seeded from and saved back to the profile; for ordinary conversions it persists with the selection.
- `runConversion` writes covers when the selection's switch is on, device or not (`writeFolderCoverArt` currently bails without a folder-art profile; give it a path that takes the flag).
- Copy-mode and SYNC paths already go through `usesFolderCoverArt`, now the setting.

- [ ] **Step 1:** Failing `DeviceArtworkReadoutTests` with the six cases above, and a decode test for `ConversionOptionsSelection` without the key (App tests).
- [ ] **Step 2:** Implement.
- [ ] **Step 3:** `swift build`, full tests pass. Launch with a scratch crates dir, capture Preferences ▸ Devices and the Patch Bay options tab, check them by eye, fix, kill the app.
- [ ] **Step 4:** Commit `feat(devices): folder art is a switch, art mode is stored per device`.

### Task 9: Docs

**Files:** `CLAUDE.md` (new "Device transfers" subsection under Sources model: the review sequence, the matcher's identity rule, patch-not-invalidate, the folder-art switch, the DEBUG hook, and the rule "a new device writer goes through `reviewedDevicePlan` and `patchDeviceCatalog`"), `CHANGELOG.md` (`## 2.3.4` section, user-facing lines), README/guide only if they describe device artwork or duplicates today (grep).

- [ ] **Step 1:** Write. **Step 2:** Full tests pass. **Step 3:** Commit `docs: device review, catalog upkeep and folder art`.
