# Changelog

## 1.0.0 — unreleased

First build of DockDeck that actually appears on screen.

### Added — build 20: the notch shelf has real content (Phase 2)

The open state stopped being an empty black slab. `NotchContentView` now hangs
from the silhouette when it opens: a glass sheet with search, kind tabs with
live counts (All / Files / Notes / Clips / Links), the newest eight items as
click-to-open rows with kind icons and relative ages, and a context menu per
row (Open, Reveal in Finder, Copy Path, Remove from Shelf). Opening notes and
bookmarks resolves their text as a URL; the sheet refreshes from the store at
every open, so content is never stale. Rows are frame-laid inside a flipped
container — the first attempt used a required width-equality against the
arranging stack and aborted in CoreAutoLayout (`mutuallyExclusiveConstraints`)
on every open; manual layout is deterministic and crash-free.

### Fixed — build 18: the notch silhouette rendered as a perfectly transparent window

The closed silhouette existed at the exact position (CGWindowList confirmed
it) but painted *nothing*: `NotchChromeView.apply` built the silhouette path
and fed it to the window's shadow — and never assigned `path` or `fillColor`
to the fill layer itself. The shelf was an invisible window at a perfect
position. The fill layer now receives the path, the fill, and its frame sized
to the content area (window minus the shadow strip), and `layout()` re-applies
the last known state so an init-time paint — which silently no-ops before the
view joins a window — is redone the moment the window is on screen.

### Fixed — build 17: a wedged Downloads folder could freeze the launch forever

The report was "se quitó del Dock" — the app had stopped tracking the Dock
again. The live stack told the real story: the launch was blocked inside
`open(Downloads, O_EVTONLY)` on the main thread, because the folder itself had
wedged at the VFS level (`readdir` hung from any process; `fileproviderd` at
63% CPU). Every launch since then froze before presenting anything — no
shelves, no notch, no status menu. Two hardenings, plus the discovery that
they also covered a second latent freeze:

- **`WorkspaceMonitor` never blocks the main thread.** The folder open runs
  on a background queue under a 2 s watchdog with an exactly-once hand-off
  box: on timeout the monitor reports unavailable and the app launches
  without Downloads watching; if the open completes late, the descriptor is
  adopted (the folder unwedged after launch).
- **Recents scans run on a dedicated serial queue.** A wedged `readdir`
  inside the enumeration would previously hang a fresh concurrent thread
  every timer tick; now it costs one hung thread, and when the wedge clears
  the trailing-run flag fires one fresh scan automatically.
- **The runtime suite now encodes the parked-state invariant.** With an
  auto-hiding Dock, a first-run shelf correctly sits *past the screen edge*
  (mirroring the parked Dock under the grace period), so "window server
  reports it on screen" was asserting the wrong thing; the parked resting
  layout is the assertion that matters. Suite: 19/19 — and it now passes
  *with Downloads still wedged*, which is the regression test for the freeze.

Separately, the recurring "grant revoked after every rebuild" bug was fixed
at the root: TCC keys Accessibility to the app's designated requirement, and
a plain ad-hoc signature's requirement is its own cdhash — new build, new
hash, silent revocation. `build.sh` now signs ad-hoc with the requirement
pinned to the bundle identifier (no keychain, no prompts), so the grant
survives every rebuild.

### Fixed — build 15: Preferences could not reach its own Dock placement section

The settings window was fixed at 460×470 with no scroll view — content pinned
top-only, so everything past ~470 pt (Sources, and the entire Dock placement
section with the Accessibility grant) was cut off below the window edge with
no way to reach it. The stack is now the document view of a scroll view pinned
to all four edges, and the window is resizable (min 460×320): tall content
scrolls, short content sits at the top.

### Added — build 14: Phase 1 of the notch mode + a second recents-scan runaway killed

The pivot the product needed: the notch anchor exists and runs. `NotchGeometry`
(pure, headless-tested) measures the real notch from `NSScreen` (`safeAreaInsets`,
`auxiliaryTopLeft/RightArea` — no hacks) and derives every rect: the closed
silhouette (physical notch + 4 pt click margin, never one pixel more of the menu
bar), the open 640 pt panel clamped inside the screen, the peek shape (Phase 2),
cone-curve silhouette radii (r5.5/r14 closed → r18/r22 open, the notch's physical
flare), and the morph fraction that drives them from one spring. `NotchPanel`
applies it per frame — window frame, silhouette path, and shadow opacity are
coupled properties of a single `SpringAnimator`, no second clock, no crossfades.
`NotchController` owns activation: 0.3 s hover-to-open, click, Esc, click-outside
close, courtesy close delay, and screen-change re-anchoring (lid closed → order
out). Wired at launch (skipped under `DOCKDECK_SUPPORT_DIR` diagnostics) plus a
status-menu toggle. Live-verified via CGWindowList: the silhouette sits at
layer 27, 228×62, top-center of the notched display — exactly the closed spec.
Model suite grew the `notchGeometry` block (radii caps, rect invariants, morph
ordering, path structure): **258 checks**.

The catch found during verification: CPU waves at ~30% with RSS churning — and
the sample named `SmartSectionResolver`, not the notch code. The build-11 fix
had left two hazards: the scan still *materialized every entry* of ~/Downloads
(≈2k URL+Date tuples, then sorted them) before any cap applied, and passes
**stacked** — the 20 s timer plus every Downloads change launched overlapping
scans on the concurrent utility queue. Fixed at both roots: the enumerator is
now consumed *bounded* (pulled at most `scanCap` entries, then stops), and
`refreshRecents` debounces (0.75 s), never runs two scans at once, and runs one
trailing pass if a request lands mid-scan — a burst of Downloads events now
costs exactly one scan. Verified live: sustained 0.0% idle CPU, stable ~106 MB
RSS, single-scan blips only.

