# fpcalc (Chromaprint)

The audio fingerprinter behind DEEP SCAN. `scripts/package-app.sh` copies this
binary into `CrateDigger.app/Contents/Resources/fpcalc`, where
`ExternalToolLocator` finds it ahead of anything on the user's PATH.

| | |
|---|---|
| Version | 1.5.1 |
| Source | https://github.com/acoustid/chromaprint/releases/tag/v1.5.1 |
| File | `chromaprint-fpcalc-1.5.1-macos-universal.tar.gz` |
| Architectures | `x86_64 arm64` |
| Linkage | static |
| License | Chromaprint is LGPL-2.1-or-later; this build statically links FFmpeg (LGPL-2.1-or-later) |

Unmodified upstream binary. It is bundled as a **separate executable** that
CrateDigger invokes as a subprocess, never linked into the app, and the source
for both Chromaprint and its FFmpeg is available at the URL above and at
ffmpeg.org. Replacing this file with another build of fpcalc is all it takes to
swap the implementation.

## Why vendored rather than a Homebrew dependency

Homebrew's `chromaprint` links dynamically against its own FFmpeg dylibs under
`/opt/homebrew`. Those paths do not exist on other people's Macs, and
hardened-runtime signing blocks loading them even on Macs that have Homebrew,
because the Team IDs don't match. `scripts/package-app.sh` runs
`require_static_tool` against this binary for exactly that reason, and a signed
build fails rather than shipping something that cannot run.

## Replacing it

Download the macOS universal build from the releases page above, then:

```sh
tar xzf chromaprint-fpcalc-*-macos-universal.tar.gz
cp chromaprint-fpcalc-*/fpcalc Vendor/fpcalc/fpcalc
chmod 755 Vendor/fpcalc/fpcalc
otool -L Vendor/fpcalc/fpcalc | grep -E '/opt/homebrew|/usr/local'   # must print nothing
lipo -archs Vendor/fpcalc/fpcalc                                     # must print: x86_64 arm64
```

Update the version in the table above when you do.
