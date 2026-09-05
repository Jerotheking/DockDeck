# DockDeck — Notch competitors: implementation deep-dive

**Date:** 2026-09-04 · **Method:** actual source code (both OSS competitors cloned and read line-by-line), official docs, one independent measured comparison. Companion to `NOTCH_COMPETITIVE_ANALYSIS.md` (product-level) — this document is *how they actually work*, at the level we can steal from.

Sources `[VERIFICADO]`: `boring.notch` (MIT, commit read 2026-09-04), `NotchDrop` (MIT, same), Jero's own machine measurements. `NotchNook` is closed-source: behavior-level only `[INFERIDO]`.

---

## 1. Window setup — the exact recipes

| Property | boring.notch | NotchDrop | DockDeck verdict |
|---|---|---|---|
| Class | `NSPanel`, `isFloatingPanel` | `NSWindow` | NSPanel (ours already is) |
| `canBecomeKey` | **false** | **true** | **true** — we need search typing (NotchDrop's choice is the correct one for a shelf) |
| `level` | `.mainMenu + 3` | `.statusBar + 8` ("kills ibar lol") | `.mainMenu + 3` baseline; full level only while a drag is over us |
| `hasShadow` | **false** (optional re-added) | false | false — the notch silhouette must not cast a shadow onto the menu bar; open state draws its own |
| Opaque/background | false / `.clear` | false / clear | same |
| Collection behavior | `.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle` | identical | identical (we already match) |
| `isMovable` | false | false | false |

Both apps: **non-opaque, clear-background, borderless-feeling window pinned top-center, excluded from Mission Control cycling.** The closed notch is *painted* (SwiftUI shape), not a system chrome — the window is invisible except where the silhouette is drawn.

## 2. Notch geometry — the math both implement

From `boring.notch/sizing/matters.swift` and `NotchDrop/Ext+NSScreen.swift` `[VERIFICADO]`:

```swift
notchWidth  = screen.frame.width - auxTopLeftArea.width - auxTopRightArea.width  (+4 click margin)
notchHeight = screen.safeAreaInsets.top            // or menu-bar height, or custom
```

- boring adds **+4 pt of width** so the closed silhouette swallows clicks aimed at the physical notch; NotchDrop uses an **inset −4** window expansion. Same trick, opposite sign — the window must be slightly *bigger* than the notch or clicks on its edges fall through to the menu bar.
- boring's three height modes: `matchRealNotchSize` (safeAreaInsets), `matchMenuBar` (frame.maxY − visibleFrame.maxY), custom. Defaults 32 pt for non-notch displays (so the feature works on external displays too — but see §7).
- **Jero's machine, measured live `[VERIFICADO]`:** built-in display 1800×1169, `safeAreaInsets.top = 38`, aux areas 790+790 → **notch = 220 × 38 pt**, menu bar = 38 pt, `visibleFrame.maxY` sits 38 pt down. These are the calibration numbers for our silhouette.
- boring's open size: **640 × 190 pt** content (window = content + **20 pt of shadow padding below**, content pinned to the window top). NotchDrop: **600 × 160**. A *shelf* needs more height than a music player: our open depth should be ~380–460 pt (configurable), same 640-ish width.

## 3. The closed silhouette — one shape, animatable

`NotchShape.swift` (originally from DynamicNotchKit) `[VERIFICADO]`: the closed/open silhouettes are **one SwiftUI `Shape`** whose path is:

- straight across the top edge,
- **quadratic "cone" curves** at the four bottom corners: top radius 6, bottom radius 14 when closed — the little trumpet-flare where the physical notch meets the screen,
- `animatableData = AnimatablePair<top, bottom>` — the *same shape* morphs when the corner radii change, which is how the notch appears to "grow" smoothly instead of swapping rectangles.

This is the cheap-SwiftUI version of our "one piece of glass" principle. Our implementation should reproduce the silhouette as a **CALayer path with corner radii we animate** (we already animate layer properties per-frame for WS-1/WS-2).

## 4. State machines

**boring.notch** (`BoringViewModel`) `[VERIFICADO]`:
- `notchState: closed | open`; size-driven: `open()` sets `notchSize = openNotchSize`, `close()` resets to `getClosedNotchSize()` — SwiftUI animates the frame change with a shared spring (`animationLibrary.animation`).
- **Sneak peeks**: separate tiny sizes (`downloadSneakSize 65×1`, `batterySneakSize 160×1` heights vs the notch) — event-driven expansions that show *one line* (download progress, battery) then close. Gated by `enableSneakPeek` + `waitInterval` (default 3 s).
- `hideOnClosed`: when the frontmost app is fullscreen **on the notch's screen** (a per-screen `FullscreenMediaDetector`), closed height → **0** — the notch disappears entirely instead of floating over video.
- **Chin**: when the menu bar is *shorter* than the notch height, they extend a cosmetic black "chin" (`menuBarHeight - notchHeight`) so the silhouette still reads as the notch.
- Close is **refused while a share sheet is active** (`SharingStateManager.preventNotchClose`) — never close under an active drag interaction.

**NotchDrop** (`NotchViewModel`) `[VERIFICADO]`:
- `status: closed | opened | popping` + **`openReason: click | drag | boot | unknown`** — the reason is first-class state, so the open animation and auto-close policy can differ per trigger.
- `popping` = brief event expansion (their version of sneak peeks).
- `NSApp.activate(ignoringOtherApps: true)` on open — they *take* key focus deliberately (they're a share sheet).
- Global `EventMonitors`: mouseMoved / leftMouseDown / leftMouseDragged / flagsChanged (Option key) — all feeding Combine subjects. Drag detection = mouse-dragged with a pasteboard file present (their "dragging a file" signal), `dropDetectorRange = 32 pt`.

## 5. Activation grammar (union of both + settings)

| Trigger | Implementation | Default |
|---|---|---|
| Hover | geometric hit-test on the closed rect + **0.3 s minimum hover duration** (`minimumHoverDuration`, configurable; `openNotchOnHover` on/off; `extendHoverArea` enlarges the hit rect) | on |
| Click | mouseDown inside silhouette (global monitor) | on |
| **Drag near/over** | system-wide leftMouseDragged + pasteboard-has-files; 32 pt corridor around the notch opens it **before** the file arrives (drop on a closed notch works) | on, not optional |
| Boot | first-run welcome (`openReason = .boot`) | once |
| Close | click outside (their monitors), **drag-down gesture** (`enableGestures`, `gestureSensitivity = 200` px, `closeGestureEnabled`), Esc | — |

## 6. Content architecture

- **Everything is SwiftUI** in both apps. boring: a `BoringViewCoordinator` with `currentView` (home/shelf/calendar/settings), and on close it *remembers* which view you were in (`openLastTabByDefault`, `openShelfByDefault` — if the shelf has items, reopen into it).
- **NotchDrop's tray** (`TrayDrop`) `[VERIFICADO]`: items in a `@PublishedPersist`ed `OrderedSet<DropItem>` (newest first via `updateOrInsert(_, at: 0)`); **expiry configurable by unit** (hours/days/weeks/months/years, default 24 h — `keepInterval`) with `cleanExpiredFiles()`; files are *staged references*, loaded off-main-thread from `NSItemProvider`s; per-item actions: click to open, ⌥+x to delete, AirDrop/share.
- boring's shelf is built **on NotchDrop's code** (acknowledged in their README) — same expiry-first model. **Nobody stages permanently. That remains the hole we fill.**

## 7. Multi-display & fullscreen

- boring settings: `showOnAllDisplays` (default **false**), `automaticallySwitchDisplay` (follow the mouse), `showOnLockScreen`, `hideFromScreenRecording`. `getClosedNotchSize(screenUUID:)` is fully per-screen — non-notch displays get a fake 32 pt "notch" height.
- Fullscreen: boring hides (height→0, per-screen detector + `hideNotchOption: never/fullscreen/always`). Their not-yet-shipped answer for floating over fullscreen is a private `CGSSpace(level: Int32.max)` (`NotchSpaceManager`) — that's the trick, it costs an EventTap and private API. NotchDrop simply lives at `.statusBar+8` and floats above everything, fullscreen included.
- **DockDeck decision:** hide-on-fullscreen as the default (boring's pattern; honest about the menu bar not existing), no private CGSSpace in v1.

## 8. Motion & feel

- NotchDrop: `.interactiveSpring(duration: 0.5, extraBounce: 0.25)` — noticeably bouncy; **haptic feedback on open/close/stage** (`hapticFeedback` default true).
- boring: central `BoringAnimations` library; `cornerRadiusScaling` (radii grow as the notch opens — part of the "one material" read); `lightingEffect` (their glow); `enableHaptics` default true; drag-down-to-close with adjustable sensitivity.
- The genre-wide feel: **fast open (~250–350 ms), springy but not wild; close is quicker and less bouncy; event pops are quick fades/scales.**

## 9. Settings catalog worth matching (grep of `Constants.swift` `[VERIFICADO]`)

Hover (delay/extend/on-off) · haptics · gestures + sensitivity · sneak peeks + wait interval · corner radius scaling · lighting effect · shadow · show calendar · open-last-tab/open-shelf-by-default · per-display (show on all / auto-switch) · lock screen · hide from screen recording · notch height mode (real/menubar/custom).

## 10. Their weaknesses (from the code, not the reviews)

1. **Expiry-model shelves** — both stage files *temporarily*; nothing organizes, pins, searches, or persists meaningfully. (`[VERIFICADO]` in `TrayDrop`.)
2. **Music dependence** — boring's core is Now Playing via `MediaRemoteAdapter` (a private-API shim that breaks on macOS updates; they ship an XPC helper with privileged install to work around system limits). Fragile by construction.
3. **canBecomeKey = false** (boring) means no text input in the notch — their search/settings live in separate windows. A shelf needs inline search; NotchDrop's `canBecomeKey = true` is the right call.
4. **No material system** — painted black shapes, no glass, no motion continuity engine (ours: `ShelfMotion` + `GlassInteractor`, already built and tested).
5. **Zero Dock story** — notch apps on a MacBook + external display abandon the external display entirely; Dock apps (us, Dockside) abandon the MacBook. Nobody bridges.
