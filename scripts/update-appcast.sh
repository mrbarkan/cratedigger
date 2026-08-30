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
APPCAST_OVERRIDE=""
TAG_OVERRIDE=""

usage() {
  cat <<'EOF'
Usage: scripts/update-appcast.sh [--dmg PATH] [--channel rc]
                                 [--appcast PATH] [--tag TAG]

Adds a release to website/appcast.xml and signs it. With no --dmg, uses the
newest dist/CrateDigger-*.dmg.

  --dmg PATH        The DMG to publish (default: newest in dist/)
  --channel NAME    Publish on a Sparkle channel instead of to everyone.
                    Use 'rc' for prereleases — only builds whose
                    AppVersion.channel says so will be offered them.
  --appcast PATH    The feed to write (default: website/appcast.xml). The v2
                    beta line writes website/appcast-beta.xml instead, so the
                    stable feed cannot be touched by a beta release.
  --tag TAG         The git tag whose release holds the DMG (default: derived
                    from the DMG name, e.g. v1.5.10). Prerelease tags carry the
                    build as the prerelease number, so pass it: v2.0.0-beta.73.
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
    --appcast) APPCAST_OVERRIDE="${2:?missing path for --appcast}"; shift 2 ;;
    --tag) TAG_OVERRIDE="${2:?missing tag for --tag}"; shift 2 ;;
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

if [[ -n "${APPCAST_OVERRIDE}" ]]; then
  APPCAST="${APPCAST_OVERRIDE}"
  # Each feed gets its own staging directory. generate_appcast writes an entry
  # for every DMG it finds, so a shared one would put the stable releases into
  # the beta feed (and its deltas into the beta release, where they are not
  # uploaded). Keeping them apart also gives the beta line its own DMG history,
  # which is what a beta-to-beta delta is computed from.
  STAGING_DIR="${ROOT_DIR}/dist/updates-$(basename "${APPCAST}" .xml | sed 's/^appcast-//')"
fi

# Each feed is generated on the branch that owns it. GitHub Pages serves
# website/ from main, so the stable feed is written there; the beta feed is
# written on v2 — whose CHANGELOG carries the 2.0.0 notes — and then carried
# across with `git checkout v2 -- website/appcast-beta.xml`.
#
# Right script, wrong branch is silent and destructive both ways, and both
# happened while testing the guard above:
#   - beta feed from main: no '## 2.0.0' section in that CHANGELOG, so the
#     notes come out empty and every entry is rewritten without its release
#     notes. The script only warns about missing notes and carries on.
#   - stable feed from v2: rewrites the appcast that is meant to stay frozen
#     for the whole 2.0 cycle.
BRANCH="$(git -C "${ROOT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
case "$(basename "${APPCAST}")" in
  appcast.xml)      EXPECTED_BRANCH="main" ;;
  appcast-beta.xml) EXPECTED_BRANCH="v2" ;;
  *)                EXPECTED_BRANCH="" ;;
esac
if [[ -n "${EXPECTED_BRANCH}" && -n "${BRANCH}" && "${BRANCH}" != "${EXPECTED_BRANCH}" ]]; then
  echo "error: $(basename "${APPCAST}") is generated on ${EXPECTED_BRANCH}; you are on ${BRANCH}." >&2
  echo "" >&2
  if [[ "${EXPECTED_BRANCH}" == "v2" ]]; then
    echo "The 2.0.0 release notes live in v2's CHANGELOG. Running this here would" >&2
    echo "rewrite the beta feed with every entry stripped of its notes." >&2
  else
    echo "website/appcast.xml is the stable feed and stays frozen for the whole" >&2
    echo "2.0 cycle on this branch. Publish it from main." >&2
  fi
  echo "" >&2
  echo "  git checkout ${EXPECTED_BRANCH}" >&2
  exit 1
fi

DMG_NAME="$(basename "${DMG_PATH}")"
VERSION="${DMG_NAME#CrateDigger-}"
VERSION="${VERSION%.dmg}"
TAG="${TAG_OVERRIDE:-v${VERSION}}"

