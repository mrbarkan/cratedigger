#!/bin/bash
# Isolated window capture for interface-style work.
# Usage: scripts/style-capture.sh <theme-id> <light|dark> <full|compact|mini> <out.png>
# Needs: SCRATCH (outside /Volumes). Optional: DEMO_LIBRARY (crates folder to copy),
# COVER (image shown in compact/mini), CRATEDIGGER_STYLE (passed through).
# Builds nothing: run `swift build` first.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
THEME="${1:?theme id}"; MODE="${2:?light|dark}"; LAYOUT="${3:?full|compact|mini}"; OUT="${4:?out.png}"

case "${SCRATCH:-}" in
  "") echo "SCRATCH is not set" >&2; exit 2 ;;
  /Volumes/*) echo "SCRATCH must be outside /Volumes" >&2; exit 2 ;;
esac
case "$MODE" in light|dark) ;; *) echo "mode must be light or dark" >&2; exit 2 ;; esac
case "$LAYOUT" in full|compact|mini) ;; *) echo "layout must be full, compact or mini" >&2; exit 2 ;; esac

SRC="$ROOT/.build/debug/CrateDiggerApp"
[ -x "$SRC" ] || { echo "missing $SRC (run swift build)" >&2; exit 2; }
BIN="$SCRATCH/CDStyleCapture"
PLIST="$HOME/Library/Preferences/CrateDiggerApp.plist"
sum() { [ -f "$PLIST" ] && shasum "$PLIST" | cut -d' ' -f1 || echo none; }

# winid helper, compiled once
WINID="$SCRATCH/winid"
if [ ! -x "$WINID" ] || [ "$ROOT/scripts/winid.swift" -nt "$WINID" ]; then
  swiftc -O "$ROOT/scripts/winid.swift" -o "$WINID" || exit 2
fi

mkdir -p "$SCRATCH" "$(dirname "$OUT")"
pkill -f "$BIN" 2>/dev/null
sleep 0.5
cp "$SRC" "$BIN"
# The copy finds Sparkle through @loader_path, so link the built framework beside it.
rm -rf "$SCRATCH/Sparkle.framework"
ln -s "$ROOT/.build/out/Products/Debug/Sparkle.framework" "$SCRATCH/Sparkle.framework"
rm -rf "$SCRATCH/crates" "$SCRATCH/home"
mkdir -p "$SCRATCH/crates" "$SCRATCH/home"
[ -n "${DEMO_LIBRARY:-}" ] && [ -d "$DEMO_LIBRARY" ] && cp -R "$DEMO_LIBRARY/." "$SCRATCH/crates/"

before="$(sum)"
defaults delete CDStyleCapture 2>/dev/null
defaults write CDStyleCapture cratedigger.onboarding.completed -bool true
defaults write CDStyleCapture cratedigger.onboarding.tourSeen -bool true
defaults write CDStyleCapture cratedigger.onboarding.whatsNewVersion -string 2.4.0
defaults write CDStyleCapture CrateDigger.appearanceMode -string "$MODE"
defaults write CDStyleCapture cratedigger.ui.selectedThemeID -string "$THEME"

ENVV=(CRATEDIGGER_CRATES_DIR="$SCRATCH/crates" CFFIXED_USER_HOME="$SCRATCH/home"
      CRATEDIGGER_SNAPSHOT_PATH="$SCRATCH/snap.png")
[ -n "${CRATEDIGGER_STYLE:-}" ] && ENVV+=(CRATEDIGGER_STYLE="$CRATEDIGGER_STYLE")
[ "$LAYOUT" = compact ] && ENVV+=(CRATEDIGGER_COMPACT=1)
[ "$LAYOUT" = mini ] && ENVV+=(CRATEDIGGER_MINI=1)
if [ "$LAYOUT" != full ] && [ -n "${COVER:-}" ]; then ENVV+=(CRATEDIGGER_COVER="$COVER"); fi

env "${ENVV[@]}" "$BIN" >"$SCRATCH/capture.log" 2>&1 &
APP_PID=$!
sleep 9

# columns: id layer width height name
# The mini player floats (layer 3), so it is picked by size alone.
WID=""
if [ "$LAYOUT" = mini ]; then
  WID="$("$WINID" CDStyleCapture | awk '$3<500 {print $3*$4, $1}' | sort -n | head -1 | cut -d' ' -f2)"
else
  WID="$("$WINID" CDStyleCapture | awk '$2==0 {print $3*$4, $1}' | sort -n | tail -1 | cut -d' ' -f2)"
fi
status=0
if [ -z "$WID" ]; then
  echo "no window found for CDStyleCapture" >&2; status=1
else
  screencapture -l "$WID" -o "$OUT" || status=1
fi
pkill -f "$BIN" 2>/dev/null
wait "$APP_PID" 2>/dev/null
if [ "$(sum)" != "$before" ]; then echo "PREFS CHANGED" >&2; exit 3; fi
exit $status
