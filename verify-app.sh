#!/usr/bin/env bash
#
# Runtime verification for DockDeck.app.
#
# A live process is not evidence the app works: DockDeck's original failure was
# a healthy process with no delegate, no window, and no menu bar item. This
# script asserts on what the app reports about itself from inside the process,
# where NSWindow.occlusionState is available without a Screen Recording grant.
#
# Usage: verify-app.sh [--no-build] [--runs N]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-paths.sh
source "$ROOT/lib-paths.sh"
APP="$(dockdeck_artifact_root "$ROOT")/DockDeck.app"
BINARY="$APP/Contents/MacOS/DockDeck"
WORK="$(mktemp -d)"
RUNS=1
DO_BUILD=1
PASS=0
FAIL=0

for arg in "$@"; do
  case "$arg" in
    --no-build) DO_BUILD=0 ;;
    --runs) shift ;;
    --runs=*) RUNS="${arg#*=}" ;;
    [0-9]*) RUNS="$arg" ;;
  esac
done

cleanup() {
  stop_dockdeck
  rm -rf "$WORK"
}
trap cleanup EXIT

check() {
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  ok    %s\n' "$description"; PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$description"; FAIL=$((FAIL + 1))
  fi
}

assert() {
  local description="$1" condition="$2"
  if [[ "$condition" == "true" ]]; then
    printf '  ok    %s\n' "$description"; PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$description"; FAIL=$((FAIL + 1))
  fi
}

# Terminates only processes whose full command is exactly a known DockDeck
# bundle executable — the build-tree bundle or the installed one. Never matches
# by bare name, never uses pkill/killall.
stop_dockdeck() {
  local pid command
  for pid in $(pgrep -f "DockDeck.app/Contents/MacOS/DockDeck" 2>/dev/null); do
    command="$(ps -p "$pid" -o command= 2>/dev/null)"
    if [[ "$command" == "$BINARY"* || "$command" == "$HOME/Applications/DockDeck.app/Contents/MacOS/DockDeck"* ]]; then
      kill -TERM "$pid" 2>/dev/null
    fi
  done
  local waited=0
  while pgrep -f "DockDeck.app/Contents/MacOS/DockDeck" >/dev/null 2>&1 && [[ $waited -lt 20 ]]; do
    /bin/sleep 0.25; waited=$((waited + 1))
  done
}

running_count() { pgrep -f "DockDeck.app/Contents/MacOS/DockDeck" 2>/dev/null | wc -l | tr -d ' '; }

json_get() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));k=sys.argv[2].split('.');v=d
for p in k: v=v[p]
print(str(v).lower() if isinstance(v,bool) else v)" "$1" "$2" 2>/dev/null; }

echo "DockDeck runtime verification"
echo "=============================="

if [[ $DO_BUILD -eq 1 ]]; then
  echo "[build]"
  if bash "$ROOT/build.sh" >"$WORK/build.log" 2>&1; then
    printf '  ok    build.sh succeeds\n'; PASS=$((PASS + 1))
  else
    printf '  FAIL  build.sh succeeds\n'; cat "$WORK/build.log"; FAIL=$((FAIL + 1)); exit 1
  fi
fi

echo "[bundle]"
check "app bundle exists" test -d "$APP"
check "executable exists" test -x "$BINARY"
check "Info.plist is valid" plutil -lint "$APP/Contents/Info.plist"
check "icon is present" test -f "$APP/Contents/Resources/DockDeck.icns"
check "signature verifies" codesign --verify --deep --strict "$APP"
ARCHS="$(lipo -archs "$BINARY" 2>/dev/null)"
assert "binary is arm64 (got: ${ARCHS:-none})" "$([[ "$ARCHS" == "arm64" ]] && echo true || echo false)"
for key in CFBundleShortVersionString CFBundleVersion CFBundleIdentifier CFBundleIconFile LSUIElement LSMinimumSystemVersion; do
  value="$(plutil -extract "$key" raw -o - "$APP/Contents/Info.plist" 2>/dev/null)"
  assert "Info.plist has $key (${value:-missing})" "$([[ -n "$value" ]] && echo true || echo false)"
done

echo "[runtime x$RUNS]"
stop_dockdeck
for run in $(seq 1 "$RUNS"); do
  report="$WORK/report-$run.json"
  # Run 1 exercises a genuine first launch (empty support dir); later runs reuse
  # it, which is the returning-user path. A scratch directory keeps the verifier
  # from touching the user's real shelf.
  support="$WORK/support"
  [[ "$run" == "1" ]] && rm -rf "$support"
  mkdir -p "$support"
  DOCKDECK_DIAGNOSTICS=1 DOCKDECK_DIAGNOSTICS_PATH="$report" DOCKDECK_SUPPORT_DIR="$support" "$BINARY" >"$WORK/run-$run.log" 2>&1 &
  pid=$!
  waited=0
  while [[ ! -s "$report" && $waited -lt 40 ]]; do /bin/sleep 0.25; waited=$((waited + 1)); done

  alive="$(ps -p "$pid" -o pid= 2>/dev/null | tr -d ' ')"
  assert "run $run: process is still alive (pid ${alive:-gone})" "$([[ -n "$alive" ]] && echo true || echo false)"
  assert "run $run: diagnostics report written" "$([[ -s "$report" ]] && echo true || echo false)"

  if [[ -s "$report" ]]; then
    if python3 "$ROOT/tools/check-report.py" "$report"; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + $?))
    fi
  fi

  # Second launch of a bundle marked LSMultipleInstancesProhibited must not
  # create a second process.
  open "$APP" >/dev/null 2>&1
  /bin/sleep 2
  count="$(running_count)"
  assert "run $run: duplicate launch leaves exactly one process (got $count)" "$([[ "$count" == "1" ]] && echo true || echo false)"

  stop_dockdeck
  after="$(running_count)"
  assert "run $run: shutdown leaves no orphan process (got $after)" "$([[ "$after" == "0" ]] && echo true || echo false)"

  if grep -q "DOCKDECK-EXCEPTION" "$WORK/run-$run.log" 2>/dev/null; then
    printf '  FAIL  run %s: uncaught exception during launch\n' "$run"
    grep "DOCKDECK-EXCEPTION" "$WORK/run-$run.log"
    FAIL=$((FAIL + 1))
  else
    printf '  ok    run %s: no uncaught exception\n' "$run"; PASS=$((PASS + 1))
  fi

  traces="$(grep -c 'DOCKDECK-TRACE' "$WORK/run-$run.log" 2>/dev/null || echo 0)"
  assert "run $run: all start-up phases reached ($traces/7)" "$([[ "$traces" -ge 7 ]] && echo true || echo false)"
done

echo "=============================="
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
