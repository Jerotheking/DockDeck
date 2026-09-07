import AppKit
import CoreGraphics

/// Geometry for the notch-anchored shelf — pure, so the headless suite pins
/// every rect before any window exists.
///
/// The notch window's contract (from `NOTCH_DESIGN_BRIEF.md`):
/// - **closed** — a silhouette that covers the *physical* notch plus a small
///   click margin, and not one pixel more of the menu bar;
/// - **open** — a panel centered on the notch, hanging down into the screen,
///   always inside it;
/// - **peek** — a slightly stretched notch for transient events (Phase 2).
///
/// Everything derives from a `Measurement` taken from a real `NSScreen`, so
/// the numbers on Jero's machine (notch 220×38 on a 1800×1169 display) are
/// just one input, never constants.
enum NotchGeometry {

    // MARK: - Measurement

    /// What the notch window needs to know about one screen. Measured from
    /// AppKit; constructible by hand so the tests need no window server.
    struct Measurement: Equatable {
        /// The full screen frame in global coordinates.
        var screen: CGRect
        /// The physical notch rectangle (top-center). `.zero` on screens
        /// without a notch.
        var notch: CGRect
        /// The menu bar's height (`frame.maxY - visibleFrame.maxY`).
        var menuBarHeight: CGFloat

        var hasNotch: Bool { !notch.isEmpty }

        /// Measures the screen the shelf should anchor to: the first screen
        /// with a real notch (the MacBook's built-in display). Returns nil
        /// when no screen has one — the caller then skips the notch mode.
        static func measureNotchedScreen() -> Measurement? {
            guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else { return nil }
            return measure(screen: screen)
        }

        /// Measures one screen. Pure enough to test through the value path.
        static func measure(screen: NSScreen) -> Measurement {
            let safeTop = screen.safeAreaInsets.top
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            guard safeTop > 0,
                  let left = screen.auxiliaryTopLeftArea,
                  let right = screen.auxiliaryTopRightArea else {
                return Measurement(screen: screen.frame, notch: .zero, menuBarHeight: menuBar)
            }
            let width = screen.frame.width - left.width - right.width
            // AppKit coordinates run bottom-up: the notch hangs from the top.
            let notch = CGRect(x: left.maxX, y: screen.frame.maxY - safeTop,
                               width: width, height: safeTop)
            return Measurement(screen: screen.frame, notch: notch, menuBarHeight: menuBar)
        }

        /// A hand-built measurement for tests: notch centered at the top of
        /// `screen`, `notchWidth × notchHeight`.
        static func fixture(screen: CGRect, notchWidth: CGFloat, notchHeight: CGFloat, menuBarHeight: CGFloat? = nil) -> Measurement {
            let bar = menuBarHeight ?? notchHeight
            let notch = CGRect(x: screen.midX - notchWidth / 2,
                               y: screen.maxY - notchHeight,
                               width: notchWidth, height: notchHeight)
            return Measurement(screen: screen, notch: notch, menuBarHeight: bar)
        }
    }

    // MARK: - Tuned constants (brief §2)

    /// Click margin beyond the physical notch on each side: clicks at the
    /// notch's soft edges must land on our silhouette, not fall through to
    /// the menu bar. boring.notch uses the same +4.
    static let clickMargin: CGFloat = 4
    /// The open panel's width. A shelf needs room for rows plus actions;
    /// matches the genre's 600–640.
    static let openWidth: CGFloat = 640
    /// Default open depth (height below the top edge). Settings will offer
    /// 320–560; this is the tuned default.
    static let defaultOpenDepth: CGFloat = 420
    static let minimumOpenDepth: CGFloat = 320
    static let maximumOpenDepth: CGFloat = 560
    /// Transparent strip *below* the open content inside the same window, so
    /// the panel can cast its own soft shadow without a system shadow frame.
    static let shadowPadding: CGFloat = 20
    /// Silhouette radii, closed → open. The closed values reproduce the
    /// physical notch's cone flare (small at the top edge, wider at the
    /// bottom); the open values relax as the panel grows. Animated per frame
    /// by interpolating on the morph fraction.
    static let closedTopRadius: CGFloat = 5.5
    static let closedBottomRadius: CGFloat = 14
    static let openTopRadius: CGFloat = 18
    static let openBottomRadius: CGFloat = 22
    /// Peek (Phase 2) radii sit between the two states.
    static let peekTopRadius: CGFloat = 8
    static let peekBottomRadius: CGFloat = 16

    // MARK: - State rects (pure)

