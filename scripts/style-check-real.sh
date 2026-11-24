#!/bin/bash
# Check that this build still renders Real Hardware like the reference build, using
# two captures taken back to back (stored baselines drift: the translucent mini
# player in particular). Usage: scripts/style-check-real.sh <theme-id> <light|dark> <full|compact|mini>
# Needs: SCRATCH, STYLE_REFERENCE_ROOT (a checkout with an untouched, already built baseline).
# Never builds. Neither capture gets CRATEDIGGER_STYLE, CRATEDIGGER_STYLE_PRESSED, the theme
# editor's or picker's hooks, or STYLE_CAPTURE_TITLE: it compares the main window as it opens.
# CRATEDIGGER_OLED is left as given, so both captures show that screen (Real on CNVRT).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
THEME="${1:?theme id}"; MODE="${2:?light|dark}"; LAYOUT="${3:?full|compact|mini}"
: "${SCRATCH:?SCRATCH is not set}"
: "${STYLE_REFERENCE_ROOT:?STYLE_REFERENCE_ROOT is not set}"
unset CRATEDIGGER_STYLE CRATEDIGGER_STYLE_PRESSED
unset CRATEDIGGER_THEME_EDITOR CRATEDIGGER_THEME_PREVIEW CRATEDIGGER_THEME_PICKER STYLE_CAPTURE_TITLE
OUT="$SCRATCH/real-check"; mkdir -p "$OUT"
NAME="$THEME-$MODE-$LAYOUT${CRATEDIGGER_OLED:+-$CRATEDIGGER_OLED}"
REF="$OUT/$NAME.ref.png"; NEW="$OUT/$NAME.new.png"
rm -f "$REF" "$NEW"
STYLE_CAPTURE_ROOT="$STYLE_REFERENCE_ROOT" "$HERE/style-capture.sh" "$THEME" "$MODE" "$LAYOUT" "$REF" || { rc=$?; echo "reference capture failed ($rc)" >&2; exit $rc; }
"$HERE/style-capture.sh" "$THEME" "$MODE" "$LAYOUT" "$NEW" || { rc=$?; echo "current capture failed ($rc)" >&2; exit $rc; }
"$HERE/style-compare.sh" "$REF" "$NEW"
