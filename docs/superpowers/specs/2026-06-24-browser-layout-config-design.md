# Browser Layout Config — Design Note

Date: 2026-06-24
Status: Approved

## Goal

Let the user reduce the library browser from the fixed 3-pane
`Artist · Album · Track` to fewer panes, for people who think in albums or just
want a flat track list.

## Modes (approved)

- **`full`** — Artist · Album · Track (current default).
- **`albumTrack`** — Album · Track. The Album pane lists *every* album across
  all artists (honoring album sort); selecting one shows its tracks and also
  sets the underlying artist (so flipping back to `full` is consistent).
- **`track`** — a single flat list of *every* track in the source (honoring
  track sort); click to play, no drill-down.

## Control & persistence

- A compact layout menu in the browser pane header, beside the sort toggle +
  collapse chevron. Shows a check on the active mode. Visible only for the normal
  library browser — hidden in Gallery and Radio modes (like the sort toggle).
- Persisted via `PreferencesStore` (sticks across launches).

## Architecture

- **Core:** `BrowserLayout` enum (`full`/`albumTrack`/`track`), `Codable`,
  `CaseIterable`, with `title`/`shortTitle`/`iconName`. Plus a testable
  `LibraryIndex.allAlbums` helper (flatten artists → albums).
- **PreferencesStore:** `browserLayout` get/set.
- **LibraryViewModel:** `@Published var browserLayout` (loaded/saved through
  prefs); helpers for the sorted flat album list and sorted flat track list;
  album selection in `albumTrack` sets both `selectedAlbumID` + `selectedArtistID`.
- **BrowserPane:** composes columns per mode; the Album and Track columns gain a
  `flat` variant (flat album list / flat all-tracks list, no disc headers).
- **MainShell:** the layout menu in the browser well's trailing controls.

## Behavior notes

- Sort controls keep working in every mode (album sort → flat album list, track
  sort → flat track list).
- The track context menu (Record Divider, Add to Crate, Refresh Tags) is
  unchanged and still applies in every mode.

## Testing

- Core unit test: `BrowserLayout` round-trips its raw values; `LibraryIndex.allAlbums`
  returns every album across artists.

## Out of scope

- Independent per-column hide toggles (presets only, to avoid invalid combos).
- A View-menu mirror of the control (could add later for discoverability/keyboard).
