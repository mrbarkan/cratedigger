# Cleanup Rework · FIX TAGS Multi-Album · Status LED — Design

**Date:** 2026-07-19
**Branch:** beta/1.1.0-theming
**Scope:** three independent features in one sprint. Each is separately shippable.

---

## 1. Library Cleanup rework (duplicates)

### Problems

- Duplicate detection is exact lowercased `artist - title` matching: it flags the
  same song on an album + a compilation as a dup, misses real dups with slightly
  different tags, and can group different recordings that share a title.
- The only action is "MOVE DUPLICATES TO TRASH" — all worst tracks across all
  groups, no per-group review.
- `scanForCleanup()` runs synchronously on the main actor and the best-track
  ranking stats file sizes inside the sort comparator (O(n log n) syscalls) —
  beachball risk at 14k tracks.

### Detection (Core — `LibraryCleanupService`, unit-tested)

`findDuplicates(in:mode:ignoring:)` gains a mode and an ignore list.

1. **Normalization** (new helpers, reuse `MetadataNormalization` where it fits):
   lowercase, strip punctuation, collapse whitespace, unify "feat."/"ft.",
   strip decoration suffixes — parenthesized/bracketed tails matching
   remaster/reissue/explicit/mono/stereo patterns (e.g. "(Remastered 2011)",
   "[Explicit]"). "(Live)", "(Radio Edit)" etc. are **not** stripped — those are
   different recordings; the duration guard is the backstop either way.
2. **Candidate grouping:** normalized `artist :: title`.
3. **Duration guard:** within a candidate group, cluster tracks whose
   `durationSeconds` are within **±2s** of each other (greedy: sort by duration,
   split where the gap to the previous track exceeds 2s). Only clusters of 2+
   are duplicate groups. Tracks with unknown duration (≤0) never cluster.
4. **Scan mode** (per-scan toggle, last choice persisted in `PreferencesStore`):
   - **Strict** (default): additionally require the same normalized album tag —
     catches re-rips/re-encodes of the same release only. A missing album tag on
     one copy drops the pair out of strict; documented ceiling.
   - **Broad:** same recording anywhere in the library.
5. **Existing version-group fence stays:** tracks inside a grouped release still
   only match within the same member pressing.
6. **Ranking:** unchanged ordering (lossless > bitrate > sample rate > size),
   but file sizes are stat'd **once** into a `[path: Int64]` before sorting.
7. **Ignore list:** a group whose **signature** is in the ignore list is
   dropped from results. Signature = SHA-256 of the sorted standardized member
   paths. If membership changes (a file added/removed), the signature changes
   and the group resurfaces — intended.

Upgrade path (not built): acoustic fingerprinting via bundled ffmpeg's
chromaprint muxer if metadata matching still misses re-encodes. `ponytail:`
comment at the detection site.

### Scan execution

`scanForCleanup()` moves to a detached task (dead-track existence checks + stat
pass + grouping), hopping back to publish results. The cleanup sheet shows a
progress spinner while scanning. Registers with the activity hub (§3).

### UI (`LibraryCleanupView`, same sheet)

- **Mode toggle** at the top of the Duplicates tab: STRICT / BROAD (Carbon
  switch style). Changing it rescans.
- **Per-row checkboxes:** every file in a group gets a checkbox; the auto-ranked
  worst versions are pre-checked, the best is starred and unchecked. The user
  can flip any row (including checking the "best").
- **Per-group "NOT A DUPLICATE"** button: adds the group signature to the
  persistent ignore list and removes the group from the list immediately.
- **Footer:** "TRASH SELECTED (n)" replaces the nuke button; n is the live
  checked count across all groups. Export buttons stay.
- Missing Tracks tab: unchanged.

### Deletion & crates

New `resolveDuplicates(selected: [LoadedTrack])` (replaces all-or-nothing):

1. Trash the selected files (per-file errors collected, one summary alert).
2. For each trashed track whose group's **best copy survives**, build a
   repoint map `oldPath → best LoadedTrack` and run it through the existing
   `rewriteTrackPaths` mechanics so crates keep the song (now pointing at the
   kept copy) instead of losing the entry. Tracks trashed with no surviving
   groupmate fall back to `purgeTracksFromLibraryState` (reference removed).
3. After repointing, crate saves dedupe by standardized path (first occurrence
   wins) — repointing can otherwise create a double entry in a crate that
   already contained the best copy.
4. `rewriteTrackPaths` becomes internal (currently private) or gains a thin
   internal wrapper.

### Persistence (`PreferencesStore`)

- `duplicateIgnoreSignatures: [String]`
- `duplicateScanMode: String` ("strict" / "broad")

### Tests (`LibraryCleanupServiceTests`)

