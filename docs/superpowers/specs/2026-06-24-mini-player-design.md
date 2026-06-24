# Mini Player — Design Note

Date: 2026-06-24
Status: Approved (design authored in the user's claude.ai project; refinements approved)

## Goal

A floating, always-on-top mini player — a compact transport mirroring the full
app's playback, for when the main window is out of the way.

## Source design

From the user's `CrateDigger Mini Player.html`: a 272pt-wide translucent Carbon
glass strip, no window chrome, floating over the desktop.

## Layout

- **Top bar:** `● NOW PLAYING` · art-mode toggle (disc icon) · expand-to-full-app.
  No close button.
- **Art (246²):** the spinning disc — reuse `SpinningRecordView`. User toggles
  **CD ↔ Vinyl**; toggle disabled for streams.
- **Title** / `ARTIST · ALBUM · YEAR`.
- **Seek bar** (cyan→orange) + elapsed/total — reuses the scrub-preview commit path.
- **Transport:** shuffle · prev · orange play dome · next · repeat.

## Decisions (approved)

- **Art:** reuse `SpinningRecordView` with a user CD/Vinyl toggle (new optional
  `forcedVinyl` override; the inspector keeps auto-detect). Disabled for streams.
- Opening the mini player **hides the full app**; Expand restores it (alternate modes).

## Architecture

- **MiniPlayerWindowController:** borderless, `.floating`-level `NSWindow`, clear
  background, draggable, remembers position; hosts `MiniPlayerView`.
- **MiniPlayerView** (SwiftUI, dark Carbon glass) shares the existing
  `LibraryViewModel` — all transport/seek/shuffle/repeat reuse current state; no
  duplicate playback. The seek reuses `commitScrubSeek` / `displayedCurrentTime`.
- Art mode (CD/Vinyl) persisted via `PreferencesStore` (`miniPlayerVinyl`).
- **Entry:** Window menu → "Mini Player" (opens mini, hides main).
  **Exit:** the expand button (restores main, closes mini).
- `MainWindowController` exposes its `model`; `AppDelegate` owns both window
  controllers and coordinates show/exit.

## Out of scope

- A dedicated static stream-art tile (streams just disable the toggle for now).
- A global keyboard shortcut for the menu item (can add later).
