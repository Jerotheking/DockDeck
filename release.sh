#!/usr/bin/env bash
#
# Reproducible release build: clean, test, build, verify, package.
#
# Stops at the first failure. It does not sign for distribution and does not
# notarize — those need credentials and are separate, explicit steps.
#
# Usage: release.sh [--format zip|dmg] [--skip-runtime]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
FORMAT="zip"
SKIP_RUNTIME=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --format) FORMAT="$2"; shift 2 ;;
    --format=*) FORMAT="${1#*=}"; shift ;;
    --skip-runtime) SKIP_RUNTIME=1; shift ;;
    *) echo "release.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

step() { printf '\n=== %s ===\n' "$1"; }

step "Model and geometry suite"
bash "$ROOT/test-model.sh"

step "Strict typecheck"
# Every source except the self-test entry point, which has its own @main.
# shellcheck disable=SC2046
swiftc -typecheck -target arm64-apple-macosx13.0 -framework AppKit -framework Carbon \
  $(ls "$ROOT"/Sources/*.swift | grep -v ModelSelfTest)
echo "typecheck clean"

step "Icon"
bash "$ROOT/tools/make-icon.sh"

step "Build"
bash "$ROOT/build.sh"

step "Bundle checks"
plutil -lint "$ROOT/DockDeck.app/Contents/Info.plist"
file "$ROOT/DockDeck.app/Contents/MacOS/DockDeck"
codesign --verify --deep --strict "$ROOT/DockDeck.app"
echo "bundle checks passed"

if [[ $SKIP_RUNTIME -eq 0 ]]; then
  step "Runtime verification"
  bash "$ROOT/verify-app.sh" --no-build
fi

step "Reproducibility"
FIRST="$(shasum -a 256 "$ROOT/DockDeck.app/Contents/MacOS/DockDeck" | awk '{print $1}')"
bash "$ROOT/build.sh" >/dev/null
SECOND="$(shasum -a 256 "$ROOT/DockDeck.app/Contents/MacOS/DockDeck" | awk '{print $1}')"
if [[ "$FIRST" == "$SECOND" ]]; then
  echo "reproducible: two consecutive builds produced the same executable"
  echo "  sha256 $FIRST"
else
  # Reported, not hidden: the build is still valid, it is just not bit-identical.
  echo "NOT bit-reproducible across builds on this machine:" >&2
  echo "  first  $FIRST" >&2
  echo "  second $SECOND" >&2
fi

step "Package"
bash "$ROOT/package.sh" --format "$FORMAT"

printf '\nRelease build complete.\n'
