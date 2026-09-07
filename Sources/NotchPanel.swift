import AppKit
import QuartzCore

/// The notch shelf's window: a borderless panel whose *visible* part is the
/// notch silhouette — the physical notch plus a small click margin — that
/// morphs into a full panel when opened.
///
/// The morph is one spring driving three coupled properties per frame:
/// the window's frame (shrinking upward when closed), the chrome layer's
/// silhouette path (cone-curve radii interpolating closed→open), and the
/// open-state shadow opacity. One spring, one material — no view swaps, no
/// crossfades, per the design brief's motion law.
///
/// Geometry (rects, radii, path) all lives in `NotchGeometry` (pure); this
/// class only applies it per spring step.
final class NotchPanel: NSPanel {
    enum State: Equatable { case closed, open }

    private(set) var state: State = .closed
    /// The measurement this panel anchors to; replaced on screen changes.
    private(set) var measurement: NotchGeometry.Measurement
    private var openDepth: CGFloat = NotchGeometry.defaultOpenDepth

    /// The black silhouette chrome: a layer-backed view pinned to the window
    /// top, whose layer path is the morphing silhouette.
    private let chrome = NotchChromeView()
    /// The real shelf content that appears in the open sheet: search, kind
    /// tabs, and the newest items with their actions.
    let notchContent = NotchContentView()

    private lazy var springs = NotchSpringBox(window: self)
    private var escMonitor: Any?
    private var trackingArea: NSTrackingArea?

    /// Set by the controller for key-window queries on collapse decisions.
    weak var controller: NotchController?

    init(measurement: NotchGeometry.Measurement) {
        self.measurement = measurement
        let closed = NotchGeometry.closedRect(measurement)
        super.init(contentRect: closed,
                   styleMask: [.nonactivatingPanel, .borderless, .utilityWindow],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        level = .mainMenu + 3
        // No system shadow on the closed silhouette: a gray rectangle over
        // the menu bar would break the "this IS the notch" illusion. The open
        // panel draws its own soft shadow inside the chrome.
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        // The shelf must accept typed search (the boring.notch lesson: a
        // canBecomeKey=false notch cannot host a search field).
        acceptsMouseMovedEvents = true

        chrome.frame = CGRect(x: 0, y: closed.height, width: closed.width, height: 0)
        contentView = chrome

        notchContent.wantsLayer = true
        notchContent.isHidden = true
        chrome.addSubview(notchContent)

        applySilhouette(animated: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Activation surface

    override func sendEvent(_ event: NSEvent) {
        // Click-to-toggle on the closed silhouette: a left click that is not
        // consumed by a subview toggles. When open, clicks land on content.
        if event.type == .leftMouseDown, state == .closed {
            open()
        }
        super.sendEvent(event)
    }

    override func mouseEntered(with event: NSEvent) { controller?.pointerEntered() }
    override func mouseExited(with event: NSEvent) { controller?.pointerExited() }

    func installTrackingArea() {
        guard trackingArea == nil else { return }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        contentView?.addTrackingArea(area)
        trackingArea = area
        let esc = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.state == .open else { return event }
            self.dismiss()
            return nil
        }
        escMonitor = esc
    }

    deinit {
        springs.box.stop()
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
    }

    // MARK: - Geometry application

    private func applySilhouette(animated: Bool) {
        let targetContent: CGRect
        switch state {
        case .closed: targetContent = NotchGeometry.closedRect(measurement)
        case .open: targetContent = NotchGeometry.openRect(measurement, depth: openDepth)
        }
        let targetWindow = NotchGeometry.windowFrame(for: targetContent)

        if !animated {
            springs.box.stop()
            setFrame(targetWindow, display: true)
            layoutChrome()
            return
        }
        springs.box.animate(to: targetWindow, parameters: state == .open ? .notchOpen : .notchClose) { [weak self] in
            self?.layoutChrome()
        }
    }

    /// Per-frame chrome layout: called from the spring step (via setFrame →
    /// this panel's override) and once at init. Keeps the chrome pinned to
    /// the window top and re-cuts the silhouette from the current fraction.
    private func layoutChrome() {
        let bounds = chrome.bounds
        chrome.frame = bounds
        // The glass sheet fills the open panel's content area but stays *below*
        // the silhouette's own height while closed, so the black lip reads as
        // the notch's edge at every fraction of the morph.
        let contentHeight = max(0, bounds.height - NotchGeometry.shadowPadding)
        let fraction = NotchGeometry.morphFraction(
            contentHeight: contentHeight,
            closed: NotchGeometry.closedRect(measurement),
            open: NotchGeometry.openRect(measurement, depth: openDepth))
        notchContent.frame = CGRect(x: 0, y: bounds.height - contentHeight,
                                    width: bounds.width, height: contentHeight)
        chrome.apply(fraction: fraction,
                     topRadius: NotchGeometry.radii(fraction: fraction).top,
                     bottomRadius: NotchGeometry.radii(fraction: fraction).bottom)
        notchContent.isHidden = fraction < 0.02
        notchContent.alphaValue = fraction
    }

    /// The spring drives the window through setFrame — this override is the
    /// per-frame hook (same pattern as ShelfPanel).
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        guard state == .open || springs.box.isRunning else { return }
        layoutChrome()
    }

    // MARK: - State changes

    func open() {
        guard state != .open else { return }
        state = .open
        orderFrontRegardless()
        // Content refreshes at open time — the delegate is asked again, so
        // items are never stale no matter what changed while closed.
        notchContent.prepareForDisplay()
        applySilhouette(animated: true)
        controller?.stateDidChange()
    }

    /// Named `dismiss` because `close()` already exists on `NSWindow`;
    /// redefining it without `override` is an ambiguity, and overriding it
    /// would entangle us with the system's own close path.
    func dismiss() {
        guard state != .closed else { return }
        state = .closed
        applySilhouette(animated: true)
        controller?.stateDidChange()
    }

    func toggle() { state == .open ? dismiss() : open() }

    /// Re-derives every rect for a (possibly new) screen measurement.
    func apply(measurement new: NotchGeometry.Measurement, animate: Bool) {
        measurement = new
        if state == .closed {
            // Re-anchor the closed silhouette to the (possibly moved) notch.
            springs.box.stop()
            setFrame(NotchGeometry.windowFrame(for: NotchGeometry.closedRect(new)), display: true)
            layoutChrome()
        } else {
            applySilhouette(animated: animate)
        }
    }

    func setDepth(_ depth: CGFloat) {
        openDepth = min(max(depth, NotchGeometry.minimumOpenDepth), NotchGeometry.maximumOpenDepth)
        if state == .open { applySilhouette(animated: true) }
    }
}

/// The black silhouette view. Layer-backed; its layer's path is the morphing
/// notch silhouette, filled with the same near-black the physical notch
/// reads as, plus the open-state shadow drawn as a layer shadow (radius and
/// opacity ramp with the morph fraction).
final class NotchChromeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { return nil }

