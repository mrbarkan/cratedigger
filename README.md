# CrateDigger

**A skeuomorphic music-library workbench for macOS.** CrateDigger scans your
folders of audio files, browses and plays them on a tactile "hardware" console,
inspects and edits tags and artwork, tidies up messy libraries, and batch-converts
files with FFmpeg — plus Subsonic/Navidrome streaming, Audio-CD ripping, and
Last.fm scrobbling.

![Platform: macOS 13+](https://img.shields.io/badge/platform-macOS%2013%2B-blue)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

<p align="center">
  <img src="website/assets/screenshot_dark.png" alt="CrateDigger — the Carbon console: Sources, Browser, and Inspector panes with an OLED display and VU meters" width="820">
</p>

## Features

- **Browse** your collection by Artist → Album → Track with cover art.
- **Play** with a queue, shuffle/repeat, ±8s seek, and output-device selection.
- **Inspect & edit** metadata and embedded artwork track-by-track.
- **Organize & clean up** — move/consolidate libraries and fix folder layouts.
- **Convert** with FFmpeg: choose codec, bitrate/sample-rate, artwork handling,
  and flexible output-folder structures (mirror source, flat, or metadata template),
  with collision-safe filenames.
- **Crates** (`.cdlib`) to save and organize collections, with a staging "Prep Crate".
- **Stream** from Subsonic / Navidrome servers.
- **Rip** Audio CDs, and **scrobble** to Last.fm.
- A skeuomorphic **"Carbon"** UI — chassis panels, an OLED display, VU meters, and knobs.

## Requirements

- **macOS 13 (Ventura) or later.**
- **Apple Silicon** for the default build. (Intel/universal builds are possible but
  need a universal Swift build and a `lipo`-merged universal FFmpeg — see below.)
- The packaged app **bundles `ffmpeg` and `ffprobe`**, so end users need nothing
  extra. When building from source, FFmpeg is optional: without it the app falls
  back to AVFoundation-only metadata and conversion is disabled.

## Install

- **Download** the latest signed `.dmg` from the [Releases](https://github.com/mrbarkan/cratedigger/releases) page and drag CrateDigger to Applications.
- Or **build it yourself** (see below).

If you find CrateDigger useful, you can support development on
[Patreon](https://www.patreon.com/mrbarkan). 💛

## Building from source

Build the app executable:

```bash
swift build
```

Run the test suite:

```bash
scripts/test.sh
```

`scripts/test.sh` forces the XCTest runner path, prefers a full Xcode developer
directory when one is installed, and prints clear guidance if Xcode still needs
its license accepted.

## Packaging

Assemble a shareable `.app` bundle with bundled `ffmpeg` and `ffprobe`:

```bash
scripts/package-app.sh
```

You can also point the script at specific binaries:

```bash
scripts/package-app.sh --ffmpeg /opt/homebrew/bin/ffmpeg --ffprobe /opt/homebrew/bin/ffprobe --output ./dist
```

> **For distribution, do NOT bundle Homebrew's ffmpeg.** Homebrew builds are
> *dynamically* linked to `/opt/homebrew/Cellar/...` dylibs that don't exist on
> other Macs, so conversion / ffprobe fail anywhere without Homebrew ffmpeg
> installed. Bundle **statically-linked** binaries instead — for Apple Silicon,
> the static arm64 `ffmpeg`/`ffprobe` from [osxexperts.net](https://www.osxexperts.net)
> are fully self-contained (verify the published SHA256). Homebrew is fine for
> local dev only. (Intel/universal distribution additionally needs a universal
> Swift build + a `lipo`-merged universal ffmpeg.)

The packaged app is written to `dist/CrateDigger.app`. By default the bundle is ad-hoc signed (suitable for local development only).
The packaging script also prefers a full Xcode developer directory when one is installed and uses a repo-local module cache so the build is less sensitive to machine-wide Swift cache state.

### Distribution build (Developer ID + notarized DMG)

A shippable build needs Developer ID signing, hardened runtime, notarization, and a DMG:

```bash
# One-time: store an app-specific password under a notarytool profile name
xcrun notarytool store-credentials cratedigger-notary \
  --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>

# Each release
CRATEDIGGER_NOTARY_PROFILE=cratedigger-notary \
  scripts/package-app.sh \
    --ffmpeg /path/to/static/ffmpeg --ffprobe /path/to/static/ffprobe \
    --sign "Developer ID Application: Your Name (TEAMID)" \
    --notarize \
    --dmg
```

This produces `dist/CrateDigger-<version>.dmg`, signed and stapled, that opens cleanly on any Mac. The hardened runtime entitlements live in `Packaging/CrateDiggerApp/CrateDigger.entitlements` (library-validation disabled so the bundled `ffmpeg`/`ffprobe` binaries can run).

For the full beta release gate, see [docs/BETA_RELEASE_CHECKLIST.md](docs/BETA_RELEASE_CHECKLIST.md).

### Last.fm scrobbling (optional)

Last.fm requires an *application* API key + shared secret. These are **not**
included in the source — the app runs fine without them (scrobbling is simply
disabled). To enable Last.fm in your own build:

1. Create an API account at <https://www.last.fm/api/account/create>.
2. Copy `scripts/lastfm.env.example` to `scripts/.lastfm.env` (gitignored) and
   fill in your key/secret. `scripts/package-app.sh` embeds them into the app
   bundle automatically.
3. For a `swift run` dev build, export `CRATEDIGGER_LASTFM_API_KEY` and
   `CRATEDIGGER_LASTFM_API_SECRET` in your shell instead.

## Manual Smoke Checklist

- Launch the packaged app on a Mac without Homebrew-installed FFmpeg tools.
- Load a mixed-format music folder.
- Confirm the empty state, loading state, and loaded-track state all make sense.
- Inspect artwork and metadata for several tracks.
- Play tracks, pause, seek on the LCD timeline, and use previous/next controls.
- Convert files using `Source Relative`, `Flat`, and `Metadata Template` folder structures.
- Use `Review album folders` and confirm the review sheet edits destinations correctly.
- Convert files with duplicate basenames and verify CrateDigger renames outputs instead of overwriting them.
- Verify the bottom status area and readiness text clearly explain whether playback, metadata probing, and conversion are available.

## License

Released under the [MIT License](LICENSE). © 2026 Mr. Barkan.
