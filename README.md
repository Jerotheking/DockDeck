# DockDeck

A file shelf for macOS that lives beside your Dock.

DockDeck puts two thin shelves in the Dock's own strip — one on each side of it —
so they read as an extension of the Dock rather than as windows parked somewhere
on screen. They rest at the Dock's exact thickness and expand when you hover over
them or start dragging something.

Inspired by [Dockside](https://github.com/PrajwalSD/Dockside), which is a separate,
independent, commercial product. DockDeck shares none of its code: Dockside
publishes no source, and none was used, decompiled, or reverse-engineered. Only
its publicly documented behaviour informed this design.

## What you get

- **Library shelf** — files, folders, notes, clipboard history, and links you drop.
- **Recents shelf** — recent screenshots and downloads, gathered automatically.
- Both flank the Dock and follow it when it moves, resizes, or changes edge.

## Launching it

```bash
open ~/Applications/DockDeck.app
```

(The build installs there with `bash build.sh --install` — outside any iCloud-
synced folder, where a signed bundle stays valid.)

DockDeck has **no Dock icon** and does not appear in ⌘-Tab: the shelves are its
presence. A menu-bar icon (▤) is always there as a way back if you lose them.

On first launch it explains itself once, shows both shelves expanded, and does
not auto-hide for 20 seconds.

## Using it

| Action | How |
| --- | --- |
| Show / hide the shelves | `⌥⇧D`, or the menu-bar icon |
| Expand / collapse the shelves | `⌥⇧E` — open without dismissing, or close without hiding |
| Change either shortcut | Preferences → Shortcuts (click to record) |
| Expand a shelf | Hover over it, or start dragging anything |
| Add something | Drag it onto a shelf |
| Preview a file | Double-click it |
| Row actions | Right-click a row: Quick Look, Show in Finder, Rename, Compress, Share, Copy as Markdown, Pin, Remove |
| Command palette | `⌘⌥P` |
| Close an expanded shelf | `Esc` |

Dragging **anything, anywhere** expands both shelves immediately, and they stay
open for the whole drag. A collapsed shelf is only as thick as your Dock, which
is too small a target to aim a dragged file at.

## Dock behaviour

DockDeck measures the Dock and claims the space it leaves.

- **Bottom Dock** — shelves sit to its left and right.
- **Left or right Dock** — shelves sit below and above it.
- **Auto-hiding Dock** — the shelves hide with it and return when you reach the
  screen edge. Turn this off in Preferences.
- **Dock too long to leave room** — the shelf on that side is not shown at all,
  rather than drawn somewhere arbitrary.

### Measurement and the Accessibility permission

Placement is only as good as the Dock measurement behind it.

- **With Accessibility access** (recommended): DockDeck reads the Dock's real
  frame and tracks it live through magnification and item changes. Exact.
- **Without it**: DockDeck infers the Dock's size from `com.apple.dock`
  preferences. Thickness is accurate; length is an estimate, so the shelves can
  sit a little off.

Preferences shows which mode is active and offers the grant. The permission is
optional — nothing else in the app uses it, and the app works without it.

## Appearance

Three surface grades, chosen in Preferences → Appearance and applied live:

- **Liquid Glass** — macOS 26's `NSGlassEffectView`, the same dynamic material
  the system chrome itself is made of. The default where available.
- **Frosted Glass** — the classic `NSVisualEffectView` translucency; the same
  look on any macOS version and lighter to composite.
- **Opaque** — a solid surface that follows light and dark, for maximum
  contrast and minimum GPU.

## Storage and privacy

- Everything is stored in `~/Library/Application Support/DockDeck/`
  (`shelf.json`, `settings.json`, `projects.json`).
- The shelf holds **references**. Removing a row never deletes the file on disk.
- No network access, no telemetry, no analytics, no helper process, no
  third-party dependencies.
- Clipboard history is recorded only while that option is on, and never leaves
  the machine.

## Building

```bash
cd DockDeck
bash build.sh          # ad-hoc signed development build
open DockDeck.app
```

## Testing

```bash
bash test-model.sh     # headless: store, persistence, settings, geometry, springs
bash verify-app.sh     # runtime: launches the real .app and asserts on visibility
```

`verify-app.sh` runs the app with `DOCKDECK_DIAGNOSTICS=1`, which makes it report
its own window state — including `NSWindow.occlusionState`, the window server's
own answer to "is this actually on screen". A live process is not evidence the
app works; that was the original bug.

```bash
DOCKDECK_DIAGNOSTICS=1 DOCKDECK_DIAGNOSTICS_PATH=/tmp/report.json \
  ./DockDeck.app/Contents/MacOS/DockDeck
```

`DOCKDECK_SUPPORT_DIR` redirects storage, so tests never touch real data.

## Releasing

```bash
bash release.sh              # test, typecheck, build, verify, package
bash package.sh --format dmg # or zip (default)
```

Signing and notarization are separate and require real credentials:

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: NAME (TEAMID)" TEAM_ID=TEAMID ./sign.sh
NOTARY_PROFILE=dockdeck ./notarize.sh
```

See [RELEASE.md](RELEASE.md) for the current, honest release status.

## Known limitations

- **Apple Silicon only.** `build.sh` refuses to run on Intel.
- **Not notarized.** Development builds are ad-hoc signed and will not pass
  Gatekeeper on another Mac.
- **Liquid Glass grades to frosted below macOS 26** — `NSGlassEffectView`
  exists only there; on older systems the Liquid Glass option renders as
  frosted instead.
- **Glass rounds all four corners** — the effect view has no per-corner API, so
  unlike frosted/opaque, the screen-facing corners of a Liquid Glass shelf are
  rounded too.
- **Dock length is estimated without Accessibility access** (see above).
- **The Recents shelf is read-only** — it reflects the filesystem and does not
  persist its own items.
- **Only the primary Dock screen** carries shelves; they do not follow the
  pointer to other displays.
