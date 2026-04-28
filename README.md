# CrateDigger

CrateDigger is a macOS music utility built with Swift, AppKit, and FFmpeg tooling. It scans folders of audio files, previews tracks and artwork, inspects metadata, and converts files into cleaner library layouts.

## Development

Build the app executable:

```bash
swift build
```

Run the test suite:

```bash
scripts/test.sh
```

`scripts/test.sh` forces the XCTest runner path, prefers a full Xcode developer directory when one is installed, and prints clear guidance if Xcode still needs its license accepted.

## Packaging

Assemble a shareable `.app` bundle with bundled `ffmpeg` and `ffprobe`:

```bash
scripts/package-app.sh
```

You can also point the script at specific binaries:

```bash
scripts/package-app.sh --ffmpeg /opt/homebrew/bin/ffmpeg --ffprobe /opt/homebrew/bin/ffprobe --output ./dist
```

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
    --sign "Developer ID Application: Your Name (TEAMID)" \
    --notarize \
    --dmg
```

This produces `dist/CrateDigger-<version>.dmg`, signed and stapled, that opens cleanly on any Mac. The hardened runtime entitlements live in `Packaging/CrateDiggerApp/CrateDigger.entitlements` (library-validation disabled so the bundled `ffmpeg`/`ffprobe` binaries can run).

For the full beta release gate, see [docs/BETA_RELEASE_CHECKLIST.md](/Users/mrbarkan/Development/CrateDigger/docs/BETA_RELEASE_CHECKLIST.md).

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
