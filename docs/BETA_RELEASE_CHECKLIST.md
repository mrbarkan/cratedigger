# CrateDigger Beta Release Checklist

This checklist is the release gate for a shareable beta build of CrateDigger.
Follow it top to bottom. A beta is ready only when every required item below is complete.

## 1. Tooling Preflight

- Confirm full Xcode is installed at `/Applications/Xcode.app`.
- Accept the Apple developer tools license once:

```bash
sudo xcodebuild -license
```

- Point developer tools at full Xcode if needed:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

- Verify local conversion tools are available for packaging:

```bash
command -v ffmpeg
command -v ffprobe
```

## 2. Verification Gate

- Run the automated test suite:

```bash
scripts/test.sh
```

- Do not ship a beta until the test runner executes successfully, not just compiles.
- If `scripts/test.sh` fails:
  - fix repo issues first if the failure is code-related
  - fix local Xcode/tooling setup first if the failure is environment-related

## 3. Build and Package Gate

- Build a packaged app with bundled `ffmpeg` and `ffprobe`:

```bash
scripts/package-app.sh --ffmpeg /opt/homebrew/bin/ffmpeg --ffprobe /opt/homebrew/bin/ffprobe
```

- Confirm the output exists at `dist/CrateDigger.app`.
- Launch the packaged app directly from the bundle, not only from Xcode.
- Confirm the app icon, bundle name, and version/build metadata are correct before sending the beta.

## 4. Manual Smoke Test Gate

Run this on a clean or clean-ish Mac, ideally one without Homebrew FFmpeg in the default path.

- Launch the packaged app and confirm the initial empty window is fully visible on screen.
- Confirm the compact empty launch state looks intentional and the inspector is collapsed.
- Load a mixed-format music folder.
- Confirm the window expands once into workspace mode after the first successful load.
- Inspect artwork and metadata for multiple tracks.
- Play tracks, pause, scrub the timeline, and use previous/next controls.
- Confirm playback still works after sorting and selection changes.
- Convert files using all three folder modes:
  - `Source Relative`
  - `Flat`
  - `Metadata Template`
- Use `Review album folders` and confirm edited paths are respected.
- Confirm duplicate output names get unique filenames instead of overwriting.
- Confirm readiness/status messaging is understandable when tools are available.
- Confirm readiness/status messaging is understandable when conversion or probing is unavailable.
- Resize the window smaller and larger and confirm the UI stays legible.
- Move the window between screens if available and confirm it remains fully visible.

## 5. Beta Distribution Gate

### Internal beta only

This is enough for a small technical tester group:

- tooling preflight complete
- automated tests executed successfully
- packaged app smoke-tested successfully
- ad-hoc signed build produced by `scripts/package-app.sh`

### External beta

These are still required before broader distribution outside a trusted internal group:

- replace ad-hoc signing with Developer ID Application signing
- notarize the final app with Apple
- staple the notarization ticket
- distribute as a clean `.zip` or `.dmg`

Do not call the app “external beta ready” until those steps are complete.

## 6. Release Artifacts To Prepare

- `CrateDigger.app`
- version number and build number for the beta
- short tester notes:
  - what changed
  - known issues
  - what to validate
  - where to report bugs

## 7. Current Repo Definition Of Done

CrateDigger is beta-ready when all of the following are true:

- `scripts/test.sh` runs successfully on a valid Xcode setup
- `scripts/package-app.sh` produces a working app bundle
- the packaged app passes the manual smoke checklist
- launch sizing and resize behavior are validated outside Xcode
- beta version/build metadata are updated intentionally
- for external beta only: Developer ID signing and notarization are complete
