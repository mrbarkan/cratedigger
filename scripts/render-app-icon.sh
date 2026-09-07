#!/usr/bin/env bash
#
# Renders every app-icon asset, then builds the .icns.
#
#   scripts/render-app-icon.sh          (from the repo root)
#
# The artwork lives in ONE place — Sources/CrateDiggerApp/UI/Theme/
# AppIconArtwork.swift — which the app draws on screen and this script
# compiles against, so an edit to the icon can never land in one and not the
# other. That is also why the artwork file must stay free of app dependencies.
#
# Writes:
#   Branding/Icon/CrateDigger.iconset/    classic sizes, Apple's 824/1024 grid
#   Branding/Icon/AppIcon.appiconset/     the same art for Assets.xcassets
#   Branding/Icon/Tahoe/                  full-bleed masters + Icon Composer layers
#   Branding/Generated/                   the 1024 preview
#   Branding/Icon/CrateDigger.icns        and copies it into Packaging/
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT

echo "▸ Compiling the icon renderer ..."
swiftc -O \
  Sources/CrateDiggerApp/UI/Theme/AppIconArtwork.swift \
  scripts/render-app-icon-main.swift \
  -o "${BUILD_DIR}/render-app-icon"

echo "▸ Rendering ..."
"${BUILD_DIR}/render-app-icon"

echo "▸ Building CrateDigger.icns with iconutil ..."
iconutil -c icns "Branding/Icon/CrateDigger.iconset" -o "Branding/Icon/CrateDigger.icns"
cp "Branding/Icon/CrateDigger.icns" "Packaging/CrateDiggerApp/Resources/CrateDigger.icns"

echo "✓ Done. The packaged app picks this up on the next scripts/package-app.sh."
