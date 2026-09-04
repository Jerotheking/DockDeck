#!/usr/bin/env bash
#
# Submits a Developer ID signed DockDeck build to Apple's notary service and
# staples the ticket.
#
# Requires one of:
#   NOTARY_PROFILE                    keychain profile from `xcrun notarytool store-credentials`
# or all three of:
#   APPLE_ID, APPLE_APP_PASSWORD, TEAM_ID
#
# Usage: NOTARY_PROFILE="dockdeck" ./notarize.sh [path-to-artifact]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT="${1:-}"

if [[ -z "$ARTIFACT" ]]; then
  ARTIFACT="$(ls -t "$ROOT"/dist/DockDeck-*.zip "$ROOT"/dist/DockDeck-*.dmg 2>/dev/null | head -1 || true)"
fi
[[ -n "$ARTIFACT" && -f "$ARTIFACT" ]] || { echo "notarize.sh: no artifact to submit — run package.sh first" >&2; exit 1; }

NOTARY_ARGS=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" && -n "${TEAM_ID:-}" ]]; then
  NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$TEAM_ID")
else
  echo "notarize.sh: set NOTARY_PROFILE, or APPLE_ID + APPLE_APP_PASSWORD + TEAM_ID" >&2
  exit 1
fi

# Refuse to submit an ad-hoc build: the notary service would reject it anyway,
# and a rejection is a slower, less clear error than this one.
APP="$ROOT/DockDeck.app"
if [[ -d "$APP" ]] && codesign -dv "$APP" 2>&1 | grep -q 'Signature=adhoc'; then
  echo "notarize.sh: DockDeck.app is ad-hoc signed. Run sign.sh with a Developer ID first." >&2
  exit 1
fi

echo "Submitting $ARTIFACT to the notary service…"
xcrun notarytool submit "$ARTIFACT" "${NOTARY_ARGS[@]}" --wait --timeout 30m

case "$ARTIFACT" in
  *.dmg) xcrun stapler staple "$ARTIFACT" ;;
  *.zip)
    # A ticket cannot be stapled to a zip; staple the app and repackage.
    xcrun stapler staple "$APP"
    echo "Stapled $APP — re-run package.sh so the artifact carries the ticket."
    ;;
esac

xcrun stapler validate "$ARTIFACT" 2>/dev/null || xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"
echo "Notarization complete."
