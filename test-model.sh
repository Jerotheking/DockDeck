#!/usr/bin/env bash
# Headless regression suite. Covers the store, persistence and recovery,
# settings normalisation, Dock-relative placement geometry, spring parameters,
# rename validation, archive preconditions, and safe removal.
# Runtime/UI behaviour is in verify-app.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/.build/model-selftest"
mkdir -p "$ROOT/.build"
swiftc -O -parse-as-library -D DOCKDECK_SELFTEST \
  -target arm64-apple-macosx13.0 -framework AppKit \
  "$ROOT/Sources/ShelfModel.swift" \
  "$ROOT/Sources/DockGeometry.swift" \
  "$ROOT/Sources/DockWatcher.swift" \
  "$ROOT/Sources/DockSensor.swift" \
  "$ROOT/Sources/ShelfGeometry.swift" \
  "$ROOT/Sources/ShelfMotion.swift" \
  "$ROOT/Sources/NotchGeometry.swift" \
  "$ROOT/Sources/ShelfSettings.swift" \
  "$ROOT/Sources/ProjectContext.swift" \
  "$ROOT/Sources/MarkdownExport.swift" \
  "$ROOT/Sources/FinderActions.swift" \
  "$ROOT/Sources/ModelSelfTest.swift" \
  -o "$OUT"
"$OUT"
