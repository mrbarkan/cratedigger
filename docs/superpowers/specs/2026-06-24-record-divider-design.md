# Record Divider — Design Spec

**Date:** 2026-06-24
**Status:** Approved (design); pending implementation plan
**Branch:** feat/v6-ui-redesign

## Problem

A user who digitizes a vinyl record ends up with one long audio file per side (a
continuous WAV/AIFF capture of, say, six songs). CrateDigger should help them
turn that single file into individual tracks: scan the file for track boundaries
(the silent gaps between songs), let the user review the detected tracks, keep or
skip any of them, and fix imperfect boundaries — all without forcing a one-shot
destructive split.

## Goals

- Detect track boundaries inside a single long audio file.
- Let the user review, keep/skip, rename, and lightly correct boundaries.
- **Non-destructive in playback:** the original file stays intact; markers drive
  track navigation (current track, next/previous).
- **Destructive only on export:** the conversion/export step uses the markers as
  cut points to write one file per kept track; skipped regions are excluded.

## Non-goals (YAGNI)

- No Side A + Side B pairing — Record Divider operates on **one file at a time**.
  Run it again for the other side.
- No waveform editor. Boundary correction is numeric (nudge / merge / split-at-time)
  plus a sensitivity re-scan.
- No auto-skipping of skipped regions during playback (they remain audible; "skip"
  only removes them from exported files). Possible later refinement.
- No automatic invocation on import. Entry is a manual command only.

## Confirmed decisions

| Decision | Choice |
|---|---|
| Output model | Hybrid: non-destructive **markers in playback**, **split into files on conversion/export** |
| Entry point | **Manual command only** (right-click a track + an Inspector button) |
| Edit power | **Keep/skip + rename + fix boundaries** (nudge / merge / split-at-time) + sensitivity re-scan |
| Detection | ffmpeg **`silencedetect`** (already bundled) |
| Input scope | **One file at a time** |
| Skipped regions in playback | Still play; excluded only from export |
| Min-track floor | **30 s**; no max length. Detection biased to long/clear silences so long songs aren't split internally |

## Architecture

```
Right-click track / Inspector button
        │  "Record Divider…"
        ▼
RecordDividerService.detect(fileURL:, sensitivity:)   ── Core, testable
        │  ffmpeg silencedetect (CommandRunning) + ffprobe duration
        ▼
[RecordMarker]  (candidate tracks, default titles)
        │
        ▼
RecordDividerSheet  ── App (SwiftUI), keep/skip · rename · nudge/merge/split · re-scan
        │  on confirm
        ▼
LoadedTrack.recordMarkers = [...]  ── persisted into the track's .cdlib crate
        │
        ├───────────────► Playback: markers act as chapters (current track, next/prev seek)
        │
        └───────────────► Conversion: marked track expands into one job per kept marker
                                   (ConversionJob.segment → ffmpeg -ss/-to)
```

### 1. Data model (Core)

- **`RecordMarker`** — new type in `Sources/CrateDiggerCore/Models/`:
  - `startSeconds: Double`, `endSeconds: Double`, `title: String`.
  - `id` derived from `startSeconds` (stable for SwiftUI lists; markers are ordered
    by start time), mirroring `StreamChapter`.
  - `Codable, Sendable, Hashable, Identifiable`.
- **`LoadedTrack`** (in `Sources/CrateDiggerCore/Services/LibraryScanService.swift`)
  gains `recordMarkers: [RecordMarker]?` — **optional** so existing `.cdlib` crates
  (JSON arrays of `LoadedTrack`) still decode. `nil`/empty = an ordinary,
  undivided track.
- One marker = one kept track. Regions of the file not covered by any marker are
  "skipped" — audible in playback, omitted from export.

### 2. Detection service (Core, testable)

- **`RecordDividerService`** in `Sources/CrateDiggerCore/Services/`:
  - `detect(fileURL: URL, sensitivity: Sensitivity) async throws -> [RecordMarker]`.
  - Runs ffmpeg with the `silencedetect` audio filter through the existing
    `CommandRunning` protocol (so tests inject a fake runner returning canned
    stderr). Silence intervals are emitted on **stderr** as
    `silence_start: <t>` / `silence_end: <t> | silence_duration: <d>` lines.
  - Gets total duration via ffprobe (reuse `ExternalToolLocator` / the
    `MetadataProbeService` approach; fall back to parsing ffmpeg output).
  - **Boundary logic:**
    - Tracks are the audio spans *between* detected silences. The cut point for a
      gap is the **midpoint of the silence** (keeps a clean head/tail on each track).
    - Leading silence (lead-in groove) before the first audio is dropped — track 1
      starts at the first `silence_end` (or 0 if no leading silence).
    - The last track ends at file duration.
    - **Min-track-length guard (30 s):** spans shorter than 30 s are merged into
      the previous track, so a brief quiet moment doesn't create a spurious
      track. There is **no maximum** track length — a whole side with no real
      gaps stays a single track.
  - **Bias toward long, clear silences (protect long songs).** True between-songs
    gaps on vinyl are short bursts of *near-total* silence; quiet musical passages
    inside a long song (e.g. *Echoes*, ~25 min) are neither truly silent nor
    sustained that long. To avoid falsely chopping such songs, the **default**
    detection is conservative: a low noise floor (`-38 dB`) and a longer minimum
    silence (`2.0 s`), so only genuine track breaks register. Manual **Merge** in
    the review sheet is the backstop if one slips through.
  - **Sensitivity** maps to the two ffmpeg knobs: noise floor (`-30 dB` …
    `-42 dB`) and minimum silence duration (`1.2 s` … `2.8 s`), centered on the
    conservative default above. Higher sensitivity = more splits.
  - Default titles: `Track 01`, `Track 02`, … (zero-padded to the count).

