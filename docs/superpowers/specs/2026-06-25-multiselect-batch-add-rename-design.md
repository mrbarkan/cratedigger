# Multi-select batch add, SCAN-OLED import status, and inline rename

Date: 2026-06-25
Branch: feat/v6-ui-redesign

## Goals

Three browser/sidebar features for the Prep-Crate → Crate workflow:

1. **Multi-select + batch Add to Crate** — select many albums/tracks (⌘-click, ⇧-click,
   ⌘A) and add them to a crate in one action.
2. **Import status on the SCAN OLED** — adding to a crate shows progress on the SCAN
   display, then reverts.
3. **Inline rename** of user crates and playlists in the Sources sidebar.

## Decisions

- Multi-select applies to **both the Album and Track columns**.
- Rename is triggered by **double-click on the name** *and* a **right-click → Rename**
  menu item.

## Current architecture (verified)

- Selection is single-value: `LibraryViewModel.selectedArtistID/selectedAlbumID/selectedTrackID`.
- Browser rows are custom `ColumnRow` (a `Button(action: onSelect)` + double-tap to
  activate) — **not** a SwiftUI `List`, so multi-select is implemented in our own tap
  handlers. Rows live in `BrowserPane.swift` / `ColumnList.swift` / `AlbumRow.swift` /
  `TrackRow.swift`.
- The add pipeline already batches: `tracksForDragItems([String]) -> [LoadedTrack]` →
  `addItemsToCrate(_:crateName:)` → `importTracksIntoCrate(_:crateName:)`. Drag payloads
  are `"track::<uuid>"` / `"album::<id>"` strings.
- The SCAN OLED (`ScanView` in `OLEDDisplay.swift`) already renders
  `LibraryViewModel.scanProgress` (`folderName`, `filesProbed`, `totalCandidates`,
  `isRunning`). `importTracksIntoCrate` already drives `scanProgress` for the
  copy-on-import branch only.
- Crates are `.cdlib` files in `cratesDirectoryURL`; the crate **name is the filename**.
  References to update on rename: `availableCrates`, `crateTrackCounts`, `targetCrateName`,
  `currentSource` (`.localCrate(name:)`). Auto "Personal Crate" is real; "Prep Crate" is not
  a `.cdlib` crate.
- Playlists are `.m3u` files via `PlaylistService` (name = filename); `Playlist.id == name`.
  References: `playlists`, `currentSource` (`.playlist(name:)`).

## Feature 1 — Multi-select + batch Add to Crate

### Model (LibraryViewModel)
- Add `@Published var selectedAlbumIDs: Set<String> = []` and
  `@Published var selectedTrackIDs: Set<UUID> = []`.
- Keep `selectedAlbumID` / `selectedTrackID` as the **anchor** (last-clicked): drives the
  Inspector and ⇧-click range origin. A plain click sets the anchor and resets the matching
  set to `[id]`.
- Selection helpers: `handleAlbumTap(_:modifiers:visibleAlbums:)` and
  `handleTrackTap(_:modifiers:visibleTracks:)` implementing:
  - plain → `set = [id]`, anchor = id
  - ⌘ → toggle id in set, anchor = id
  - ⇧ → set = inclusive range between anchor and id within the visible ordering
- `selectAllInActiveColumn()` for ⌘A: fills the set for whichever column is "active"
  (track column if a track is selected/visible, else album column), using the current
  visible ordering.
- Clear sets when the source changes (`selectSource`) and when the album selection changes
  the visible track set (keep only still-visible track ids).

### Modifier capture
Read `NSEvent.modifierFlags` inside the row tap closure (`.contains(.command)` /
`.contains(.shift)`). No gesture restructure; the existing `onSelect` closure routes to the
new handlers with the captured modifiers.

### ⌘A
Add an **Edit → Select All (⌘A)** menu item in `AppDelegate`, forwarded via
`MainWindowController` to `model.selectAllInActiveColumn()`. `validateMenuItem` enables it
only for browsable sources with content. Guard: if the key window's first responder is a
field editor (renaming/search), the action is a no-op so normal text Select-All still works.

### Visual
Rows render selected when `selectedTrackIDs.contains(id)` / `selectedAlbumIDs.contains(id)`.
The anchor (`selectedTrackID`/`selectedAlbumID`) keeps the brighter "primary" treatment.

### Add to Crate
A single resolver `selectedTracksForCrateAdd() -> [LoadedTrack]`:
1. if `selectedTrackIDs` non-empty → those tracks;
2. else if `selectedAlbumIDs` non-empty → those albums' tracks;
3. else → the single selected album's tracks (today's behavior).
Wire it into the sidebar "Add to Crate" button, the sidebar per-crate "Add selected to…"
menu, and keep drag-to-crate (drag the whole selection as multiple payload strings).

## Feature 2 — Import status on the SCAN OLED

Wrap the add path so **every** add (reference-only and copy-on-import) shows on the SCAN OLED:
- Before work: remember `previousOLED = oledView`; set `oledView = .scan`,
  `scanProgress = ScanProgress(folderName: "Adding → <crate>", filesProbed: 0,
  totalCandidates: N, isRunning: true)`.
- During: ramp `filesProbed` (copy path already reports per-file; reference-only sets it to
  N on completion).
- After: `scanProgress = ScanProgress(folderName: "Added <N> · <crate>", filesProbed: N,
  totalCandidates: N, isRunning: false)`, then after ~1.5s revert `oledView = previousOLED`
  (only if still `.scan`) and `scanProgress = .idle`. A small `revealImportStatus` helper on
  the VM centralizes this so all call sites share it.

## Feature 3 — Inline rename (crates & playlists)

### VM methods
- `renameCrate(old:new:) -> Bool`: validate; move `<old>.cdlib` → `<new>.cdlib`; update
  `availableCrates`, `crateTrackCounts` key, `targetCrateName`, and `currentSource` if
  `.localCrate(old)`; `refreshAvailableCrates()`. Reject Prep Crate. Return false + Carbon
  alert on failure.
- `renamePlaylist(old:new:) -> Bool`: move `<old>.m3u` → `<new>.m3u` via a new
  `PlaylistService.renamePlaylist(from:to:)`; reload `playlists`; update `currentSource` if
  `.playlist(old)`.
- Validation (testable, pure): `CrateNameValidator.validate(_ proposed:, existing:[String])`
  in Core — trims; rejects empty, `/`, `:`, leading `.`, and case-insensitive duplicates;
  returns `.ok(sanitized)` or `.invalid(reason)`.

### Sidebar UI (SourcesSidebar)
- `@State editingName: EditingTarget?` where `EditingTarget` is `.crate(String)` /
  `.playlist(String)`.
- Double-click name or context-menu **Rename** sets `editingName`. While editing, the row
  swaps its label for a Carbon `TextField` (auto-focused). Return commits via the VM rename;
  Esc / blur cancels. On duplicate/invalid, keep editing and show the alert.
- Only user crates (everything in `availableCrates`, incl. Personal) and all playlists;
  Prep Crate has no rename.

## Testing

- `CrateNameValidatorTests` (Core, XCTest): empty, whitespace, slash/colon, dot-leading,
  duplicate (case-insensitive), happy path.
- Rename file-op behavior is exercised indirectly; selection/menu/OLED wiring is UI (manual
  GUI verification by the user, per project norm).

## Out of scope / backlog

- Marquee/drag-rectangle selection.
- Multi-select for artists.
- Other VU-meter tweaks (already backlogged).
- Reordering crates/playlists.