    override var isFlipped: Bool { true }

    private var appliedFraction: CGFloat = -1
    private var appliedTop: CGFloat = -1
    private var appliedBottom: CGFloat = -1
    private var lastFraction: CGFloat?
    private var lastTop: CGFloat = 0
    private var lastBottom: CGFloat = 0

    /// Applies the current morph state: cuts the silhouette path and ramps
    /// the shadow. Cheap guards keep repeated per-frame calls free when the
    /// values have not changed.
    func apply(fraction: CGFloat, topRadius: CGFloat, bottomRadius: CGFloat) {
        guard let layer else { return }
        let changed = abs(fraction - appliedFraction) > 0.001
            || abs(topRadius - appliedTop) > 0.1
            || abs(bottomRadius - appliedBottom) > 0.1
        guard changed else { return }
        appliedFraction = fraction
        appliedTop = topRadius
        appliedBottom = bottomRadius
        lastFraction = fraction
        lastTop = topRadius
        lastBottom = bottomRadius

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The silhouette covers the window minus the transparent shadow strip
        // at its bottom; in this flipped view y=0 is the window's TOP edge, so
        // a path of height `contentHeight` anchored at the origin hangs from
        // the top — exactly where the notch is.
        let contentHeight = max(1, bounds.height - NotchGeometry.shadowPadding)
        let path = NotchGeometry.silhouettePath(size: CGSize(width: bounds.width, height: contentHeight),
                                                topRadius: topRadius,
                                                bottomRadius: bottomRadius)
        if fillLayer == nil {
            fillLayer = CAShapeLayer()
            layer.addSublayer(fillLayer!)
        }
        // The fill IS the silhouette: near-black like the physical notch. The
        // path must be assigned to the *fill layer* — the original version
        // only ever fed it to the window's shadow, so the shelf rendered as a
        // perfectly transparent window at the perfect position.
        fillLayer?.frame = bounds
        fillLayer?.path = path
        fillLayer?.fillColor = NSColor.black.cgColor
        layer.shadowOpacity = Float(0.35 * fraction)
        layer.shadowRadius = 14 * fraction + 1
        layer.shadowOffset = CGSize(width: 0, height: -6)
        layer.shadowPath = path
        layer.masksToBounds = false
        CATransaction.commit()
    }

    private var fillLayer: CAShapeLayer?

    override func layout() {
        super.layout()
        fillLayer?.frame = bounds
        appliedFraction = -1 // force a re-cut on bounds change
        // The layer only exists once the view joins a window, so an init-time
        // apply is silently skipped; re-applying the last known state here
        // guarantees the silhouette is painted as soon as the window is.
        if let f = lastFraction { apply(fraction: f, topRadius: lastTop, bottomRadius: lastBottom) }
    }
}

/// The animator lives in a box so the panel can hold it lazily without
/// fighting `NSWindow`'s own property surface.
final class NotchSpringBox {
    let box: SpringAnimator
    init(window: NSWindow) { box = SpringAnimator(window: window) }
    func animate(to frame: CGRect, parameters: SpringParameters, completion: (() -> Void)? = nil) {
        box.animate(to: frame, parameters: parameters, completion: completion)
    }
    func stop() { box.stop() }
    var isRunning: Bool { box.isRunning }
}
