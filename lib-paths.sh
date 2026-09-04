#!/usr/bin/env bash
# Shared path resolution. Sourced by build.sh, verify-app.sh and package.sh so
# they cannot disagree about where the app is.
#
# Build products never live inside a sync provider: iCloud Drive re-attaches
# extended attributes asynchronously, which invalidates a code signature after
# it is applied, and can evacuate files to the cloud leaving dataless stubs.
# Source can live wherever the user keeps it; artefacts go somewhere local.

# The provider marks the synced root, not every descendant, so walk up to $HOME.
dockdeck_is_synced() {
  local dir="$1"
  while [[ "$dir" != "/" && "$dir" != "$HOME" && -n "$dir" ]]; do
    if xattr "$dir" 2>/dev/null | grep -q 'com.apple.fileprovider'; then return 0; fi
    dir="$(dirname "$dir")"
  done
  return 1
}

dockdeck_artifact_root() {
  local root="$1"
  if [[ -n "${DOCKDECK_ARTIFACT_ROOT:-}" ]]; then
    printf '%s' "$DOCKDECK_ARTIFACT_ROOT"
  elif dockdeck_is_synced "$root"; then
    printf '%s' "$HOME/Library/Caches/DockDeck"
  else
    printf '%s' "$root"
  fi
}
