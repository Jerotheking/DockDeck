# Changelog

## 1.0.0 — unreleased

First build of DockDeck that actually appears on screen.

### Changed — build 9: snappy tracking + much richer motion

- **Size tracking is genuinely snappy.** The watcher's pointer throttle is
  gone (0.25 s → 0): magnification is now tracked at hardware event rate, so
  the shelf follows the Dock's own animation instead of sampling it. The
  transient confirmation delay dropped from 0.35 s to 0.15 s, so the resting
  state (and its rebuilt tiles) settles within one beat of the Dock's own
  animation. `retarget(to:)` on the spring animator keeps position and
  velocity through the whole cascade — the compression reads as one gesture,
  not a chain of animations.
- **Magnification no longer masquerades as a resize.** A size-only Dock
  reading taken while the pointer is *not* on the Dock cannot be
  magnification (the Dock only magnifies under the pointer), so it is
  promoted to resting geometry immediately — divider drags land in one
  reading instead of after a confirm window. Under the pointer it stays
  transient, exactly as before.
- **New `.track` spring preset** (0.13 s response, 0.95 damping): visually
  caught up with the Dock in under a tenth of a second, no visible overshoot
  — attached, not chasing. Expansion is now the bounciest gesture (0.42 /
  0.68); reveal quickened to 0.30 / 0.78; collapses 0.24 / 0.85; structural
  relocations use the new decisive `.slide` (0.45 / 0.90).
- **The glass is now alive.** New `GlassInteractor`: a specular glow gathers
  in the shelf's glass under the pointer and follows it (biased toward the
  Dock-facing edge, with a slow pulse so even a resting pointer reads as
  awake), plus a perpetual 1.5 pt floating drift on the surface. All of it is
  compositor-side; it fades in when the pointer arrives and dissolves on
  exit; it is suppressed under Reduce Motion and on pre-macOS-26.
- **Rows dispense outward.** Expanded shelf rows now arrive with a staggered
  spring entrance (45 ms apart, capped at 8 rows) — travelling in from the
  Dock-facing edge with a slight scale-up and fade, so the shelf reads as
  pouring its contents out rather than fading as one block. Also runs on
  every re-render (tab switch, search) since `renderRows` drives it.
- Press/pop physics (`setPressed` / `releasePressed`) join the shared motion
  vocabulary for tiles and rows.

### Added — push-based Dock tracking (the Dock itself reports changes)

- New `DockSensor`: an `AXObserver` attached to the **Dock process's own
  accessibility tree**, receiving push notifications the moment the Dock's
  window or item list changes — position, orientation, auto-hide reveal,
  magnification, divider drags, tile additions. This is the mechanism
  Dockside-class apps use; it replaces inference-from-unrelated-events as the
  primary tracking layer. It self-heals (re-attaches after a Dock relaunch or
  element destruction, and the moment the Accessibility grant appears).
- The screen/workspace/prefchange event net and the pointer throttle remain
  as secondary layers, and the slow poll remains as backstop + sensor health
  check — three layers, fastest first, nothing relies on a single signal.
- Runtime diagnostics now report `dockSensorAttached`, and the verifier can
  assert the push path is live.
- **Live acceptance test passed**: with the real Dock flipped
  right → bottom → left → right via `defaults` + `killall Dock`, the shelves
  followed every flip (correct edge, correct screen, correct thickness) and
  landed back on the exact baseline frames.

### Changed — repositioning after a Dock move

- When the Dock's change *relocates* a shelf (other edge, or far along the
  strip — over 120 pt), the shelf now travels with the quick spring instead
  of the slow liquid reveal: it gets out of the way decisively. Growth in
  place keeps the liquid character.
- A launch banner now logs the exact build number and binary mtime, so a
  stale installed build can never be mistaken for the new one.


### Fixed — the shelf now pops out above the Dock

- The shelf windows sat at `.floating` (level 3), far below the Dock's own
  level (20): the Dock always drew over them, which is why an expansion never
  read as *leaving* the Dock. They now sit at `.mainMenu` (24) — above the
  Dock, below menu-bar extras — so an expanded shelf is visibly in front.

### Changed — the content breathes with the Dock

- During magnification the shelves no longer only compress their window:
  their whole content now **scales with the Dock through a transform** (one
  GPU matrix per reading — no tile rebuilds, no flicker), anchored to the face
  that touches the Dock so the icons stay welded to its edge exactly the way
  the Dock's own icons grow. When a reading confirms, the transform eases back
  to identity with a spring while the rebuilt tiles take over at the new
  resting thickness.
- An **expanded** shelf no longer snaps shut when the Dock magnifies
  underneath it: its inner face re-welds to the strip's new face, the visible
  depth and the length (and with them the scroll position) are preserved, and
  it only steps aside when the Dock leaves no depth at all.
