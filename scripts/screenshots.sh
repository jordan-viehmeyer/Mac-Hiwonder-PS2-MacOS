#!/usr/bin/env bash
# Capture the README screenshots from the live app.
#
# ImageRenderer cannot draw AppKit-backed controls (Picker, Toggle) or ScrollView contents,
# so anything with real controls has to be captured from a real window. The app poses
# itself at a known rect and prints it; this captures exactly that rect.
#
# Needs Screen Recording permission for the terminal running this.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO_ROOT/build/PS2MC.app"
OUT="$REPO_ROOT/docs/screenshots"
mkdir -p "$OUT"

[ -d "$APP" ] || { echo "build the app first: ./scripts/build-app.sh" >&2; exit 1; }

# The pure-SwiftUI controller diagram renders faithfully off-screen, so take that one
# without involving the screen at all.
"$APP/Contents/MacOS/PS2MC" --render-docs "$OUT" >/dev/null

capture() {
  local view="$1" name="$2"
  pkill -x PS2MC 2>/dev/null || true
  sleep 1

  local log; log="$(mktemp)"
  "$APP/Contents/MacOS/PS2MC" --docs-pose "$view" >"$log" 2>/dev/null &
  local pid=$!

  local rect="" tries=0
  while [ -z "$rect" ] && [ $tries -lt 40 ]; do
    sleep 0.25
    rect="$(grep -m1 '^RECT ' "$log" 2>/dev/null | cut -d' ' -f2 || true)"
    tries=$((tries + 1))
  done

  if [ -z "$rect" ]; then
    echo "  ! $name: window never reported its position" >&2
    kill "$pid" 2>/dev/null || true
    return 1
  fi

  sleep 1.2   # let the window finish drawing
  if screencapture -x -R "$rect" "$OUT/$name.png" 2>/dev/null && [ -s "$OUT/$name.png" ]; then
    echo "  ✓ $name.png"
  else
    echo "  ! $name: screencapture failed -- grant Screen Recording to this terminal" >&2
  fi
  kill "$pid" 2>/dev/null || true
  rm -f "$log"
}

echo "Capturing screenshots into $OUT"
capture status      status
capture bindings    bindings
capture tuning      tuning
capture calibration calibration
capture wizard      wizard
pkill -x PS2MC 2>/dev/null || true
echo "Done."
