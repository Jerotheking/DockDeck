#!/usr/bin/env bash
#
# Acceptance test for the requirement "the shelves must follow the Dock when it
# gets smaller or larger, automatically".
#
# Resizes the real Dock through System Events — the same API System Settings
# uses, applied live with no Dock restart — and asserts the shelves re-measure
# and move. The original size is always restored, including on failure.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib-paths.sh"
APP="$(dockdeck_artifact_root "$ROOT")/DockDeck.app"
BINARY="$APP/Contents/MacOS/DockDeck"
WORK="$(mktemp -d)"
PASS=0
FAIL=0

ORIGINAL_TILESIZE="$(defaults read com.apple.dock tilesize 2>/dev/null || echo 48)"

cleanup() {
  # Restore the user's Dock first, whatever happened.
  osascript -e "tell application \"System Events\" to tell dock preferences to set dock size to $(python3 -c "print(max(0.0,min(1.0,($ORIGINAL_TILESIZE-16)/112)))")" >/dev/null 2>&1
  for pid in $(pgrep -f "DockDeck.app/Contents/MacOS/DockDeck" 2>/dev/null); do
    [[ "$(ps -p "$pid" -o command= 2>/dev/null)" == "$BINARY"* ]] && kill -TERM "$pid" 2>/dev/null
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

assert() {
  if [[ "$2" == "true" ]]; then printf '  ok    %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); fi
}

# tilesize 16...128 maps to System Events' 0.0...1.0 dock size.
set_dock_size() {
  local tilesize="$1"
  local fraction
  fraction="$(python3 -c "print(max(0.0,min(1.0,($tilesize-16)/112)))")"
  osascript -e "tell application \"System Events\" to tell dock preferences to set dock size to $fraction" >/dev/null 2>&1
}

read_shelf() { python3 -c "
import json,sys
try: d=json.load(open('$1'))
except Exception: print('ERR'); sys.exit()
s=d['shelves'].get('$2',{})
print(f\"{d['dock']['thickness']}|{s.get('collapsedFrame','?')}|{d['dock'].get('tileSize','?')}|{s.get('placementMode','?')}|{s.get('layoutViable','?')}\")"; }

# Every shelf must be viable and usable at this instant, whatever the Dock is
# doing. A shelf that disappears because the Dock got big is a product failure,
# not an edge case.
check_all_viable() {
  python3 -c "
import json
d=json.load(open('$1'))
ok = bool(d['shelves']) and all(v['layoutViable'] and v['usableFrame'] for v in d['shelves'].values())
print('true' if ok else 'false')" 2>/dev/null || echo false
}

echo "DockDeck — Dock resize acceptance test"
echo "======================================"
echo "original tilesize: $ORIGINAL_TILESIZE"

[[ -x "$BINARY" ]] || { echo "  FAIL  app not built at $BINARY"; exit 1; }

report="$WORK/live.json"
DOCKDECK_DIAGNOSTICS=1 \
DOCKDECK_DIAGNOSTICS_PATH="$report" \
DOCKDECK_DIAGNOSTICS_INTERVAL=1 \
DOCKDECK_SUPPORT_DIR="$WORK/support" \
"$BINARY" >"$WORK/run.log" 2>&1 &

waited=0
while [[ ! -s "$report" && $waited -lt 40 ]]; do /bin/sleep 0.25; waited=$((waited + 1)); done
[[ -s "$report" ]] || { echo "  FAIL  app produced no diagnostics"; exit 1; }

BEFORE="$(read_shelf "$report" leading)"
before_thickness="${BEFORE%%|*}"
echo "  before: $BEFORE"

# --- Grow the Dock -----------------------------------------------------------
set_dock_size 96
/bin/sleep 4
AFTER_BIG="$(read_shelf "$report" leading)"
big_thickness="${AFTER_BIG%%|*}"
echo "  bigger: $AFTER_BIG"
assert "shelves survive a big Dock (no vanishing)" "$(check_all_viable "$report")"
assert "a bigger Dock makes the shelf thicker ($before_thickness -> $big_thickness)" \
  "$(python3 -c "print('true' if float('$big_thickness') > float('$before_thickness') + 2 else 'false')" 2>/dev/null || echo false)"

# --- Shrink the Dock ---------------------------------------------------------
set_dock_size 24
/bin/sleep 4
AFTER_SMALL="$(read_shelf "$report" leading)"
small_thickness="${AFTER_SMALL%%|*}"
echo "  smaller: $AFTER_SMALL"
assert "shelves survive a small Dock" "$(check_all_viable "$report")"
assert "a smaller Dock makes the shelf thinner ($big_thickness -> $small_thickness)" \
  "$(python3 -c "print('true' if float('$small_thickness') < float('$big_thickness') - 2 else 'false')" 2>/dev/null || echo false)"

# A Dock small enough to leave a gap must return to in-gap placement; a Dock
# too big for one must fall back to a sidecar. That transition IS the feature.
big_mode="$(printf '%s' "$AFTER_BIG" | cut -d'|' -f4)"
small_mode="$(printf '%s' "$AFTER_SMALL" | cut -d'|' -f4)"
assert "a small Dock places in its own gap (got $small_mode)" \
  "$([[ "$small_mode" == "inGap" ]] && echo true || echo false)"
assert "a Dock too big for a gap falls back to a sidecar (got $big_mode)" \
  "$([[ "$big_mode" == "sidecar" ]] && echo true || echo false)"


# --- Maximum Dock: the case that used to make them disappear -----------------
set_dock_size 128
/bin/sleep 4
AFTER_MAX="$(read_shelf "$report" leading)"
echo "  maximum: $AFTER_MAX"
assert "shelves survive the largest possible Dock" "$(check_all_viable "$report")"

# --- Still usable afterwards -------------------------------------------------
usable="$(python3 -c "
import json
d=json.load(open('$report'))
print('true' if all(v['usableFrame'] and v['layoutViable'] for v in d['shelves'].values()) else 'false')" 2>/dev/null || echo false)"
assert "both shelves remain viable and usable after resizing" "$usable"

adjacent="$(python3 -c "
import json
d=json.load(open('$report'))
print('true' if all(abs(float(v['adjacentToDock'])) < 2 for v in d['shelves'].values()) else 'false')" 2>/dev/null || echo false)"
assert "both shelves are still touching the Dock after resizing" "$adjacent"

echo "======================================"
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
