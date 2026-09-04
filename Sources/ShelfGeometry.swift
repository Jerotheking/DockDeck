import CoreGraphics
import Foundation

/// Placement math for shelves that flank the Dock.
///
/// The model, taken from Dockside: the Dock owns a strip along one screen edge
/// and sits centred in it, leaving a gap at each end. A shelf claims one of
/// those gaps, so it reads as an extension of the Dock rather than a separate
/// window somewhere else on screen.
///
/// Two states:
/// - **collapsed** — exactly the leftover gap, at the Dock's own thickness.
/// - **expanded** — grows *perpendicular*, into the screen, and lengthens along
///   the strip only when the gap is too short to be useful. It never leaves the
///   screen and never needs the Dock to move.
///
/// Every input is a value, so all of this is exercised headlessly by
/// `ModelSelfTest` with no window server and no real Dock.
enum ShelfGeometry {
    /// Which end of the Dock's strip a shelf occupies. For a bottom Dock,
    /// `leading` is to its left and `trailing` to its right; for a side Dock,
    /// `leading` is below it and `trailing` above.
    enum Slot: String, CaseIterable, Codable { case leading, trailing }

    /// Depth a shelf grows to when expanded, measured into the screen from the
    /// Dock's edge. Wide enough for a filename plus its icon and row actions.
    static let defaultDepth: CGFloat = 320
    static let minimumDepth: CGFloat = 220
    static let maximumDepth: CGFloat = 520
    /// Below this, a collapsed gap cannot show even one row, so expansion also
    /// lengthens along the strip.
    static let minimumUsefulLength: CGFloat = 360
    /// A gap narrower than this is not worth claiming at all.
    static let minimumViableLength: CGFloat = 48

    /// How a shelf ended up where it is.
    enum Mode: String, Equatable {
        /// Ideal: inside the Dock's own strip, in the gap the Dock leaves.
        case inGap
        /// Fallback: the Dock fills its strip, so the shelf sits immediately
        /// inboard of it — still touching the Dock, just one lane over.
        case sidecar
    }

    struct Layout: Equatable {
        var collapsed: CGRect
        var expanded: CGRect
        var slot: Slot
        var mode: Mode
        /// Only false when even the sidecar cannot be placed — a screen too
        /// small to hold the Dock and a shelf at once. Disappearing is a last
        /// resort, never the first answer to a crowded Dock.
        var isViable: Bool
    }

    static func layout(slot: Slot, dock: DockGeometry, depth requestedDepth: CGFloat = defaultDepth) -> Layout {
        let gaps = dock.gaps
        let gap = slot == .leading ? gaps.leading : gaps.trailing
        let strip = dock.dockStrip
        let screen = dock.screen
        let depth = requestedDepth.isFinite ? min(max(requestedDepth, minimumDepth), maximumDepth) : defaultDepth

        let gapLength = dock.orientation == .bottom ? gap.width : gap.height
        if gapLength >= minimumViableLength, gap.width > 0, gap.height > 0 {
            let collapsed = clamp(gap, to: screen)
            let expanded = expand(from: collapsed, slot: slot, dock: dock, strip: strip, screen: screen, depth: depth)
            return Layout(collapsed: collapsed, expanded: clamp(expanded, to: screen),
                          slot: slot, mode: .inGap, isViable: true)
        }

        // The Dock fills its own strip — a large tile size, or simply a lot of
        // apps. Vanishing would be the worst possible answer to a crowded Dock,
        // so fall back to the lane immediately inboard of it.
        return sidecarLayout(slot: slot, dock: dock, screen: screen, depth: depth)
    }

