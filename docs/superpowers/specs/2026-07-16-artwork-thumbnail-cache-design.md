# Artwork: folder-canonical art, thumbnail-only cache

**Status:** approved design, not yet planned
**Target:** 1.1.0 beta line (`beta/1.1.0-theming`)

## Problem

`ArtworkStore` persists a full-resolution copy of **every** cover
`ArtworkService.resolveArtwork` sees — embedded, folder, or remote — into
`Application Support/CrateDigger/Artwork/<hash>`, and nothing ever deletes
from it. For a large library this silently grows to gigabytes of pure
duplication: embedded art already lives inside the audio files, and imported
art is already written as `cover.jpg` into the album folder
(`applyImportedArtwork` marks tracks `.folderImage`). Deleting an album
folder orphans its blobs forever.

## Goal

Art canonically lives **next to the music** (embedded tags or `cover.jpg` in
the album folder — both already true today). The app-owned cache keeps only
small disposable thumbnails, so deleting an album folder deletes everything
real.

## Design

### 1. `ArtworkStore` → thumbnail-only

- On `put`, downscale to a **max 512 px JPEG (~0.8 quality)** before writing.
  New location: `Application Support/CrateDigger/Thumbnails/<hash>.jpg`.
  Full-res bytes never touch disk in App Support again.
- The store's two jobs survive at ~1 % of the disk cost: cold-launch covers
  (crates carry only `artworkHash`) and offline-drive browsing.
- Downscaling lives in Core next to the existing thumbnail generation in
  `ArtworkService` (ImageIO `CGImageSourceCreateThumbnailAtIndex`, same as
  `generateThumbnail`), unit-tested: bytes in → JPEG ≤ 512 px out, tiny
  inputs pass through untouched.

### 2. Full-res consumers re-resolve from source

The disk cache must never feed a re-embedding path (a 512 px thumb baked
into a converted file would be silent quality loss):

- `ArtworkService.hydrated(_:)` — single caller,
  `LibraryViewModel+Conversion.swift:341`. When `asset.data` is empty it
  currently refills from cache/store by hash. Change: refill from the
  **track's source** (embedded art or folder image via the existing resolve
  path). During conversion/transfer the source file is online by definition,
  so nothing is lost. The in-memory `dataCache` (full-res, NSCache-bounded)
  still short-circuits this when warm.
- The large artwork viewer prefers source bytes when the file is reachable;
  falls back to the thumbnail when the drive is offline.
- Display thumbnails (`generateThumbnail`/`thumbnailAsync`) keep reading the
  store — they want small bytes anyway; decoding from a 512 px JPEG is
  cheaper than from full-res.

### 3. One-time migration

On first launch with the new store, if `…/CrateDigger/Artwork` exists:
downscale each blob into `Thumbnails/<hash>.jpg`, then delete the old
directory. Runs off the main actor; failures on individual blobs are
skipped (worst case that cover re-caches on next browse). Result: space is
reclaimed immediately and offline-drive covers survive the transition.

### 4. Cache hygiene

"Clean Thumbnail Cache" button in Preferences → deletes the `Thumbnails`
directory (recreated lazily). No reference-counting GC — thumbs are small
enough that stale ones don't matter, and any needed thumb regenerates on
next browse.

## Error handling

- Unwritable/undecodable blob during migration: skip, continue, log via
  `AppLog`.
- Thumb write failure: non-fatal — behavior degrades to today's cold-launch
  placeholder.
- `hydrated` finding the source offline mid-conversion: the job already
  handles missing-artwork (converts without embedding) — unchanged.

## Testing (Core, XCTest)

- Downscale: large input → ≤ 512 px JPEG; small input → unchanged bytes.
- Store round-trip: `put` full-res → `data(for:)` returns thumb-sized bytes.
- Migration: temp dir with fake blobs → thumbs created, originals gone.
- Hydration: empty-data asset + reachable source file → full-res restored
  (fake resolver); unreachable → asset unchanged.

## Out of scope

- Extracting embedded art out to `cover.jpg` (embedded already lives with
  the file).
- Reference-counting GC of thumbnails.
- Any change to `applyImportedArtwork`'s cover.jpg writing (already
  folder-canonical).
