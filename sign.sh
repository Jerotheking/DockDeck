#!/usr/bin/env bash
#
# Replaces the ad-hoc signature on DockDeck.app with a Developer ID signature.
#
# Requires real credentials; there is no fallback and no simulation. If the
# variables are absent this script fails rather than producing something that
# looks signed.
#
#   DEVELOPER_ID_APPLICATION   e.g. "Developer ID Application: Your Name (TEAMID)"
#   TEAM_ID                    e.g. "ABCDE12345"
#   KEYCHAIN_PATH              optional: unlocked keychain holding the identity
#
# Usage: DEVELOPER_ID_APPLICATION="..." TEAM_ID="..." ./sign.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/DockDeck.app"

: "${DEVELOPER_ID_APPLICATION:?set DEVELOPER_ID_APPLICATION to your Developer ID Application identity}"
: "${TEAM_ID:?set TEAM_ID to your Apple Developer team identifier}"

[[ -d "$APP" ]] || { echo "sign.sh: $APP not found — run build.sh first" >&2; exit 1; }

if ! security find-identity -v -p codesigning ${KEYCHAIN_PATH:+"$KEYCHAIN_PATH"} | grep -qF "$DEVELOPER_ID_APPLICATION"; then
  echo "sign.sh: identity '$DEVELOPER_ID_APPLICATION' is not available for code signing" >&2
  echo "         available identities:" >&2
  security find-identity -v -p codesigning ${KEYCHAIN_PATH:+"$KEYCHAIN_PATH"} >&2
  exit 1
fi

# Hardened runtime is mandatory for notarization. DockDeck needs no entitlement
# exceptions: no JIT, no unsigned memory, no library validation opt-out, no
# network. If that ever changes, add an entitlements plist here rather than
# weakening the runtime.
codesign --force \
  --sign "$DEVELOPER_ID_APPLICATION" \
  --options runtime \
  --timestamp \
  ${KEYCHAIN_PATH:+--keychain "$KEYCHAIN_PATH"} \
  "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

echo "Signed $APP"
codesign -dv --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
echo
echo "Next: ./notarize.sh (Gatekeeper will still reject this build until it is notarized and stapled)"