### Fixed — build 12: an expanded shelf no longer covers the Dock's icons

The report that matters most: *"ya no puedo acceder a mis iconos"* — with a
side Dock, expanding a shelf laid its 320 pt sheet straight over the Dock's
icon column, and since the shelf lives at a window level above the Dock's,
it swallowed the icons' clicks too.

- **Root cause.** The in-gap expansion grew *from inside* the Dock's band:
  the collapsed shelf sits in the band (in the gap, where no icons live),
  and the expanded frame simply grew perpendicular from there. The sidecar
  placement and the transient path already anchored to the Dock's inner
  face — only the everyday in-gap case did not.
- **The fix.** Expansion is welded to the Dock's inner face in every
  orientation: above a bottom Dock, inboard of a side Dock — exactly where
  the shelf pops out in front, never on top of the icons. Verified live
  against the real Dock's measurements: expanded spans 3067–3387, the
  Dock's column (3387–3440) stays completely free.
- **A new invariant in the model suite** (`expandedNeverCoversDock`): for
  every orientation and every slot, the expanded frame covers none of the
  Dock's band, the collapsed frame never sits on the Dock's own frame, and
  the expanded sheet touches the band's inner face with no stray gap. Suite
  now 224 checks. Three older placement assertions were updated from the
  old semantics (grow inside the band, anchored to the screen edge) to the
  correct one.

### Changed — build 11: WS-2 + WS-1, the expansion morph and content inertia

Implements the "wow" pair from `DESIGN_THINKING.md` — the shelf grows as one
piece of glass, and its content has mass.

- **Frame one of an expansion is a full shelf.** The panel now tells its
  controller *before* the spring's first step (`beginExpansionFrom`); the
  expanded layout mounts and renders into the frame the shelf already has, so
  content grows with the glass instead of arriving after it. The old 80 ms
  delay + fade — the audit's "empty drawer" measurement (B3) — is gone, along
  with the generation-guarded fade machinery. Collapsing keeps its short
  fade: disappearing content may soften, appearing content may not.
- **The material stretches with the window (face growth).** During the
  outward growth, the chrome layer scales ~4.5% along the shelf's long axis,
  driven by the spring's own per-frame progress (no second clock), and eases
  back exactly when the last spring frame lands — the glass reads as one
  piece deforming, not a rectangle completing a tween.
- **The content inherits the surface's motion (WS-1).** The spring animator
  now publishes its per-step motion (`MotionSample`), and a pure, tested
  mapping (`ContentMotion`) turns it into one GPU transform per frame on the
  content host's *sublayer* — so it composes with, and never fights, the
  Dock-scale transform. Shear along the strip is signed and hard-clamped at
  ~2.5°, the depth axis squashes ≤ 5% only while pouring outward, and the
  content trails the window's displacement by exactly one third. Mass, not
  jelly — and structurally impossible to exceed the taste limits, because the
  model suite pins every boundary (12 new checks; suite now 200).
- **The glow has inertia (WS-7).** The specular bloom no longer teleports to
  the pointer: it approaches exponentially (τ = 70 ms, wall-clock based so
  event bursts and pauses advance it identically), snaps the last few points,
  and resumes from its last spot on re-enter. The perpetual float now runs
  two incommensurable periods (5.3 s × 7.1 s), so the composite drift never
  resolves into a loop the eye can learn.
- **Fixed a latent CPU runaway in the recents shelf** (found burning ~270%
  with RSS past 1.2 GB on a real machine during build 11's verification).
  `SmartSectionResolver` recursively walked *all* of ~/Downloads and called
  `standardizedFileURL` per file — which performs a reachability syscall per
  entry (`faccessat`, confirmed in a `sample` capture) — on a 20 s timer and
  on every Downloads change, stacking passes. It now scans top level only,
  prefetches resource values in the enumerator's single pass, caps any scan
  at 8k/20k entries, and materializes `ShelfItem`s only for the newest ones.
  Idle CPU is 0.0% again with stable memory.

### Fixed — build 10: WS-0, the coalesced reading pipeline

Implements WS-0 from `DESIGN_THINKING.md` — the fix that unlocks every other
motion workstream and kills the build 9 CPU runaway.

- **One evaluation per frame, never one per notification.** Every dirty mark
  (push sensor, screen/workspace/prefchange events, pointer, poll backstop)
  funnels into a single scheduled evaluation never closer than 33 ms apart.
  A hundred Dock notifications during magnification now cost one synchronous
  AX read, not a hundred — the main thread is sovereign again.
- **The decision is a pure, tested core.** `DockWatcher.fold(_:reading:...)
  replaces the `asyncAfter` confirmation cascade: a size-only reading becomes
  resting geometry when it *repeats* (the Dock stopped breathing, quorum of
  two coalesced readings) or the pointer is off the Dock, whichever comes
  first. At most one `onChange` per evaluation — the double-report that caused
  first-frame micro-jerk is structurally impossible now.
- **Re-entrancy guarded.** An event landing mid-evaluation schedules the next
  tick instead of recursing; a mid-evaluation read can never re-enter.
- **Idle CPU is 0.0%** (was: runaway to full core). 188/188 model checks
  (11 new on the promotion core), 20/20 runtime, installed and verified as
  build 10.

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
