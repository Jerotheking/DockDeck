#!/usr/bin/env bash
#
# Builds DockDeck.app.
#
# The result is ad-hoc signed: valid on this Mac, NOT distributable. Producing a
# distributable build means running sign.sh and notarize.sh with real Developer
# ID credentials; see RELEASE.md.
#
# Usage: build.sh [--install]
#   --install  also copy the built app to ~/Applications (outside any synced
#              folder), which is where it should be run from.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-paths.sh
source "$ROOT/lib-paths.sh"
ARTIFACT_ROOT="$(dockdeck_artifact_root "$ROOT")"
mkdir -p "$ARTIFACT_ROOT"
BUILD="$ARTIFACT_ROOT/.build"
APP="$ARTIFACT_ROOT/DockDeck.app"
ARCH="$(uname -m)"
DEPLOYMENT_TARGET="13.0"
BUNDLE_ID="com.sintelia.dockdeck"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD_NUMBER="$(tr -d '[:space:]' < "$ROOT/BUILD_NUMBER")"

if [[ "$ARCH" != "arm64" ]]; then
  echo "DockDeck: expected Apple Silicon arm64, found $ARCH" >&2
  exit 1
fi

if [[ ! -f "$ROOT/Resources/DockDeck.icns" ]]; then
  echo "DockDeck: missing Resources/DockDeck.icns — run tools/make-icon.sh" >&2
  exit 1
fi

rm -rf "$BUILD" "$APP"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Source order is fixed so the build is reproducible; main.swift must be present
# for the explicit entry point (see Sources/main.swift).
SOURCES=(
  main.swift
  AppDelegate.swift
  CommandPalette.swift
  Diagnostics.swift
  DragActivation.swift
  DockGeometry.swift
  DockWatcher.swift
  DockSensor.swift
  GlassInteractor.swift
  FinderActions.swift
  GlobalHotkey.swift
  MarkdownExport.swift
  Onboarding.swift
  PreferencesWindow.swift
  ProjectContext.swift
  QuickLookPreview.swift
  ShelfChrome.swift
  ShelfGeometry.swift
  ShelfModel.swift
  ShelfMotion.swift
  ShelfPanel.swift
  ShelfRowView.swift
  ShelfSettings.swift
  ShelfTileView.swift
  ShelfViewController.swift
  SmartFolders.swift
  ThumbnailProvider.swift
  WorkspaceMonitor.swift
)
SOURCE_PATHS=()
for source in "${SOURCES[@]}"; do
  path="$ROOT/Sources/$source"
  [[ -f "$path" ]] || { echo "DockDeck: missing source $path" >&2; exit 1; }
  SOURCE_PATHS+=("$path")
done

swiftc -O -whole-module-optimization \
  -target "arm64-apple-macosx${DEPLOYMENT_TARGET}" \
  -framework AppKit -framework Carbon \
  "${SOURCE_PATHS[@]}" \
  -o "$BUILD/DockDeck"

install -m 755 "$BUILD/DockDeck" "$APP/Contents/MacOS/DockDeck"
install -m 644 "$ROOT/Resources/DockDeck.icns" "$APP/Contents/Resources/DockDeck.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>DockDeck</string>
  <key>CFBundleDisplayName</key><string>DockDeck</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>DockDeck</string>
  <key>CFBundleIconFile</key><string>DockDeck</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSUIElement</key><true/>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>LSMinimumSystemVersion</key><string>${DEPLOYMENT_TARGET}</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>DockDeck ${VERSION}. Local-only utility; no network access, no telemetry.</string>
</dict></plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Extended attributes must go before signing: codesign refuses a bundle carrying
# resource forks or Finder metadata, which is exactly what a copy from a Time
# Machine snapshot, a Finder drag, or a sync provider leaves behind.
#
# Done twice on purpose. A file provider (iCloud Drive) re-attaches attributes
# asynchronously, so the recursive sweep can be undone on the bundle root before
# codesign looks at it; the second, root-only pass closes that window.
xattr -cr "$APP" 2>/dev/null || true
xattr -c "$APP" 2>/dev/null || true


# Ad-hoc signature. Enough for Gatekeeper to run it locally after the quarantine
# bit is cleared; it carries no identity and satisfies no distribution
# requirement. sign.sh replaces it with a Developer ID signature.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

printf 'Built %s\n' "$APP"
[[ "$ARTIFACT_ROOT" != "$ROOT" ]] && printf '  artifacts    outside the synced source tree (%s)\n' "$ARTIFACT_ROOT"
printf '  version      %s (build %s)\n' "$VERSION" "$BUILD_NUMBER"
printf '  target       arm64-apple-macosx%s\n' "$DEPLOYMENT_TARGET"
printf '  swift        %s\n' "$(swiftc --version | head -1)"
printf '  signature    ad-hoc (development build — not notarized, not distributable)\n'

if [[ "${1:-}" == "--install" ]]; then
  INSTALL_DIR="$HOME/Applications"
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR/DockDeck.app"
  ditto "$APP" "$INSTALL_DIR/DockDeck.app"
  xattr -cr "$INSTALL_DIR/DockDeck.app" 2>/dev/null || true
  codesign --force --sign - --timestamp=none "$INSTALL_DIR/DockDeck.app"
  codesign --verify --strict "$INSTALL_DIR/DockDeck.app"
  printf '  installed    %s\n' "$INSTALL_DIR/DockDeck.app"
fi
