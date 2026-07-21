# Pre-Transfer to Device ("Sync") — Design

**Date:** 2026-07-21
**Status:** Approved (approach + design approved in session; user waived spec re-review)

## Problem

Transferring to an external device (⌘⇧T) requires the volume to be mounted; if it
isn't, the user gets a folder prompt. There is no way to prepare a device payload
— pick tracks, convert, organize — while the device is in a bag, then land it all
with one action at mount time.

## Solution overview (Approach A: staged-tree mirror)

Queue tracks for a saved `ExternalDeviceProfile` while its device is offline.
Conversion work is **pre-baked at queue time** into a local per-profile staging
folder whose layout mirrors the final device-relative paths. When the device
mounts, **Sync** is a dumb, restartable copy-if-absent loop from the staged tree
(or straight from source for copy-mode profiles) into `root/<musicSubpath>/`.

Decisions locked in session:

- Pre-bake on queue (Sync = fast copy).
- Devices section in Sources lists **all saved profiles, always** (offline = dimmed).
- **Additions only** — no staged deletions, no mirror sync.
- Offline device view shows **cached catalog + queued tracks** (badged PENDING).
- Queue entry point is the **existing Transfer to Device action**, made offline-aware.
- Sync is **manual** (button), never automatic on mount.
- OLED must narrate both phases (bake = Cnvrt pane, sync = DEV pane).
- **No trash**: staging bytes exist only when strictly needed and are deleted
  as soon as they've served their purpose.
- Side feature: all Sources section headers become collapsible (chevron),
  collapsed state persisted.

## 1. Data model (CrateDiggerCore)

### `DeviceSyncQueueEntry` (new, `Models/`)

```swift
public struct DeviceSyncQueueEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var track: LoadedTrack            // Codable; artwork by hash, stays small
    public var destinationRelativePath: String // relative to device music dir, e.g. "Artist/2001 Album/01 Song.m4a"
    public var isStaged: Bool                // true = baked file exists at stagingDir/destinationRelativePath
    public var sourceModifiedAt: Date        // source file mtime at bake time (staleness guard)
    public var queuedAt: Date
}
```

The staging tree mirrors the destination tree, so a baked entry's local file is
always `stagingDir/<destinationRelativePath>` — no second path field. Copy-mode
entries have `isStaged == false`: sync copies straight from source and no bytes
are ever duplicated locally for plain copies.

### `DeviceSyncQueueStore` (new, `Services/`, mirrors `DeviceCatalogStore`)

- Queue JSON: `Application Support/CrateDigger/DeviceSyncQueues/<profileID>.json`
  (an encoded `[DeviceSyncQueueEntry]`).
- Staging tree: `Application Support/CrateDigger/DeviceStaging/<profileID>/`.
- API: `load(profileID:) -> [DeviceSyncQueueEntry]`, `save(_:profileID:)`,
  `remove(profileID:)` (queue JSON + entire staging dir),
  `stagingDirectory(for profileID:) -> URL`,
  `removeStagedFile(for entry:profileID:)` (file + prune now-empty parent dirs),
  `sweepOrphans(validProfileIDs:)` (delete queues/staging for deleted profiles).
- Pure `FileManager` work; injectable directory for tests (same pattern as
  `DeviceCatalogStore`).

## 2. Queueing / bake (app layer + existing Core pipeline)

`LibraryViewModel+ExternalDeviceTransfer.transferToDevice(profileID:tracks:)`
gains one branch: when the profile's volume is **not mounted**, call
`stageForSync(profile:tracks:)` instead of prompting for a folder.

`stageForSync`:

1. Dedup: drop tracks whose source path already has a queue entry for this profile.
2. Plan destination relative paths with the existing `ExternalDeviceTransferPlanner`
   / `OutputPathPlanner` (collision-safe against existing queue entries).
3. **Convert-mode** profiles: local free-disk preflight (existing estimate
   helper), then run the normal conversion pipeline with the staging dir as
   destination root — `oledView = .conversion`, `ConversionProgressSnapshot`
   updates, exactly like a live convert-during-transfer does today.
4. **Copy-mode** profiles: write entries with `isStaged = false`. No I/O.
5. Save queue, refresh sidebar badge. Bake failures: entry not added, surfaced
   via `appAlert`.

## 3. Sources & browsing (app layer)