    /// The closed silhouette: the physical notch plus the click margin on
    /// left, right, and below (never above — the screen edge is the top).
    /// Bottom-up coordinates: "downward" is a *smaller* y, so the rect grows
    /// by dropping its minimum edge; its maximum stays at the screen top.
    static func closedRect(_ m: Measurement) -> CGRect {
        guard m.hasNotch else { return .zero }
        return CGRect(x: m.notch.minX - clickMargin,
                      y: m.notch.minY - clickMargin,
                      width: m.notch.width + 2 * clickMargin,
                      height: m.notch.height + clickMargin)
    }

    /// The open panel: centered on the notch, hanging `depth` into the screen,
    /// clamped to stay inside it. Width shrinks rather than overflowing a
    /// narrow screen.
    static func openRect(_ m: Measurement, depth: CGFloat = defaultOpenDepth) -> CGRect {
        let d = min(max(depth, minimumOpenDepth), maximumOpenDepth)
        let width = min(openWidth, m.screen.width - 2 * clickMargin - 16)
        let height = min(d, m.screen.height - m.menuBarHeight - 24)
        return CGRect(x: m.screen.midX - width / 2,
                      y: m.screen.maxY - height,
                      width: width,
                      height: height)
    }

    /// The peek silhouette (Phase 2): the notch stretched a little wider and
    /// a little taller, for one-line event expansions.
    static func peekRect(_ m: Measurement) -> CGRect {
        guard m.hasNotch else { return .zero }
        let width = m.notch.width + 2 * 24
        let height = m.notch.height + 14
        return CGRect(x: m.screen.midX - width / 2,
                      y: m.screen.maxY - height,
                      width: width, height: height)
    }

    /// The *window* frame for an open panel: the content rect extended
    /// downward by the shadow padding only (bottom-up coordinates: a smaller
    /// y). The chrome is pinned to the window's top; the padding stays
    /// transparent. An even `insetBy` would wrongly add padding above the
    /// screen's top edge too.
    static func windowFrame(for content: CGRect) -> CGRect {
        CGRect(x: content.minX, y: content.minY - shadowPadding,
               width: content.width, height: content.height + shadowPadding)
    }

    /// The chrome's frame inside a window frame: everything except the
    /// transparent shadow strip at the bottom (bottom-up coordinates, so the
    /// strip is removed by raising the origin and shrinking the height).
    static func chromeRect(inWindow window: CGRect) -> CGRect {
        CGRect(x: window.minX, y: window.minY + shadowPadding,
               width: window.width, height: window.height - shadowPadding)
    }

    /// Morph fraction (0 = fully closed, 1 = fully open) from the *current
    /// content height* between the two states. Opening shrinks the window
    /// upward, so the height grows with closedness — the mapping normalizes
    /// that into one scalar everything else (radii, shadow) rides on.
    static func morphFraction(contentHeight: CGFloat, closed: CGRect, open: CGRect) -> CGFloat {
        let span = open.height - closed.height
        guard abs(span) > 1 else { return contentHeight >= open.height - 1 ? 1 : 0 }
        return min(1, max(0, (contentHeight - closed.height) / span))
    }

    /// Radii interpolated on the morph fraction.
    static func radii(fraction: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        let f = min(1, max(0, fraction))
        return (closedTopRadius + (openTopRadius - closedTopRadius) * f,
                closedBottomRadius + (openBottomRadius - closedBottomRadius) * f)
    }

    /// The silhouette path — a direct port of the competitors' `NotchShape`
    /// (DynamicNotchKit lineage): straight top edge, cone-curve corners whose
    /// top radius is small and bottom radius is wide, drawn in layer space
    /// (y down). One shape morphs between closed and open because the radii
    /// (and the rect) animate.
    static func silhouettePath(size: CGSize, topRadius: CGFloat, bottomRadius: CGFloat) -> CGPath {
        let w = max(1, size.width), h = max(1, size.height)
        let rt = min(max(0, topRadius), h / 2)
        let rb = min(max(0, bottomRadius), h / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: rt, y: rt), control: CGPoint(x: rt, y: 0))
        path.addLine(to: CGPoint(x: rt, y: h - rb))
        path.addQuadCurve(to: CGPoint(x: rt + rb, y: h), control: CGPoint(x: rt, y: h))
        path.addLine(to: CGPoint(x: w - rt - rb, y: h))
        path.addQuadCurve(to: CGPoint(x: w - rt, y: h - rb), control: CGPoint(x: w - rt, y: h))
        path.addLine(to: CGPoint(x: w - rt, y: rt))
        path.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - rt, y: 0))
        path.closeSubpath()
        return path
    }
}