### 3. Review sheet (App)

- **`RecordDividerSheet`** (SwiftUI, following the `AddStreamSheet` style; presented
  from the Carbon UI). Driven by `LibraryViewModel`.
- Header: source filename + detected-track count + a **sensitivity slider** with a
  **Re-scan** button.
- One row per detected segment:
  - **Keep** toggle (skipped rows dim; excluded from the saved marker set).
  - Index, **editable title** field.
  - Start / End shown as `mm:ss` with **± nudge steppers**.
  - Duration (read-only).
  - Row actions: **Merge with next**, **Split at time…**.
- Footer: **Cancel** / **Apply**.
- **Apply** writes the kept markers onto the `LoadedTrack` and persists it back into
  the crate(s) that hold it (same obligation as tag edits — see Persistence).
- **Re-scan** re-detects from the slider value, replacing rows. Because boundaries
  change, **titles reset to defaults on re-scan** (with a confirm if the user had
  typed custom titles). Numeric edits/merges/splits after a scan are preserved
  until the next re-scan.

### 4. Playback integration (non-destructive)

- In `LibraryViewModel`, when the currently-playing track has `recordMarkers`:
  - Expose `currentRecordTrackIndex` (the marker whose range contains the playhead)
    and `currentRecordTrack`, mirroring the existing `currentChapter` /
    `chapterIndex(at:)` logic used for stream chapters.
  - **Next / Previous** seek to the adjacent marker's start instead of advancing the
    library queue, while a marked file is playing.
  - The OLED now-playing view shows `Track <n>/<total> — <title>` for marked files.
- Playback remains continuous; skipped regions still play.

### 5. Conversion / export integration (the split)

- **`ConversionJob`** (`Sources/CrateDiggerCore/Models/ConversionModels.swift`)
  gains an optional segment: `startSeconds: Double?` + `endSeconds: Double?` (or a
  small `TimeSegment` value). `nil` = whole file (today's behavior).
- **`ConversionService`** inserts `-ss <start>` in the input section (before `-i`)
  and `-to <end>` in the output section when a segment is present. The re-encode
  path handles accurate cutting; for stream-copy a note/guard applies (vinyl rips
  are typically re-encoded).
- **Job planning** (`LibraryViewModel+Conversion` / `OutputPathPlanner`): when a
  selected `LoadedTrack` has `recordMarkers` **and** the split option is on, expand
  it into **one `ConversionJob` per kept marker**:
  - `sourceURL` = the long file (all jobs).
  - `metadata` = the source file's tags (album / album-artist / year / genre)
    **inherited**, with per-marker `title`, and **sequential `trackNumber` /
    `trackTotal`** over the kept markers.
  - `destinationURL` via `OutputPathPlanner.planDestination(...)`, which already
    guarantees collision-safe unique filenames. All markers share the same
    `albumFolderKey`, so the resulting tracks land in one album folder.
  - `segment` = the marker's range.
- **Conversion options** gain a **"Split records into tracks"** toggle, default
  **ON** when any selected track has markers, default OFF / hidden otherwise.

### Persistence

`recordMarkers` is part of `LoadedTrack`, so saving the track to its `.cdlib`
persists the markers. Editing markers must update the track inside **every** crate
that references it — the same invariant as tag edits and `updateTrackURLInIndex`
(CLAUDE.md). The implementation reuses/extends that update path so markers don't go
stale across crates.

## Error handling

- **ffmpeg/ffprobe missing:** the Record Divider command is disabled and surfaces
  the existing "install ffmpeg" guidance (same as conversion).
- **No silences detected** (one continuous capture): return a single marker = the
  whole file and tell the user "No track breaks detected — try higher sensitivity."
- **Very short / unreadable file:** guard and show a clear message; no markers
  written.
- **Detection process failure / non-zero exit:** surface ffmpeg stderr in an alert;
  leave the track unchanged.

## Testing (Core, XCTest)

- `RecordDividerServiceTests`: feed canned `silencedetect` stderr (+ known duration)
  through a fake `CommandRunning`; assert derived markers — gap midpoints, leading-
  silence drop, min-track-length merge, default titles, and sensitivity mapping.
- `RecordMarkerTests`: `Codable` round-trip; `LoadedTrack` with and without
  `recordMarkers` decodes (back-compat with pre-feature crates).
- Split-expansion test: a marked `LoadedTrack` + split option → N jobs with correct
  segments, inherited album metadata, per-track titles, sequential numbers/total,
  and unique destination paths.
- `ConversionService` arg-building: a job with a segment includes `-ss`/`-to` at the
  right positions; a job without one is unchanged.

UI (the sheet, playback next/prev wiring) is verified by the user in the running
app, consistent with the project's untested-UI convention.

## Open questions

None blocking. Future refinements noted as non-goals: Side A/B pairing, auto-skip of
skipped regions in playback, auto-offer on import.
