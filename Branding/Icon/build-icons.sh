#!/usr/bin/env bash
#
# CrateDigger · macOS icon build script
# Fixes @2x filenames (the export tool can't write "@"), then produces:
#   • CrateDigger.icns  — classic icon, works on every macOS (backwards compatible)
# The AppIcon.appiconset/ folder is already Xcode-ready — just drag it into
# Assets.xcassets. See README.md for the full picture.
#
set -euo pipefail
cd "$(dirname "$0")"

ISET="CrateDigger.iconset"
echo "▸ Restoring @2x filenames in ${ISET}/ ..."
for f in "${ISET}"/*-2x.png; do
  [ -e "$f" ] || continue
  mv -f "$f" "${f/-2x.png/@2x.png}"
done

echo "▸ Building CrateDigger.icns with iconutil ..."
iconutil -c icns "${ISET}" -o CrateDigger.icns

echo "✓ Done."
echo "  • CrateDigger.icns          → drop into an SPM/AppKit bundle or set as CFBundleIconFile"
echo "  • AppIcon.appiconset/       → drag into Assets.xcassets in Xcode"
echo "  • Tahoe/CrateDigger-1024-fullbleed.png → import into Icon Composer for the Liquid Glass icon"