- `LibrarySource` gains `case offlineDevice(profileID: UUID)`.
- `SourcesSidebar` Devices section lists **all saved profiles**:
  - Mounted (matched by `ExternalDeviceProfile.match`): today's row + behavior.
  - Offline: dimmed row, profile icon, queue-count badge when non-empty;
    selecting it → `selectSource(.offlineDevice(profileID:))`.
- Offline selection builds `LibraryIndex.build(from: cachedCatalog + queuedTracks)`
  where `cachedCatalog = DeviceCatalogStore().load(key: profile.volumeUUID ?? profile.name)`
  (same `catalogKey` a mounted scan saves under). Queued tracks are badged
  **PENDING** in browser rows (membership test: source path ∈ queue).
- Context menu on a pending track/album: **Remove from Sync Queue** — removes
  entries + staged files (+ prunes empty dirs).
- Mounted device with a non-empty queue: **SYNC n** button in the browser
  header; also exposed via the device row context menu.

### Collapsible Sources sections (side feature)

Every `sectionHeader` in `SourcesSidebar` gets a chevron toggle. Collapsed set
persisted in `PreferencesStore` as `collapsedSourceSections: [String]` (section
title strings). Default: all expanded.

## 4. Sync (app layer)

Manual action, only available while mounted. Per run:

1. Preflight: device free space vs. total staged/source bytes (existing
   `validateDeviceTransferPreflight` pattern).
2. For each entry, in order:
   - **Staleness**: if source file mtime ≠ `sourceModifiedAt`, re-bake that entry
     first (same conversion path; copy-mode entries just refresh the mtime).
   - Destination `root/<musicSubpath>/<destinationRelativePath>`; **skip if the
     file already exists** (still counts as done).
   - Copy from staging (baked) or from source (copy-mode). Create intermediate dirs.
   - On success: delete the staged file **immediately**, prune empty dirs,
     remove entry from queue, persist queue (so interruption loses nothing).
   - On failure: entry stays queued; continue with the rest.
3. End: report `synced / skipped / failed` (appAlert, informational). Queue empty →
   staging dir + queue JSON removed. Force device rescan (`selectDevice(forceRescan:)`)
   so the cached catalog reflects the new contents.

Restartability is structural: re-running Sync just processes whatever entries remain.

### OLED

- **Bake phase** drives the existing **Cnvrt** pane (it is a conversion).
- **Sync phase** drives the **DEV pane** (`OLEDView.devices`): header
  `SYNC → <PROFILE NAME>`, the existing dsp-ticker showing the current relative
  path, and an `n/m` progress readout; terminal state `SYNC COMPLETE · N TRACKS`
  (or `N SYNCED · M FAILED`). New published state: a small
  `DeviceSyncProgressSnapshot` (profile name, current path, done, total, failed).

## 5. Disk hygiene ("no trash")

- Copy-mode entries never stage bytes.
- Staged file deleted the moment its copy lands; empty subfolders pruned.
- Queue empty → whole staging dir + queue JSON deleted.
- Removing a queue entry deletes its staged file.
- Deleting a profile calls `DeviceSyncQueueStore.remove(profileID:)`.
- App-launch sweep: `sweepOrphans(validProfileIDs:)` deletes staging/queue data
  for profiles that no longer exist.
- Local free-disk preflight before baking.

## 6. Error handling

- Bake failure → no queue entry, `appAlert` with ffmpeg stderr summary (existing
  conversion error path).
- Sync copy failure → entry retained, end-of-run summary lists the count; DEV
  pane shows failed count.
- Missing source file at sync (user deleted/moved it): a **staged** entry still
  syncs — the baked file no longer needs its source (staleness check is skipped;
  the bake is assumed fresh). A **copy-mode** entry fails, stays queued, and is
  listed in the summary.
- Device unmounted mid-sync → treated as copy failure for the in-flight entry;
  loop stops, remaining entries stay queued.

## 7. Testing (Core, XCTest)

- `DeviceSyncQueueStore`: round-trip, `remove` clears staging, `removeStagedFile`
  prunes empty dirs, `sweepOrphans` deletes only orphans.
- Entry planning: copy-mode → `isStaged == false`; convert-mode → staged file
  lands at `stagingDir/<destinationRelativePath>`.
- Staleness: mtime mismatch detected.
- Dedup: re-queueing same source path is a no-op.

UI wiring (sidebar rows, SYNC button, OLED pane, collapsible headers) is
app-layer and verified manually by the user (⌘R), per project convention.

## Out of scope

- Staged removals / mirror sync.
- Auto-sync on mount.
- Drag-and-drop onto sidebar device rows.
- Background/idle baking (bake runs at queue time, foreground).
