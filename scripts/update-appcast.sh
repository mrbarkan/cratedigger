#!/usr/bin/env bash

set -euo pipefail

# Regenerates website/appcast.xml — the feed the shipped app checks for updates
# — from a packaged DMG, signing the entry with the private EdDSA key in the
# maintainer's Keychain.
#
# Run it after scripts/package-app.sh has produced a signed, notarized DMG and
# before pushing website/, since GitHub Pages deploys the feed from there.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGING_DIR="${ROOT_DIR}/dist/updates"
APPCAST="${ROOT_DIR}/website/appcast.xml"
CHANGELOG="${ROOT_DIR}/CHANGELOG.md"
SITE_URL="https://cratedigger.mrbarkan.com/"
RELEASES_URL="https://github.com/mrbarkan/cratedigger/releases"
CHANNEL=""
DMG_PATH=""

usage() {
  cat <<'EOF'
Usage: scripts/update-appcast.sh [--dmg PATH] [--channel rc]

Adds a release to website/appcast.xml and signs it. With no --dmg, uses the
newest dist/CrateDigger-*.dmg.

  --dmg PATH        The DMG to publish (default: newest in dist/)
  --channel NAME    Publish on a Sparkle channel instead of to everyone.
                    Use 'rc' for prereleases — only builds whose
                    AppVersion.channel says so will be offered them.
  --help, -h        Show this help

The DMG must already be the one you are uploading to the GitHub release: the
feed points at that release's download URL and the signature covers those exact
bytes, so re-packaging afterwards invalidates it.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg) DMG_PATH="${2:?missing path for --dmg}"; shift 2 ;;
    --channel) CHANNEL="${2:?missing name for --channel}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

GENERATE_APPCAST="$(find "${ROOT_DIR}/.build" -type f -name 'generate_appcast' -perm -u+x 2>/dev/null | head -n 1)"
if [[ -z "${GENERATE_APPCAST}" ]]; then
  echo "error: generate_appcast not found — run 'swift package resolve' first." >&2
  exit 1
fi

if [[ -z "${DMG_PATH}" ]]; then
  DMG_PATH="$(ls -t "${ROOT_DIR}"/dist/CrateDigger-*.dmg 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "${DMG_PATH}" || ! -f "${DMG_PATH}" ]]; then
  echo "error: no DMG to publish. Run scripts/package-app.sh --dmg first." >&2
  exit 1
fi

DMG_NAME="$(basename "${DMG_PATH}")"
VERSION="${DMG_NAME#CrateDigger-}"
VERSION="${VERSION%.dmg}"
TAG="v${VERSION}"

mkdir -p "${STAGING_DIR}"
# The committed feed is the source of truth for what's already published:
# generate_appcast updates it in place, keeping older entries and their
# signatures rather than rewriting history from whatever happens to be on disk.
if [[ -f "${APPCAST}" ]]; then
  cp "${APPCAST}" "${STAGING_DIR}/appcast.xml"
fi
cp "${DMG_PATH}" "${STAGING_DIR}/${DMG_NAME}"

# Release notes: the changelog section for this version, under the archive's
# own name, which is how generate_appcast pairs notes with an update.
NOTES_PATH="${STAGING_DIR}/${DMG_NAME%.dmg}.md"
awk -v version="${VERSION}" '
  $0 ~ "^## " version "( |$)" { inside = 1; next }
  inside && /^## / { exit }
  inside { print }
' "${CHANGELOG}" > "${NOTES_PATH}"
if [[ ! -s "${NOTES_PATH}" ]]; then
  echo "warning: no '## ${VERSION}' section in CHANGELOG.md — publishing without release notes." >&2
  rm -f "${NOTES_PATH}"
fi

ARGS=(
  --download-url-prefix "https://github.com/mrbarkan/cratedigger/releases/download/${TAG}/"
  --link "${SITE_URL}"
  --full-release-notes-url "${RELEASES_URL}"
  --embed-release-notes
)
if [[ -n "${CHANNEL}" ]]; then
  ARGS+=(--channel "${CHANNEL}")
fi

echo "Signing ${DMG_NAME} into the appcast${CHANNEL:+ (channel: ${CHANNEL})}..."
"${GENERATE_APPCAST}" "${ARGS[@]}" "${STAGING_DIR}"

# generate_appcast only *warns* when the private key is missing and still writes
# a feed — one whose entries every installed app will refuse, because the app
# carries the public key and requires the signature. Check before touching the
# committed feed, so a keyless run leaves it alone.
if ! grep -F "${DMG_NAME}" "${STAGING_DIR}/appcast.xml" | grep -q 'sparkle:edSignature='; then
  echo "error: the generated entry for ${DMG_NAME} is unsigned — not updating ${APPCAST}." >&2
  echo "The private EdDSA key isn't in your Keychain. Run '$(dirname "${GENERATE_APPCAST}")/generate_keys'" >&2
  echo "if this Mac has never signed a release, or restore the key from your backup." >&2
  exit 1
fi

cp "${STAGING_DIR}/appcast.xml" "${APPCAST}"
echo "Wrote ${APPCAST}"
echo
echo "Next: upload ${DMG_NAME} to the ${TAG} release, then commit and push"
echo "website/appcast.xml — Pages redeploys the feed on push."
