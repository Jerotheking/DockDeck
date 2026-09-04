#!/usr/bin/env bash
# Regenerates Resources/DockDeck.icns from tools/make-icon.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -O -target arm64-apple-macosx13.0 -framework AppKit "$ROOT/tools/make-icon.swift" -o "$WORK/make-icon"
"$WORK/make-icon" "$WORK"
mkdir -p "$ROOT/Resources"
iconutil -c icns "$WORK/DockDeck.iconset" -o "$ROOT/Resources/DockDeck.icns"
printf 'Wrote %s (%s bytes)\n' "$ROOT/Resources/DockDeck.icns" "$(stat -f%z "$ROOT/Resources/DockDeck.icns")"