- A **hidden** (auto-hide-mirrored) shelf stays hidden — a transient reading
  no longer pops it back into view.


### Changed — the shelves follow the magnifying Dock instead of being overlapped

- **Continuous tracking, no freezing.** Every differing Dock reading is now
  applied. The watcher classifies each one: a *size-only* change — the Dock
  magnifying under the pointer, or its unwind afterwards — arrives flagged as
  transient, and the shelves **compress into the gap the Dock leaves right
  now**, hugging its current edge. The Dock can grow, but it never grows over
  the shelves; if it fills the whole strip they step aside for that moment and
  return when it settles. A size-only reading confirmed twice becomes the new
  resting geometry with a full re-placement. Structural changes (edge, screen,
  auto-hide, tile size) remain immediate.
- Pointer-driven re-measurement is throttled to 4 Hz, and mouse-drag/up events
  joined the net so a magnification session is followed in real time.
- Diagnostics now report the compressed strip frame alongside the collapsed
  layout, and the runtime verifier accepts either as a valid resting frame.

### Changed — liquid expansion motion

- The expansion spring is bouncier and slightly slower (response 0.50,
  damping 0.78), so the panel **overshoots outward past its resting depth and
  settles back** — the shelf reads as pouring out of the Dock like liquid
  finding its level, not a rectangle completing a tween. Reveal (0.40/0.80)
  and collapse (0.30/0.92) follow the same character.
- The surface moves first and its contents fade in a beat later (80 ms), with
  a generation counter so a collapse that interrupts an expansion never leaves
  a stranded fade — content settles as the spring is still finishing, which is
  what sells the pop.

### Added — appearance and hotkeys

- **Liquid Glass surface.** On macOS 26 and later the shelves render on
  `NSGlassEffectView`, the same dynamic material the system chrome is made of.
  Three grades in Preferences — **Liquid Glass**, **Frosted**
  (`NSVisualEffectView`, the classic translucency, available on every macOS),
  and **Opaque** — swapped live without relaunching, and persisted.
- **Two separate, configurable global shortcuts.** Show/hide (`⌥⇧D`) and
  expand/collapse (`⌥⇧E`) are distinct intents and distinct bindings, editable
  with a click-to-record control in Preferences. A binding already used by the
  other action is rejected, and modifier-less combinations are refused because
  a global shortcut without modifiers would swallow a bare keystroke in every
  other app.
- **Settings survive upgrades.** Settings decode key-by-key with per-key
  fallbacks: a file written by an older version keeps every preference it
  carried instead of being reset wholesale by the first unrecognised key.

### Added — first-run onboarding

- **A real onboarding panel replaces the plain welcome alert.** It teaches the
  three gestures that make the shelves findable and offers the Accessibility
  grant with a live status: the moment the grant is given in System Settings,
  the panel flips to “granted”, re-measures the Dock, and the shelves visibly
  snap to their exact position. Finishing — by button, by closing, or by
  granting — hands control back exactly once.

### Polish

- Row action buttons use SF Symbols (`pin.fill`, `doc.on.doc`, `xmark`) instead
  of Unicode glyphs, so they match system weight and rendering at any scale.
- The expanded header is stronger: 13 pt title at full label colour, a bordered
  `+`-prefixed New Note button, and a borderless `⌘` icon for the palette.

### Fixed

- **The expand/collapse shortcut was silently dead in production**
  (`⌥⇧E`, OSStatus -9866). Each hotkey installed its own Carbon event handler,
  and Carbon refuses a second handler for the same event on the same target —
  so only the first hotkey ever worked. The dispatcher is now installed once
  per process and dispatches per key. The runtime verifier now asserts both
  registrations from inside the process, which is how this stayed invisible
  until a user log exposed it.
- **"Get Started" did nothing.** The onboarding completion nilled the only
  strong reference to the controller *inside the controller's own action*,
  deallocating it mid-call — the window never closed. The reference is now
  held by the delegate and dropped at cleanup, and the panel is centred on
  screen instead of appearing at the bottom-left.
- **"Unusable frame" log spam while hidden.** A hidden shelf's frame is a
  deliberate 4-pt sliver past the screen edge; the usability guard rejected it
  and logged an error on every Dock re-read. Hidden shelves are no longer
  guarded as if they were trying to be visible.
- **Shelves chased the Dock's magnification as it unwound.** Each intermediate
  frame of the ~1 s unwind was accepted as a real change, so the shelves
  visibly thrashed after the pointer left the Dock. Size-only readings are now
  confirmed twice before acceptance; structural changes (edge, screen,
  auto-hide, tile size) stay immediate.
- **Show/hide never hid.** The hotkey only *collapsed* the shelves — which
  still occupy their gap beside the Dock — so they could not actually be sent
  off screen. Hiding and collapsing are different states; the hotkey now
  answers for presence and the expand/collapse one for openness.