    /// Placement used when the Dock leaves no gap: a lane of the Dock's own
    /// thickness, pressed against the Dock's inboard edge, anchored to the end
    /// of the screen this slot belongs to.
    private static func sidecarLayout(slot: Slot, dock: DockGeometry, screen: CGRect, depth: CGFloat) -> Layout {
        let thickness = min(dock.thickness, dock.orientation == .bottom ? screen.height / 3 : screen.width / 3)
        let length = min(max(minimumUsefulLength, thickness * 4),
                         dock.orientation == .bottom ? screen.width / 2 : screen.height / 2)
        guard thickness >= minimumViableLength / 2, length >= minimumViableLength else {
            return Layout(collapsed: .zero, expanded: .zero, slot: slot, mode: .sidecar, isViable: false)
        }

        var collapsed: CGRect
        switch dock.orientation {
        case .right:
            let x = dock.dockStrip.minX - thickness
            let y = slot == .leading ? screen.minY : screen.maxY - length
            collapsed = CGRect(x: x, y: y, width: thickness, height: length)
        case .left:
            let x = dock.dockStrip.maxX
            let y = slot == .leading ? screen.minY : screen.maxY - length
            collapsed = CGRect(x: x, y: y, width: thickness, height: length)
        case .bottom:
            let y = dock.dockStrip.maxY
            let x = slot == .leading ? screen.minX : screen.maxX - length
            collapsed = CGRect(x: x, y: y, width: length, height: thickness)
        }
        collapsed = clamp(collapsed, to: screen)

        var expanded = collapsed
        switch dock.orientation {
        case .right, .left:
            expanded.size.width = min(depth, screen.width)
            expanded.origin.x = dock.orientation == .right
                ? dock.dockStrip.minX - expanded.width
                : dock.dockStrip.maxX
        case .bottom:
            expanded.size.height = min(depth, screen.height)
            expanded.origin.y = dock.dockStrip.maxY
        }
        return Layout(collapsed: collapsed, expanded: clamp(expanded, to: screen),
                      slot: slot, mode: .sidecar, isViable: true)
    }

    /// Placement for a *transient* Dock change — magnification while the
    /// pointer is over the Dock, or the tail of its unwind.
    ///
    /// The shelf stays in the Dock's own strip and hugs the Dock's current
    /// edge, compressed into whatever room is left: it can shrink to nothing
    /// (`.zero` means "nothing to show right now"), but it must never be
    /// overlapped by the Dock and never jump lanes. When the Dock settles, a
    /// full re-placement via `layout(slot:dock:)` restores the resting frame.
    /// Pure so the headless suite covers it.
    static func compressIntoGap(slot: Slot, dock: DockGeometry) -> CGRect {
        let gaps = dock.gaps
        let gap = slot == .leading ? gaps.leading : gaps.trailing
        let room = dock.orientation == .bottom ? gap.width : gap.height
        guard room >= minimumViableLength else { return .zero }

        var frame: CGRect
        switch dock.orientation {
        case .bottom:
            frame = CGRect(x: slot == .leading ? gap.maxX - room : gap.minX,
                           y: dock.dockStrip.minY,
                           width: room, height: dock.thickness)
        case .left, .right:
            frame = CGRect(x: dock.dockStrip.minX,
                           y: slot == .leading ? gap.minY : gap.maxY - room,
                           width: dock.thickness, height: room)
        }
        return clamp(frame, to: dock.screen)
    }

    /// How much the shelf's *content* should breathe for a transient Dock
    /// reading. Tiles are built for the resting thickness; while the Dock
    /// magnifies under the pointer the gap narrows, and scaling the content to
    /// the gap's ratio makes the icons track the Dock's own icons instead of
    /// staying frozen inside a shrinking window. Expressed against the
    /// *target* gap so it stays honest whatever mechanism produces the frame:
    /// a gap the content can't fit must scale down, never clip.
    ///
    /// Clamped to ≤ 1 on purpose: growing past resting size would push the
    /// content outside its own glass surface. Growth is handled the moment
    /// the reading confirms, by the re-layout that rebuilds tiles at the new
    /// resting thickness.
    static func contentScale(slot: Slot, dock: DockGeometry) -> CGFloat {
        let gaps = dock.gaps
        let gap = slot == .leading ? gaps.leading : gaps.trailing
        let room = dock.orientation == .bottom ? gap.width : gap.height
        guard room > 0, dock.thickness > 0 else { return 1 }
        return min(1, room / dock.thickness)
    }

    /// Keeps an *expanded* shelf expanded across a transient reading. The old
    /// behavior crushed it into its collapsed frame — the shelf visibly snapped
    /// shut whenever the Dock magnified underneath it.
    ///
    /// An expanded shelf lives entirely on its own side of the strip (above a
    /// bottom Dock, inboard of a side Dock), so it cannot overlap the Dock as
    /// long as it stays there. Only the depth axis needs to move: its inner
    /// face re-welds to the strip's face as the Dock's thickness changes, and
    /// the depth shrinks only when the screen cannot fit it (`.zero` when no
    /// depth is left at all). The length axis is untouched on purpose — the
    /// user's scroll position must not jump while the Dock breathes.
    static func expandedTransient(from frame: CGRect, dock: DockGeometry) -> CGRect {
        let screen = dock.screen
        let strip = dock.dockStrip
        switch dock.orientation {
        case .bottom:
            // Depth is vertical: the shelf hangs above the strip.
            let depth = min(frame.height, max(0, screen.maxY - strip.maxY))
            guard depth > 0 else { return .zero }
            return clamp(CGRect(x: frame.minX, y: strip.maxY,
                                width: frame.width, height: depth), to: screen)
        case .right:
            // Depth is horizontal: the shelf hangs inboard, to the strip's left.
            let depth = min(frame.width, max(0, strip.minX - screen.minX))
            guard depth > 0 else { return .zero }
            return clamp(CGRect(x: strip.minX - depth, y: frame.minY,
                                width: depth, height: frame.height), to: screen)
        case .left:
            // Depth is horizontal: the shelf hangs inboard, to the strip's right.
            let depth = min(frame.width, max(0, screen.maxX - strip.maxX))
            guard depth > 0 else { return .zero }
            return clamp(CGRect(x: strip.maxX, y: frame.minY,
                                width: depth, height: frame.height), to: screen)
        }
    }

