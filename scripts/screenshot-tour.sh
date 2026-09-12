#!/usr/bin/env bash

set -euo pipefail

# Screenshots of every feature, in Carbon dark and light, from a demo library.
#
# Builds the debug app, runs a renamed copy of it (a separate executable name is
# a separate preferences domain: no bookmarks into the real library, no Last.fm
# session) against a crates folder of its own under .build/, seeds that library
# from a music folder, and lets installDemoTourIfRequested in AppDelegate walk
# the features. The app plays audio and opens windows while it runs; leave the
# Mac alone for about four minutes.
#
#   scripts/screenshot-tour.sh <music folder> [output folder]
#
# CRATEDIGGER_SEED_CRATES may hold JSON {"Crate": ["folder name prefix", ...]}
# to file albums into crates; anything unmatched lands in the Prep Crate.
# CRATEDIGGER_SHOWCASE picks the album the tour plays and features, by title or
# artist prefix; it is also seeded as the most played and best rated.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MUSIC_DIR="${1:?usage: scripts/screenshot-tour.sh <music folder> [output folder]}"
OUT_DIR="${2:-${ROOT_DIR}/docs/screenshots}"
DEMO_LIBRARY="${ROOT_DIR}/.build/demo-library"
DOMAIN="CrateDiggerDemo"

[[ -d "${MUSIC_DIR}" ]] || { echo "error: no folder at ${MUSIC_DIR}" >&2; exit 1; }

cd "${ROOT_DIR}"
swift build || { echo "error: swift build failed" >&2; exit 1; }
BIN_DIR="$(swift build --show-bin-path)"
cp "${BIN_DIR}/CrateDiggerApp" "${BIN_DIR}/${DOMAIN}"

# A fresh demo library and preferences every run, marked as past onboarding so
# no first-run sheet covers the tour.
rm -rf "${DEMO_LIBRARY}" "${OUT_DIR}/dark" "${OUT_DIR}/light" "${OUT_DIR}/DONE.txt"
mkdir -p "${OUT_DIR}"
defaults delete "${DOMAIN}" >/dev/null 2>&1 || true
MARKETING="$(sed -n 's/.*static let marketing = "\(.*\)".*/\1/p' Sources/CrateDiggerApp/AppVersion.swift)"
defaults write "${DOMAIN}" cratedigger.onboarding.completed -bool true
defaults write "${DOMAIN}" cratedigger.onboarding.tourSeen -bool true
defaults write "${DOMAIN}" cratedigger.onboarding.whatsNewVersion -string "${MARKETING}"

CRATEDIGGER_CRATES_DIR="${DEMO_LIBRARY}" \
CRATEDIGGER_SEED="${MUSIC_DIR}" \
CRATEDIGGER_SEED_CRATES="${CRATEDIGGER_SEED_CRATES:-{\}}" \
CRATEDIGGER_TOUR="${OUT_DIR}" \
  "${BIN_DIR}/${DOMAIN}"

[[ -f "${OUT_DIR}/DONE.txt" ]] || { echo "error: the tour did not finish; look for [tour] lines in Console" >&2; exit 1; }
rm -f "${OUT_DIR}/DONE.txt"
echo "Wrote $(find "${OUT_DIR}/dark" "${OUT_DIR}/light" -name '*.png' | wc -l | tr -d ' ') screenshots to ${OUT_DIR}"
