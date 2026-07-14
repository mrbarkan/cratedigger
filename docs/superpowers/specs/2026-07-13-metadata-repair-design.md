# Metadata Repair ("FIX TAGS") — Design

**Date:** 2026-07-13
**Status:** Approved

## Problem

Tracks imported before the ffprobe-preference fix (or while ffprobe was missing)
were scanned AVFoundation-only, which cannot read FLAC/OGG Vorbis comments —
their track numbers came back `nil` and were frozen into `.cdlib` crates.
`refreshLibrary()` only rebuilds the index from already-loaded tracks; nothing
ever re-probes the files, so the loss is permanent without a repair path.

## Solution

A one-press **FIX TAGS** key in the inspector's Library Tools row (repurposes
the disabled ORGANIZE placeholder) that heals the current source's crate from
the files themselves.

- **Candidates:** tracks in the current source with a missing track number,
  OR a (disc, track#) duplicated within their album (an all-"11"s album is as
  broken as one with blanks — added after field testing). Not every nil
  field — disc number/year are legitimately absent on many files and would
  force a full re-probe per press.
- **Duplicated-number tracks whose file tag echoes the same bad value:** the
  filename-inferred number ("03 - Song.flac") is offered as the conflict's
  file value — tag-vs-tag comparison alone can't see this case because the
  crate was scanned from those very tags.
- **Re-probe:** each candidate goes through the existing
  `LibraryScanService.reloadTrack(at:)` — full pipeline (ffprobe → AVFoundation
  → filename fallback), same as the per-track "Refresh Tags" context action.
- **Merge (fill missing):** blank stored fields take the file's value —
  title, artist, album artist, album, track #/total, disc #/total, year, genre.
- **Conflicts:** stored and file both have a value and they differ → recorded,
  stored value kept. Reported in a review sheet after the run; each row has a
  "use file value" checkbox, Apply/Keep-all buttons.
- **Persistence:** repaired tracks flow through the existing
  `updateTrackURLsInIndex(_:)` batch funnel (Prep Crate + every `.cdlib` saved
  at most once, track store persisted once, index rebuilt).
- **Never writes to audio files.** The file is what we read *from*; only the
  stale crate copy is updated. Zero-risk operation.
- **Gating:** enabled only for file-backed sources (local crates, Prep Crate).

## Components

| Piece | Target | Notes |
|---|---|---|
| `MetadataRepairPlanner` | Core | Pure: `repair(stored:probed:)` → merged metadata + filled fields + conflicts; `adopt(_:from:into:)` applies chosen conflict fields; `needsRepair(_:)` candidacy. Unit-tested. |
| `LibraryViewModel+MetadataRepair` | App | `repairMissingMetadata()`: gather candidates, re-probe sequentially in a Task, merge, batch-persist, publish conflicts + summary alert. |
| `MetadataRepairSheetView` | App | SwiftUI sheet listing conflicts grouped per track; presented from `InspectorPane`. |
| FIX TAGS key | App | Replaces the disabled ORGANIZE key in Library Tools; spinner while running. |

## Testing

XCTests for the planner (fill, conflict, no-op, mixed, adopt, candidacy) in
`Tests/CrateDiggerCoreTests`. View-model wiring untested per project convention;
GUI verified by the user.