    /// Grows the shelf into the screen, and along the strip when the gap alone
    /// is too short. The end anchored to the screen edge never moves, so the
    /// shelf appears to unfold out of the Dock rather than jump.
    ///
    /// The expanded frame is welded to the Dock's **inner face** — above a
    /// bottom Dock, inboard of a side Dock — exactly where the sidecar and
    /// transient placements already put it. Growing from inside the strip
    /// (the old behavior) produced an expanded frame that covered the Dock's
    /// own icons — fatal on a side Dock, where the depth axis runs straight
    /// across the icon column, and worst for a shelf at a window level above
    /// the Dock's, which then also swallowed the icons' clicks.
    private static func expand(from collapsed: CGRect, slot: Slot, dock: DockGeometry, strip: CGRect, screen: CGRect, depth: CGFloat) -> CGRect {
        var frame = collapsed
        switch dock.orientation {
        case .bottom:
            frame.size.height = min(depth, screen.height - strip.height)
            frame.origin.y = strip.maxY
            if frame.width < minimumUsefulLength {
                let extra = min(minimumUsefulLength - frame.width, screen.width - frame.width)
                // Grow toward the middle of the screen, away from the outer edge.
                if slot == .leading { frame.size.width += extra } else {
                    frame.origin.x -= extra
                    frame.size.width += extra
                }
            }
        case .right:
            frame.size.width = min(depth, screen.width - strip.width)
            frame.origin.x = strip.minX - frame.width
            if frame.height < minimumUsefulLength {
                let extra = min(minimumUsefulLength - frame.height, screen.height - frame.height)
                if slot == .leading { frame.size.height += extra } else {
                    frame.origin.y -= extra
                    frame.size.height += extra
                }
            }
        case .left:
            frame.size.width = min(depth, screen.width - strip.width)
            frame.origin.x = strip.maxX
            if frame.height < minimumUsefulLength {
                let extra = min(minimumUsefulLength - frame.height, screen.height - frame.height)
                if slot == .leading { frame.size.height += extra } else {
                    frame.origin.y -= extra
                    frame.size.height += extra
                }
            }
        }
        return frame
    }

    /// Frame used while the shelf is hidden: it slides out through the Dock's
    /// own edge, leaving a sliver that is still on screen and still clickable.
    static let peekSize: CGFloat = 4

    static func hiddenFrame(from visible: CGRect, dock: DockGeometry) -> CGRect {
        var frame = visible
        switch dock.orientation {
        case .right: frame.origin.x = dock.screen.maxX - peekSize
        case .left: frame.origin.x = dock.screen.minX - frame.width + peekSize
        case .bottom: frame.origin.y = dock.screen.minY - frame.height + peekSize
        }
        return frame
    }

    /// A frame is usable only if it has real area and overlaps a screen by more
    /// than the hidden sliver — anything less is indistinguishable from the
    /// shelf having vanished, which is the failure this app shipped with.
    static func isUsable(_ frame: CGRect, onAnyOf screens: [CGRect]) -> Bool {
        guard frame.width.isFinite, frame.height.isFinite,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width > peekSize, frame.height > peekSize else { return false }
        return screens.contains { screen in
            let overlap = screen.intersection(frame)
            return !overlap.isNull && overlap.width > peekSize && overlap.height > peekSize
        }
    }

    /// Clamp a frame so it sits inside `bounds` wherever it fits.
    static func clamp(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return frame }
        var result = frame
        result.size.width = max(1, min(result.width, bounds.width))
        result.size.height = max(1, min(result.height, bounds.height))
        result.origin.x = min(max(result.origin.x, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.origin.y, bounds.minY), bounds.maxY - result.height)
        return result
    }
}