- **`ThumbnailProvider.swift` was never compiled.** The build script's fixed
  source list predated the file, so a full build failed outright; the typecheck
  command compiles the whole directory and masked it.
- **A first run with no viable shelf space** presented nothing and said
  nothing; `present()` now reports viability so the caller can react instead of
  silently doing nothing.

### Fixed — launch was completely broken

- **The app delegate was never connected.** `AppDelegate` was marked `@main`,
  which synthesises a call to `NSApplicationMain()`. That relies on the main nib
  (`NSMainNibFile`) to instantiate and wire the delegate, and this bundle ships
  no nib and declares no `NSPrincipalClass`. `NSApp.delegate` stayed `nil` for
  the entire process lifetime, so `applicationDidFinishLaunching` never ran:
  no window, no menu-bar item, and no storage directory were ever created. The
  process stayed alive, which is why it looked installed and working.
  Replaced with an explicit `main.swift` that assigns the delegate before
  `NSApplication.run()`.
- **An NSException aborted the rest of launch.** The empty-state view activated
  a constraint between itself and `stackView` before being added to the view
  hierarchy — `no common ancestor`. AppKit swallows exceptions thrown inside a
  delegate callback, so the remaining setup was silently skipped with no crash
  and no log. Views are now added to the hierarchy before any constraint
  referencing an ancestor is activated. This bug was hidden behind the first one.
- **The collapsed shelf was 193 pt wide instead of the Dock's 53 pt.** The
  expanded layout stayed mounted while hidden, and a hidden subtree still
  contributes its constraints; AppKit sizes a window to its content view's
  fitting size. The expanded layout is now mounted only while expanded.

### Changed — the shelf now lives beside the Dock

- Rewrote placement: shelves claim the leftover space in the Dock's own strip
  instead of the opposite screen edge. A right-hand Dock used to push the shelf
  to the *left* of the screen — the opposite of the intent.
- Two shelves, flanking the Dock: **library** (files, notes, clipboard, links)
  and **recents** (screenshots, downloads).
- New `DockGeometry`: measures the Dock's real frame through the Accessibility
  API, falling back to an estimate from `com.apple.dock` preferences. Reports
  which source it used instead of pretending both are equal.
- New `DockWatcher`: follows the Dock across moves, resizes, edge changes,
  app launches and quits, and display reconfiguration.
- **Expand to reveal**: shelves rest at the Dock's thickness and expand on hover.
- **Drag activation**: any drag anywhere on the system expands both shelves
  immediately and holds them open, so the drop target is never Dock-thin.
- Mirrors an auto-hiding Dock, with a launch grace period so the shelves cannot
  vanish before they have been seen.

### Added

- Frosted-glass surface (`NSVisualEffectView`, `.sidebar`), with corners rounded
  only on the sides facing into the screen, and a hairline edge that adapts to
  light and dark.
- Spring-based motion with velocity-preserving retargeting, honouring the
  system's Reduce Motion setting.
- Menu-bar item created *before* anything that can fail, with Show/Hide,
  New Note, Preferences, About, and Quit.
- Preferences window: shelf toggles, expand-on-hover, Dock auto-hide mirroring,
  expanded size, content sources, and the Accessibility grant with live status.
- First-run guidance explaining where the shelves are and how to reach them.
- Diagnostics mode (`DOCKDECK_DIAGNOSTICS=1`) reporting window state, Dock
  measurement, and shelf adjacency; start-up phase traces.
- App icon, generated reproducibly from source (`tools/make-icon.sh`).
- Version metadata, release/sign/notarize/package scripts, SHA-256 checksums,
  and a release manifest.

### Fixed — correctness and safety

- Removing a row never deletes the file on disk; covered by a test.
- Rename validation rejects empty names, path separators, `.`/`..`, names that
  escape the folder, and existing destinations — with the reason shown.
- Compression refuses a missing source or an existing archive instead of failing
  silently.
- Failures are reported to the user; they used to be swallowed.
- Timers, event monitors, hotkeys, filesystem watchers, and the status item are
  all released on quit; shutdown is idempotent.
- Pending saves are flushed rather than cancelled on quit.
- The clipboard poll runs only while the feature is on. The old build ran a
  0.12 s timer for the app's entire lifetime regardless.
- The 15-second refresh no longer rebuilds every row unconditionally.
- Filesystem enumeration for the recents shelf moved off the main thread.
- A borderless panel now accepts key status, so the search field can be typed in.
- The hotkey reports registration failure instead of failing silently.
- URL schemes are re-validated on open, not only on drop.

### Changed — product

- Renamed from DockShelf to DockDeck; bundle identifier `com.sintelia.dockdeck`.
  No data migration was needed: the broken build never wrote anything.
- UI unified to English; it had been a mix of Italian and English.
