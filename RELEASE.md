# Release status

**Current state: development build. Not distributable.**

DockDeck 1.0.0 builds, launches, and has been verified at runtime on the machine
it was developed on. It is **ad-hoc signed and not notarized**, which means it
runs here and will be refused by Gatekeeper anywhere else.

## What has been verified

| Check | How | Result |
| --- | --- | --- |
| Model, persistence, settings, geometry, springs | `test-model.sh` | 137 checks, 5 consecutive runs |
| Strict typecheck | `swiftc -typecheck` on all sources | clean |
| Bundle builds | `build.sh` | arm64, Info.plist lints |
| Signature integrity | `codesign --verify --deep --strict` | valid (ad-hoc) |
| Launch, visibility, shutdown | `verify-app.sh --runs=5` | 47 checks, 0 failures |
| Shelf actually on screen | `NSWindow.occlusionState` reported by the app | `true`, both shelves |
| Shelf touching the Dock | measured adjacency | 0 pt, both shelves |
| Duplicate launch | second `open` of the bundle | one process |
| Shutdown | process table after quit | no orphans |

### What "visible" means here

`verify-app.sh` does not conclude the app works because a process exists — that
was the original bug. It runs the app with `DOCKDECK_DIAGNOSTICS=1` and asserts
on `NSWindow.occlusionState`, which is the window server's own answer to whether
a window is on screen, read from inside the process that owns it.

An external check was attempted first and **rejected as unreliable**:
`CGWindowListCopyWindowInfo` returned zero windows for *every* application on
this machine, because the Screen Recording permission is not granted. That zero
was a false negative, not evidence.

### What has NOT been verified

- **Visual appearance.** No screenshot or pixel comparison was made: screen
  capture needs the same missing Screen Recording grant. Geometry, visibility,
  and adjacency are asserted numerically; how the frosted glass and animations
  *look* has not been machine-checked.
- **Any Dock configuration other than this machine's.** Runtime verification ran
  against a right-hand, auto-hiding Dock with magnification, 53 pt thick, on a
  3440x1440 display. Bottom and left Docks, pinned Docks, and other display
  arrangements are covered by the headless geometry suite, not by a live run.
- **Any other machine, macOS version, or Intel hardware.**
- **Behaviour without the Accessibility permission.** The estimated-measurement
  path is exercised by unit tests, but was not run live: this machine has the
  grant. Its thickness formula predicts 53 pt here, matching the exact reading;
  its Dock *length* estimate is known to be less accurate.

## Signing and notarization

Nothing here is faked. The build is honestly labelled at every step: `build.sh`
prints `ad-hoc (development build — not notarized, not distributable)`, and
`package.sh` reads the real signature out of the artifact rather than assuming.

To produce a distributable build you need an Apple Developer account:

```bash
# 1. Sign with a Developer ID and the hardened runtime
DEVELOPER_ID_APPLICATION="Developer ID Application: NAME (TEAMID)" \
TEAM_ID="TEAMID" \
./sign.sh

# 2. Package
./package.sh --format dmg

# 3. Notarize and staple
NOTARY_PROFILE="dockdeck" ./notarize.sh
# or: APPLE_ID=… APPLE_APP_PASSWORD=… TEAM_ID=… ./notarize.sh

# 4. Repackage so the artifact carries the ticket, then verify
./package.sh --format dmg
spctl --assess --type execute --verbose=4 DockDeck.app
```

`sign.sh` fails if the identity is absent rather than falling back to ad-hoc.
`notarize.sh` refuses to submit an ad-hoc build.

## Blockers for an actual release

These need a person or credentials; none can be resolved from here.

1. **No Apple Developer ID.** Without it there is no Developer ID signature and
   no notarization, so the app cannot run on anyone else's Mac.
2. **No licence chosen.** There is no `LICENSE` file. `NOTICE.md` records that
   there are no third-party dependencies, but the terms for DockDeck itself are
   an owner decision and were not invented here.
3. **Bundle identifier is provisional.** `com.sintelia.dockdeck` was chosen to
   replace the inherited `com.freebuff.dockshelf`. It must match the Developer
   ID team before first distribution — changing it afterwards orphans user data.
4. **Not tested on a second machine** or on any macOS version other than 26.6.
5. **Visual QA is manual.** Someone has to look at it.

## Installing the development build elsewhere

Only for testing, and it will be quarantined:

```bash
xattr -dr com.apple.quarantine /Applications/DockDeck.app
```

Requiring that command is exactly what notarization removes. Do not ship a build
that needs it.
