#!/usr/bin/env bash
#
# Packages DockDeck.app into a distributable archive with checksums and a
# release manifest that states, honestly, what the artifact is.
#
# Usage: package.sh [--format zip|dmg]   (default: zip)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-paths.sh
source "$ROOT/lib-paths.sh"
ARTIFACT_ROOT="$(dockdeck_artifact_root "$ROOT")"
APP="$ARTIFACT_ROOT/DockDeck.app"
DIST="$ARTIFACT_ROOT/dist"
FORMAT="zip"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --format) FORMAT="$2"; shift 2 ;;
    --format=*) FORMAT="${1#*=}"; shift ;;
    *) echo "package.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

[[ -d "$APP" ]] || { echo "package.sh: $APP not found — run build.sh first" >&2; exit 1; }

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")"
NAME="DockDeck-$VERSION"

rm -rf "$DIST"
mkdir -p "$DIST/$NAME"
cp -R "$APP" "$DIST/$NAME/"
for doc in README.md CHANGELOG.md RELEASE.md LICENSE NOTICE; do
  [[ -f "$ROOT/$doc" ]] && cp "$ROOT/$doc" "$DIST/$NAME/"
done

# Signature status, read from the artifact rather than assumed.
SIGNATURE_LINE="$(codesign -dv "$APP" 2>&1 | grep '^Signature=' || echo 'Signature=none')"
case "$SIGNATURE_LINE" in
  *adhoc*) SIGN_STATUS="ad-hoc (development build — NOT distributable)" ;;
  *none*)  SIGN_STATUS="unsigned — NOT distributable" ;;
  *)       SIGN_STATUS="$(codesign -dv --verbose=2 "$APP" 2>&1 | grep 'Authority=' | head -1 | sed 's/Authority=//')" ;;
esac

if xcrun stapler validate "$APP" >/dev/null 2>&1; then
  NOTARY_STATUS="notarized and stapled"
else
  NOTARY_STATUS="NOT notarized"
fi

case "$FORMAT" in
  zip)
    ARTIFACT="$DIST/$NAME.zip"
    # ditto --keepParent preserves the bundle's symlinks and extended
    # attributes; `zip` does not, and a zip'd .app can arrive broken.
    ( cd "$DIST" && ditto -c -k --sequesterRsrc --keepParent "$NAME" "$NAME.zip" )
    ;;
  dmg)
    ARTIFACT="$DIST/$NAME.dmg"
    hdiutil create -volname "DockDeck $VERSION" -srcfolder "$DIST/$NAME" -ov -format UDZO "$ARTIFACT" >/dev/null
    ;;
  *)
    echo "package.sh: unknown format '$FORMAT' (expected zip or dmg)" >&2; exit 2 ;;
esac

CHECKSUM="$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
APP_CHECKSUM="$(shasum -a 256 "$APP/Contents/MacOS/DockDeck" | awk '{print $1}')"
shasum -a 256 "$ARTIFACT" > "$ARTIFACT.sha256"

cat > "$DIST/MANIFEST.txt" <<MANIFEST
DockDeck release manifest
=========================

Product             DockDeck $VERSION (build $BUILD_NUMBER)
Bundle identifier   $(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")
Artifact            $(basename "$ARTIFACT")
Artifact SHA-256    $CHECKSUM
Executable SHA-256  $APP_CHECKSUM

Build target        arm64-apple-macosx13.0
Architecture        $(lipo -archs "$APP/Contents/MacOS/DockDeck")
Minimum macOS       $(plutil -extract LSMinimumSystemVersion raw -o - "$APP/Contents/Info.plist")
Compiler            $(swiftc --version | head -1)
Built on            $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))
SDK                 macOS $(xcrun --show-sdk-version)

Signature           $SIGN_STATUS
Notarization        $NOTARY_STATUS

Verified by         test-model.sh (headless model + geometry suite)
                    verify-app.sh (runtime launch, visibility, shutdown)

Notes
-----
An ad-hoc signed build runs only on the machine that produced it, and Gatekeeper
will refuse it elsewhere until the quarantine attribute is cleared by hand. For
distribution, run sign.sh with a Developer ID identity, then notarize.sh, then
re-run this script.
MANIFEST

echo "Packaged $ARTIFACT"
echo "  sha256        $CHECKSUM"
echo "  signature     $SIGN_STATUS"
echo "  notarization  $NOTARY_STATUS"
echo "  manifest      $DIST/MANIFEST.txt"
