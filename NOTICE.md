# Third-party notices

DockDeck has **no third-party dependencies**. It links only against frameworks
shipped with macOS:

| Framework | Use |
| --- | --- |
| AppKit | Windows, views, drag and drop, menu bar |
| Foundation | Storage, JSON, filesystem |
| QuartzCore | Spring animation, layer effects |
| QuickLookUI | File previews |
| Carbon (HIToolbox) | The `⌥⇧D` global hotkey, via `RegisterEventHotKey` |
| ApplicationServices | Accessibility, to measure the Dock |

No package manager, no vendored source, no bundled binaries.

## Attribution

DockDeck's placement model — shelves that flank the Dock inside its own strip,
expanding on drag — was informed by [Dockside](https://github.com/PrajwalSD/Dockside)
by Prajwal S D / Hachipoo Apps, a separate commercial product.

Dockside publishes **no source code**; its repository contains only a README,
localization strings, release notes, and binaries. No Dockside code was copied,
decompiled, or reverse-engineered, and no Dockside text, icon, or asset is
included here. The influence is on behaviour and product shape only, from
publicly published documentation.

Dockside is not affiliated with, and does not endorse, DockDeck.