Normalization cases (feat variants, remaster suffixes, punctuation); duration
clustering (edit vs extended split, ±2s boundary, unknown duration); strict vs
broad album behavior; ignore-list filtering; signature stability; single stat
pass (fake FileManager not required — assert via injected size lookup if
needed, else skip the perf assertion).

---

## 2. FIX TAGS — multi-album selection

### Problem

`MetadataMatchService.query(for:)` collapses the whole selection into one
`ReleaseQuery` (most-common artist/album), so a selection spanning albums gets
matched against a single release; minority-album tracks are shoehorned into it.
The review sheet's pager is candidates-for-one-release, not albums.

### Fix

1. **Partition** (Core, testable): `MetadataMatchService.partitionByAlbum(_
   tracks: [LoadedTrack]) -> [[LoadedTrack]]` grouping by
   `OutputPathPlanner.albumFolderKey(for:)` — the same invariant the browser
   index and conversion planner share. Order: by first appearance in selection.
2. **`matchSelectionOnline`** partitions first, then matches groups
   **sequentially** (MusicBrainz throttle) with OLED progress
   "MATCHING TAGS… 2/5". Single-album selections behave exactly as today.
   Uncapped group count; `ponytail:` comment noting 30 singles = 30 sequential
   lookups.
3. **Queue model** (`LibraryViewModel`):
   - `struct AlbumMatchBatch { let albumLabel: String; let matches: [ReleaseMatch] }`
   - `metadataMatches: [ReleaseMatch]` stays the *current* batch (sheet binding
     unchanged); new `pendingMatchBatches: [AlbumMatchBatch]` plus
     `matchQueueProgress: (current: Int, total: Int)?` for the header.
   - `advanceMatchQueue()` pops the next batch into `metadataMatches`; called
     by APPLY (`applyReleaseMatch`) and by a new SKIP button.
   - Groups with no match are collected; after the last batch, one summary
     alert ("Matched 3 of 5 albums; 2 had no online match…").
   - **Closing the sheet (X / Esc) cancels the remaining queue** — predictable
     escape hatch; SKIP is the per-album pass.
4. **Sheet (`MetadataMatchSheetView`):** header gains "ALBUM 2 OF 5 ·
   <albumLabel>" when a queue is active; footer gains SKIP next to APPLY when
   `matchQueueProgress != nil`. Candidate pager unchanged.
5. Local probe/heal pass is already per-track — unchanged. Local-conflict
   fallback only shows after the queue completes (unchanged single-album
   behavior when there's no queue).

### Tests (`MetadataMatchServiceTests`)

Partition: multi-album selection splits on `albumFolderKey`; order by first
appearance; single-album passthrough. Queue mechanics live in the view model
(untested per repo convention) — keep them thin.

---

## 3. Status LED (global activity indicator)

### Problem

Long operations (index rebuilds, crate I/O, cleanup scan, tag matching) give no
visual feedback; the app looks frozen or idle while working.

### Activity hub (`LibraryViewModel`)

- `@Published private(set) var activities: [UUID: String]`
- `@discardableResult func beginActivity(_ label: String) -> UUID` /
  `func endActivity(_ id: UUID)` — both `@MainActor`; detached tasks call via
  `MainActor.run`. Callers use `defer`-style pairing.
- `var isWorking: Bool` — true when `activities` is non-empty OR any existing
  busy flag is active: `scanProgress`, `conversionProgress`,
  `isRepairingMetadata`, `albumsFetchingArtwork`. Already-instrumented features
  light the lamp with zero changes.
- Instrument in this sprint: cleanup scan, FIX TAGS probe+match, index
  rebuilds (`buildIndex` call sites doing full rebuilds), crate load/save where
  already async, artwork download/import.

### The LED (`StatusLED.swift`, ~40 lines)

- Overlaid at the header's top-right: `HeaderShell` gains
  `.overlay(alignment: .topTrailing)` with small padding — an 8–10px round
  lamp on the chassis, recessed-dark when idle, soft amber breathing pulse
  (~1.6s ease-in-out) while `isWorking`.
- Hover `.help` / tooltip listing active labels joined with " · ".
- **Idle-GPU invariant:** the `repeatForever` animation is attached only while
  `isWorking == true` and fully removed when false (conditional modifier /
  identity swap) — zero compositor cost when idle. Same rule as the Material
  ban.
- No layout shift; purely an overlay.

### Honest scope

The LED shows work; it does not unfreeze main-thread work. The cleanup scan
goes off-main in §1; remaining synchronous spots (full-crate decode on source
switch) are the known 14k perf item, out of this sprint.

---

## Build order

1. §3 activity hub + LED (small, everything else registers with it)
2. §1 cleanup detection (Core + tests) → scan off-main → UI → deletion/repoint
3. §2 partition (Core + tests) → queue → sheet changes

Each lands as its own commit(s); `scripts/test.sh` green between sections.
