# FIX TAGS: online metadata matching with field-level review

**Status:** approved design, not yet planned
**Target:** 1.1.0 beta line (`beta/1.1.0-theming`)

## Problem

FIX TAGS today only heals crate-vs-file drift: it re-probes the selected
files' own tags, fills blanks, and surfaces conflicts. It cannot *correct*
metadata — nothing consults an outside source. Fixing a mistagged or
untagged album means hand-editing every field.

## Goal

Select an album / track / multiple tracks → press FIX TAGS → the app looks
up the best release match online → one review sheet shows `current →
proposed` for every field → the user checks which fields to overwrite →
OK → tags written. Straight to the point.

## Sources

**MusicBrainz + iTunes Search** — both free, no API key, no account.
MusicBrainz brings release depth (track lists, album artist, year);
iTunes is fast and already integrated (`RemoteArtworkService`). Discogs is
a future source behind a user token (out of scope for v1).

## Design

### 1. Core: `MetadataMatchService` (new, unit-tested)

```
protocol ReleaseMetadataProvider {           // one impl per source
    func searchReleases(query: ReleaseQuery) async throws -> [ReleaseCandidate]
    func releaseDetail(id: String) async throws -> ReleaseDetail   // tracks
}
struct MusicBrainzClient: ReleaseMetadataProvider   // 1 req/s, User-Agent set
struct ITunesSearchClient: ReleaseMetadataProvider
```

- Both clients take an injectable transport (same pattern as
  `CommandRunning`) so parsing and scoring are tested offline with canned
  JSON fixtures.
- `ReleaseQuery` is built from the selection: existing tags first
  (artist/album/titles), falling back to **path inference** for blank
  fields — parse `"Artist - Album (1997)/03 Title.flac"` shapes from folder
  and file names. Path inference is a pure, tested function.
- **Scoring:** candidates ranked by artist+title string similarity
  (normalized Levenshtein), track-count agreement, and per-track duration
  deltas (± a few seconds). Pure function over value types → heavily
  tested.
- **Track mapping:** selection tracks map to release positions by track
  number, then duration proximity, then title similarity.
- Output: `TagMatchProposal` = ranked `[ReleaseMatch]`, each carrying
  release info (source, title, artist, year, artwork URL) + per-track
  proposed `ConversionMetadata` deltas for the fields in
  `MetadataRepairField` (title, artist, album artist, album, track #/total,
  disc #/total, year, genre).

### 2. Request shape

- Album selected → **one album-level match**: 1 search + 1 release-detail
  request per source (MusicBrainz throttled to 1 req/s).
- Loose track selection → group by `OutputPathPlanner.albumFolderKey` first
  (the app's one definition of "an album"), match per group; singleton
  tracks match by artist+title recording search.
- No network / no candidate above a minimum score → info alert ("No match
  found — check the artist/album tags"), nothing touched.

### 3. UI: match review sheet

Replaces the current conflict sheet **for this flow** (the existing
blank-fill repair and its `MetadataRepairSheetView` remain for crate-drift
conflicts — different job, unchanged).

- **Header:** matched release (source badge, title, artist, year, cover
  thumb) with a candidate switcher (top ~3 alternates re-render the sheet).
- **Field matrix:** one row per field with a checkbox; a field defaults ON
  when any track's proposed value differs from current, OFF when identical
  everywhere. Under each field, per-track `current → proposed` diffs
  (collapsed when the album is uniform, e.g. album/year/genre).
- **OK** applies only checked fields, through the existing tag-write path
  (`MetadataEditorService` file rewrite + every referencing `.cdlib`
  updated via the same code the inspector editor uses). Cancel touches
  nothing.
- Progress while matching shows on the OLED (same transient pattern as
  `oledNotice`); FIX TAGS button disabled during a lookup.

### 4. Wiring

`LibraryViewModel+MetadataRepair` gains the match flow next to the existing
repair pass; the FIX TAGS button (InspectorPane) triggers: probe-refresh the
selection (existing code) → build query → match → present sheet →
apply. All I/O off the main actor; hop back for state.

## Error handling

- Per-source failure is non-fatal: if MusicBrainz errors, iTunes results
  still show (and vice versa). Both failing → the no-match alert with the
  underlying reason.
- Malformed JSON → provider returns empty candidates + `AppLog` entry,
  never throws past the service boundary.
- Tag-write failures reuse the existing per-file error surfacing of the
  metadata editor.

## Testing (Core, XCTest)

- Path inference: filename/folder shapes → expected query fields.
- Scoring: fixture candidates ranked correctly; below-threshold rejected.
- Track mapping: shuffled/short/duration-off selections map correctly.
- Clients: canned MusicBrainz/iTunes JSON → parsed candidates; malformed
  JSON → empty + no throw.
- Apply merge: checked fields overwrite, unchecked preserved.

## Out of scope (v1)

- Discogs provider (future, behind a user token).
- Acoustic fingerprinting (AcoustID/fpcalc — new external tool).
- Fetching/applying artwork from the match (the artwork search sheet
  already covers art; revisit after v1).
- Writing back to files not in the selection.