mkdir -p "${STAGING_DIR}"

# The archive being published and the feed being written have to belong to the
# same release line, and neither the DMG default nor generate_appcast checks.
#
# Two ways that goes wrong, both seen for real:
#   - Something from the other line is left in this staging directory.
#     generate_appcast emits an entry for EVERY archive it finds there, so it
#     is published into this feed with a download URL for a tag that was never
#     cut. A 2.0.0 beta entry reached the stable appcast exactly this way.
#   - No --dmg is passed, so the newest DMG in dist/ is taken. That is the
#     build you just made in the usual flow, and the wrong line entirely when
#     the other line was built more recently.
#
# Compare the two rather than hardcode a version: whatever is already staged
# defines the line this feed serves.
MAJOR="${VERSION%%.*}"
FOREIGN=()
for archive in "${STAGING_DIR}"/CrateDigger-*.dmg; do
  [[ -e "${archive}" ]] || continue
  staged_name="$(basename "${archive}")"
  staged_version="${staged_name#CrateDigger-}"
  staged_version="${staged_version%.dmg}"
  [[ "${staged_version%%.*}" == "${MAJOR}" ]] || FOREIGN+=("${staged_name} (${staged_version%%.*}.x)")
done
if (( ${#FOREIGN[@]} )); then
  echo "error: ${DMG_NAME} does not belong in $(basename "${APPCAST}")." >&2
  echo "" >&2
  echo "  publishing:  ${DMG_NAME} (${MAJOR}.x)" >&2
  echo "  ${STAGING_DIR#${ROOT_DIR}/} already holds:" >&2
  printf '    %s\n' "${FOREIGN[@]}" >&2
  echo "" >&2
  echo "generate_appcast writes an entry for every archive in that directory, so" >&2
  echo "this run would mix both release lines into one feed, with download URLs" >&2
  echo "for tags that were never cut. Pass --dmg for the build you meant to" >&2
  echo "publish, or move the stray archive out of that directory." >&2
  exit 1
fi

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

# --download-url-prefix is applied to EVERY entry, not just the new one, so a
# plain run rewrites older releases' DMG URLs to point inside this release's
# tag — a 404 for anyone the newest entry doesn't apply to. Each asset already
# names its own version, so re-derive the tag per URL and put the old ones back.
python3 - "${STAGING_DIR}/appcast.xml" "${TAG}" "${DMG_NAME}" <<'PYFIX'
import re, sys

path, this_tag, this_dmg = sys.argv[1], sys.argv[2], sys.argv[3]
xml = open(path).read()
base = "https://github.com/mrbarkan/cratedigger/releases/download/"

def retag(match):
    tag, asset = match.group(1), match.group(2)
    # This release's own assets are already tagged correctly, and on a
    # prerelease the tag (v2.0.0-beta.73) can't be derived from the DMG name.
    if asset == this_dmg:
        return base + this_tag + "/" + asset
    # Older full DMGs are named CrateDigger-<version>.dmg and belong to
    # v<version>. Deltas (CrateDigger<to>-<from>.delta) ship with the release
    # they upgrade TO, which is the tag just written — leave those.
    version = re.fullmatch(r"CrateDigger-(.+)\.dmg", asset)
    return base + ("v" + version.group(1) if version else tag) + "/" + asset

fixed = re.sub(re.escape(base) + r"(v[^/\"]+)/([^\"]+)", retag, xml)
if fixed != xml:
    open(path, "w").write(fixed)
    print("repointed older enclosures at their own release tags")
PYFIX

cp "${STAGING_DIR}/appcast.xml" "${APPCAST}"
echo "Wrote ${APPCAST}"
echo
echo "Next: upload ${DMG_NAME} to the ${TAG} release, then commit and push"
echo "${APPCAST#"${ROOT_DIR}/"} — Pages redeploys the feed on push."
echo
echo "If the feed carries a <sparkle:deltas> entry, upload that .delta from"
echo "${STAGING_DIR} to the ${TAG} release too — its URL points there."
