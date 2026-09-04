#!/usr/bin/env python3
"""Assertions over a DockDeck diagnostics report.

Kept out of verify-app.sh because these checks are about geometry — is the shelf
touching the Dock, is it as thick as the Dock, does a hidden shelf still leave a
sliver on screen — and expressing that in shell quoting was where the bugs were.

Exit code is the number of failures, capped at 125.
"""
import json
import re
import sys


def rect(value):
    """Parse an NSStringFromRect string: {{x, y}, {w, h}}."""
    numbers = [float(n) for n in re.findall(r"-?\d+(?:\.\d+)?", value)]
    if len(numbers) != 4:
        raise ValueError(f"not a rect: {value!r}")
    return numbers  # x, y, w, h


class Checker:
    def __init__(self):
        self.passed = 0
        self.failed = 0

    def check(self, ok, description):
        if ok:
            print(f"  ok    {description}")
            self.passed += 1
        else:
            print(f"  FAIL  {description}")
            self.failed += 1


def main(path):
    with open(path) as handle:
        report = json.load(handle)

    c = Checker()
    dock = report["dock"]
    shelves = report["shelves"]
    thickness = float(dock["thickness"])
    dx, dy, dw, dh = rect(dock["frame"])
    screens = [rect(s) for s in report["screens"]]

    c.check(report.get("delegateAttached") is True, "delegate is attached")
    c.check(report.get("shelfCount") == 2, f"two shelves were built (got {report.get('shelfCount')})")
    status = report.get("statusItem", {})
    c.check(status.get("present") is True, "status item is present")
    c.check(status.get("visible") is True, "status item is visible")
    c.check(status.get("hasImage") is True, "status item has an icon")
    version = report.get("version")
    c.check(version and version != "unknown", f"reports a real version ({version})")
    c.check(dock["source"] in ("accessibility", "estimated"), f"dock measured via {dock['source']}")

    # A failed hotkey registration is invisible to window-level checks; the
    # ⌥⇧E failure shipped exactly that way.
    hotkeys = report.get("hotkeys", {})
    c.check(hotkeys.get("showHideRegistered") is True, "show/hide hotkey is registered")
    c.check(hotkeys.get("expandCollapseRegistered") is True, "expand/collapse hotkey is registered")

    first_run = report.get("isFirstRun") is True
    mirrors = dock.get("autohides") is True
    # An auto-hiding Dock means a returning launch starts hidden: that is the
    # mirroring feature. A first launch starting hidden is indistinguishable
    # from the app not working, and is never acceptable.
    expect_visible = first_run or not mirrors

    print(f"        dock={dock['orientation']}/"
          f"{'autohide' if mirrors else 'pinned'} source={dock['source']} "
          f"thickness={thickness:g} frame={dock['frame']} firstRun={first_run}")

    for slot in ("leading", "trailing"):
        shelf = shelves.get(slot)
        if shelf is None:
            c.check(False, f"{slot}: shelf exists")
            continue
        state = shelf["state"]
        c.check(shelf["layoutViable"] is True, f"{slot}: layout is viable")
        c.check(shelf["isVisible"] is True, f"{slot}: window is visible")
        c.check(shelf["occlusionVisible"] is True, f"{slot}: window server reports it on screen")

        cx, cy, cw, ch = rect(shelf["collapsedFrame"])
        fx, fy, fw, fh = rect(shelf["frame"])

        # The premise of the app: the collapsed shelf is as thick as the Dock,
        # so it reads as part of it rather than as a window parked nearby.
        thick_ok = abs(cw - thickness) < 1 or abs(ch - thickness) < 1
        c.check(thick_ok, f"{slot}: collapsed shelf is as thick as the Dock ({cw:g}x{ch:g} vs {thickness:g})")

        adjacency = abs(float(shelf["adjacentToDock"]))
        c.check(adjacency < 2, f"{slot}: adjacent to the Dock (gap {adjacency:g} pt)")

        if expect_visible:
            c.check(shelf["usableFrame"] is True, f"{slot}: frame is usable")
            c.check(state != "hidden", f"{slot}: first launch is not auto-hidden (state {state})")
            # Two legitimate resting frames: the full collapsed layout, or —
            # while the Dock is magnified under the pointer — the compressed
            # strip frame that keeps the shelf clear of the Dock. Anything else
            # is a real defect.
            c.check(shelf["collapsedFrame"] == shelf["frame"] or shelf["compressedFrame"] == shelf["frame"],
                    f"{slot}: frame is the resting layout or the compressed strip frame")
        else:
            c.check(state == "hidden", f"{slot}: mirrors the auto-hiding Dock (state {state})")
            # Even hidden, part of it must remain on a screen so it can be found.
            on_screen = any(
                max(sx, fx) < min(sx + sw, fx + fw) and max(sy, fy) < min(sy + sh, fy + fh)
                for sx, sy, sw, sh in screens
            )
            c.check(on_screen, f"{slot}: hidden shelf keeps a sliver on screen")

        print(f"        {slot:<8} state={state:<9} frame={shelf['frame']}")

    print(f"        report: {c.passed} passed, {c.failed} failed")
    return min(c.failed, 125)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: check-report.py <report.json>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
