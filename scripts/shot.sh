#!/usr/bin/env bash
#
# Screenshot the running CrateDigger window.
#
# Every visual regression in this app has been caught by looking at it, not by
# reading the code. This makes "look at it" one command, so a UI change can be
# verified before it is handed back rather than after someone notices.
#
#   scripts/shot.sh                       capture to /tmp, print the path
#   scripts/shot.sh out.png               capture to out.png
#   scripts/shot.sh out.png 1089 243      click window-relative (1089,243) first
#
# Launches the debug binary if the app is not already running, and leaves it
# running afterwards so successive shots cost about a second each.
#
# Captures the window region only, never the whole screen, so a shot never
# picks up whatever else is on the desktop.
#
# Requires: a debug build (swift build), plus Screen Recording and
# Accessibility permission for whichever terminal runs this.

set -euo pipefail

APP_NAME="CrateDiggerApp"
BIN=".build/arm64-apple-macosx/debug/$APP_NAME"
OUT="${1:-/tmp/cratedigger-$(date +%H%M%S).png}"

win() {
  osascript -e "tell application \"System Events\" to tell process \"$APP_NAME\" to get {position, size} of window 1" 2>/dev/null
}

if ! pgrep -qf "$BIN"; then
  if [ ! -x "$BIN" ]; then
    echo "No debug build at $BIN. Run: swift build" >&2
    exit 1
  fi
  "$BIN" >/dev/null 2>&1 &
  # Poll for the window instead of guessing a launch duration: a cold start
  # after a rebuild is far slower than a warm one.
  for _ in $(seq 1 60); do
    win >/dev/null && break
    sleep 0.5
  done
fi

bounds="$(win | tr -d ' ')"
if [ -z "$bounds" ]; then
  echo "Could not read the $APP_NAME window. Is Accessibility permission granted?" >&2
  exit 1
fi
IFS=, read -r x y w h <<<"$bounds"

if [ "$#" -ge 3 ]; then
  # uiclick posts real HID events. System Events "click at" was tried and
  # reports success against SwiftUI controls without actually pressing them.
  swift "$(dirname "$0")/uiclick.swift" "$2" "$3"
  # The window may have moved if the click dragged the chassis, so re-read.
  bounds="$(win | tr -d ' ')"
  IFS=, read -r x y w h <<<"$bounds"
fi

screencapture -x -R"$x,$y,$w,$h" "$OUT"
echo "$OUT"
