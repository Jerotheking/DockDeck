import AppKit

/// One shelf, anchored to one end of the Dock's strip.
///
/// Two of these flank the Dock. Each owns its geometry (via `ShelfGeometry`),
/// its glass chrome, and its expand/collapse state; it knows nothing about what
/// is inside it.
///
/// States:
/// - **collapsed** — exactly the gap the Dock leaves, at the Dock's thickness.
///   This is the resting state and is why the shelf reads as part of the Dock.
/// - **expanded** — grown into the screen to show full rows. Entered by hovering
///   or by dragging something over it, left shortly after the pointer goes away.
/// - **hidden** — slid out past the screen edge, mirroring an auto-hiding Dock.
final class ShelfPanel: NSPanel {
    enum State: Equatable { case collapsed, expanded, hidden }

    let slot: ShelfGeometry.Slot
    private(set) var state: State = .collapsed
    private(set) var layout: ShelfGeometry.Layout
    private(set) var dock: DockGeometry

    let chrome = ShelfChromeView()
    /// Everything the shelf controller renders lives in here, so a transient
    /// Dock reading can scale the shelf's content as one unit. Scaling a
    /// transform (a GPU-backed matrix) instead of rebuilding tiles at 4 Hz is
    /// what keeps the breathing smooth: no view churn, no flicker, no layout
    /// passes — the content simply tracks the Dock the way the Dock's own
    /// icons track its magnification.
    let contentScaleHost = NSView()
    /// The pointer-driven glass interactor. Created lazily on the first
    /// pointer enter so a shelf the pointer never touches costs nothing.
    private var interactor: GlassInteractor?
    /// The panel-owned tracking area that feeds the interactor: the Dock
    /// facing surface must know where the pointer is on it, not just when it
    /// crossed the border. `inVisibleRect` keeps the area tracking the
    /// chrome's bounds through springs and compressions without re-adding it.
    private var pointerArea: NSTrackingArea?
    private lazy var springs = SpringAnimator(window: self)
    private var collapseWorkItem: DispatchWorkItem?
    private var trackingArea: NSTrackingArea?

    /// Suppresses collapsing while a sheet, menu, editor, or drag owns the shelf.
    var isBusy = false { didSet { if !isBusy { scheduleCollapse() } } }
    /// Mirrors the Dock: when the Dock hides itself, so does the shelf.
    var mirrorsDockAutohide = true

    /// How long the shelf stays expanded after the pointer leaves. Long enough
    /// to cross a gap or reach for a scrollbar without it snapping shut.
    private static let collapseDelay: TimeInterval = 0.45

    var onStateChange: ((State) -> Void)?

    init(slot: ShelfGeometry.Slot, dock: DockGeometry, appearance: ShelfAppearance = .liquidGlass) {
        self.slot = slot
        self.dock = dock
        self.layout = ShelfGeometry.layout(slot: slot, dock: dock)
        chrome.surface = appearance
        let initial = layout.isViable ? layout.collapsed : CGRect(x: 0, y: 0, width: 60, height: 200)
        super.init(contentRect: initial,
                   styleMask: [.nonactivatingPanel, .borderless, .utilityWindow],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        // Above the Dock's own level (kCGDockWindowLevel = 20): the shelf
        // must read as popping out of the Dock, in front of it — a shelf the
        // Dock can draw over looks like it never leaves the strip. It stays
        // clear of the Dock by geometry (it compresses away when the Dock
        // magnifies), not by losing the z-order fight. `.mainMenu` (24) sits
        // above the Dock and below the menu-bar extras.
        level = .mainMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        // The glass provides its own edge; a system shadow on top of it reads as
        // a second, competing boundary.
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = chrome
        contentScaleHost.wantsLayer = true
        contentScaleHost.layer = CALayer()
        contentScaleHost.layer?.anchorPoint = anchorPoint(for: slot)
        chrome.addSubview(contentScaleHost)
        applyCornerStyle()
        // Installed up front: a tracking area added *in response to* the first
        // mouseEntered would never see that event. `.activeAlways` keeps the
        // glow working on a panel that never becomes key.
        installPointerArea()
        acceptsMouseMovedEvents = true
    }

    // MARK: - Pointer life (the glass notices you)

    /// The panel itself owns a tracking area so the interactor gets continuous
    /// pointer positions — `DropRootView`'s area drives expand/collapse, this
    /// one drives the glow. Two owners, two jobs, no coupling.
    private func installPointerArea() {
        guard pointerArea == nil else { return }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        chrome.addTrackingArea(area)
        pointerArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        wakeInteractor()?.appear()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if let fresh = wakeInteractor() { fresh.appear() }
        interactor?.update(point: chrome.convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        interactor?.disappear()
    }

    /// Creates the glass interactor on demand — only on the OS with Liquid
    /// Glass, and only when the user has not asked for reduced motion.
    private func wakeInteractor() -> GlassInteractor? {
        if let interactor { return interactor }
        guard #available(macOS 26.0, *),
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return nil }
        let fresh = GlassInteractor(panel: self)
        interactor = fresh
        return fresh
    }

    /// The transform's anchor sits on the face that touches the Dock, so the
    /// content stays welded to the Dock's edge while it scales — exactly where
    /// the Dock's own icons grow from. (Core Animation anchors are normalized
    /// 0–1 with the origin at the layer's bottom-left.)
    private func anchorPoint(for slot: ShelfGeometry.Slot) -> CGPoint {
        switch dock.orientation {
        case .bottom: return slot == .leading ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 1, y: 0.5)
        case .left:   return slot == .leading ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0.5, y: 1)
        case .right:  return slot == .leading ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0.5, y: 1)
        }
    }

    /// Scales the shelf's content for a transient reading without touching
    /// layout. `layout()` fixes the host's frame each pass, and the transform
    /// rides on top of that, so a resting frame and a scale never fight.
    private func applyContentScale(_ scale: CGFloat) {
        let clamped = max(0.25, min(1, scale))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A restore still in flight would keep driving the presentation layer
        // past this assignment; it is superseded, so kill it first.
        contentScaleHost.layer?.removeAnimation(forKey: "dockScaleRestore")
        contentScaleHost.layer?.transform = clamped >= 0.999
            ? CATransform3DIdentity
            : CATransform3DMakeScale(clamped, clamped, 1)
        CATransaction.commit()
    }

    /// Undoes any transient scale and restores the content's natural size —
    /// the moment the Dock's reading is structural (or confirmed), the real
    /// layout (and its rebuilt tiles) takes over.
    private func restoreContentScale() {
        guard let layer = contentScaleHost.layer,
              !CATransform3DEqualToTransform(layer.transform, CATransform3DIdentity) else { return }
        let current = layer.transform
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            applyContentScale(1)
            return
        }
        CATransaction.begin()
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: current)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.damping = 14
        spring.stiffness = 180
        spring.duration = spring.settlingDuration
        CATransaction.setCompletionBlock { [weak self] in
            self?.applyContentScale(1)
        }
        contentScaleHost.layer?.add(spring, forKey: "dockScaleRestore")
        CATransaction.commit()
    }

    /// A borderless panel refuses key status by default, which would leave the
    /// search field unable to accept typing. `.nonactivatingPanel` means being
    /// key still does not steal activation from the frontmost app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    deinit { springs.stop(); collapseWorkItem?.cancel() }

    // MARK: - Geometry

    /// Reacts to a *transient* Dock change — magnification while the pointer is
    /// over the Dock, or the tail of its unwind. The shelf compresses into the
    /// gap the Dock leaves right now, hugging its current edge: the Dock may
    /// grow, but it never grows over the shelf. A zero frame means the Dock has
    /// taken the whole strip, and the shelf gets out of the way for that
    /// moment. Full placement is restored by the next non-transient reading.
    func applyTransient(dock newDock: DockGeometry) {
        dock = newDock
        layout = ShelfGeometry.layout(slot: slot, dock: newDock)
        applyCornerStyle()

        // A hidden shelf stays hidden. Its window is parked just past the
        // screen edge (mirroring an auto-hiding Dock), not ordered out —
        // animating it to a gap frame would pop it back into view every time
        // the Dock magnified. Structural readings re-park it via apply().
        guard state != .hidden else { return }

        // Content breathes with the Dock even when the shelf itself has no
        // room to move: the icons track the Dock's own icons as it magnifies.
        applyContentScale(ShelfGeometry.contentScale(slot: slot, dock: newDock))

        // An expanded shelf stays expanded — a Dock magnifying underneath it
        // must not slam it shut. Its inner face re-welds to the Dock's moved
        // edge; if the Dock's growth has consumed the shelf's end, get out of
        // the way instead of overlapping.
        if state == .expanded {
            let target = ShelfGeometry.expandedTransient(from: frame, dock: newDock)
            guard target != .zero else {
                springs.animate(to: ShelfGeometry.hiddenFrame(from: layout.collapsed, dock: newDock), parameters: .collapse) { [weak self] in
                    guard let self, self.state == .expanded else { return }
                    self.state = .hidden
                    self.onStateChange?(self.state)
                }
                return
            }
            springs.animate(to: target, parameters: .reveal)
            return
        }

        let target = ShelfGeometry.compressIntoGap(slot: slot, dock: newDock)
        guard target != .zero, ShelfGeometry.isUsable(target, onAnyOf: NSScreen.screens.map(\.frame)) else {
            if isVisible { orderOut(nil) }
            return
        }
        if !isVisible, state != .hidden { orderFrontRegardless() }
        // Follow the Dock *live*: the fast `.track` spring via retarget, which
        // keeps position and velocity — the compression reads as one gesture
        // welded to the magnification, not a chain of small animations.
        springs.retarget(to: target, parameters: .track)
    }

    /// Recomputes placement for a new Dock reading. Called at launch and
    /// whenever the Dock or the displays change.
    func apply(dock newDock: DockGeometry, animated: Bool) {
        let orientationChanged = dock.orientation != newDock.orientation
        dock = newDock
        layout = ShelfGeometry.layout(slot: slot, dock: newDock)
        applyCornerStyle()
        restoreContentScale()

        guard layout.isViable else {
            // No room at this end of the Dock. Ordering an unusable window on
            // screen would be worse than showing nothing.
            if isVisible { orderOut(nil) }
            return
        }

        let target = frameForCurrentState()
        // A hidden shelf's frame is *supposed* to fail the usability check: it
        // is a deliberate sliver past the screen edge, kept clickable on
        // purpose. Guarding only visible states means a Dock change while
        // hidden neither spams the log nor orders out an already-hidden panel.
        if state != .hidden {
            guard ShelfGeometry.isUsable(target, onAnyOf: NSScreen.screens.map(\.frame)) else {
                NSLog("DockDeck: %@ shelf produced an unusable frame %@; leaving it hidden", slot.rawValue, NSStringFromRect(target))
                if isVisible { orderOut(nil) }
                return
            }
        }

        /// The Dock moved to another edge or far along the strip — the shelf
        /// should read as decisively moving to its new home: quick, decisive,
        /// no bounce. Growth in place keeps the liquid character; a parked
        /// (hidden) shelf just teleports where nobody can see it.
        let jumped = orientationChanged
            || abs(target.origin.x - frame.origin.x) > 120
            || abs(target.origin.y - frame.origin.y) > 120
        if state == .hidden || !animated {
            springs.set(target)
        } else if jumped {
            springs.animate(to: target, parameters: .slide)
        } else {
            springs.animate(to: target, parameters: .reveal)
        }
    }

    private func frameForCurrentState() -> CGRect {
        switch state {
        case .collapsed: return layout.collapsed
        case .expanded: return layout.expanded
        case .hidden: return ShelfGeometry.hiddenFrame(from: layout.collapsed, dock: dock)
        }
    }

    /// Round only the corners that face into the screen; the ones against the
    /// screen edge stay square, exactly as the Dock's own background does.
    private func applyCornerStyle() {
        switch dock.orientation {
        case .bottom: chrome.roundedCorners = [.topLeft, .topRight]
        case .left: chrome.roundedCorners = [.topRight, .bottomRight]
        case .right: chrome.roundedCorners = [.topLeft, .bottomLeft]
        }
        chrome.cornerRadius = 12
    }

    // MARK: - Presentation

    /// Applies the appearance-dependent settings. Called at launch and whenever
    /// preferences change, so a surface swap never requires rebuilding a shelf.
    func applySettings(_ settings: ShelfSettings) {
        mirrorsDockAutohide = settings.mirrorDockAutohide
        chrome.surface = settings.appearance
    }

    /// Puts the panel on screen at its resting size, without revealing it —
    /// revealing is the caller's decision, and on an auto-hiding Dock it must
    /// not happen at all. Returns false when there is no viable place for this
    /// shelf, so the caller can say so instead of silently doing nothing.
    @discardableResult
    func present() -> Bool {
        guard layout.isViable else { return false }
        state = .collapsed
        springs.set(layout.collapsed)
        orderFrontRegardless()
        onStateChange?(state)
        return true
    }

    // MARK: - Expand to reveal

    func expand() {
        guard layout.isViable, state != .expanded else { collapseWorkItem?.cancel(); return }
        collapseWorkItem?.cancel()
        let wasHidden = state == .hidden
        state = .expanded
        if !isVisible { orderFrontRegardless() }
        restoreContentScale()
        springs.animate(to: layout.expanded, parameters: wasHidden ? .reveal : .expand)
        onStateChange?(state)
    }

    func collapse() {
        guard layout.isViable, state == .expanded else { return }
        collapseWorkItem?.cancel()
        state = .collapsed
        springs.animate(to: layout.collapsed, parameters: .collapse)
        onStateChange?(state)
    }

    /// Collapses after a grace period, so brushing past the shelf on the way
    /// somewhere else does not make it flap open and shut.
    func scheduleCollapse() {
        collapseWorkItem?.cancel()
        guard state == .expanded, !isBusy else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isBusy, !self.isKeyWindow else { return }
            self.collapse()
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDelay, execute: work)
    }

    func hide() {
        guard layout.isViable, state != .hidden else { return }
        collapseWorkItem?.cancel()
        state = .hidden
        springs.animate(to: ShelfGeometry.hiddenFrame(from: layout.collapsed, dock: dock), parameters: .collapse)
        onStateChange?(state)
    }

    /// The transform's host tracks the chrome's bounds on every frame change —
    /// springs, transient compressions, expansion. (NSWindow has no layout()
    /// hook worth the name here, and the `layout` property is already taken.)
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        contentScaleHost.frame = chrome.bounds
        interactor?.viewportChanged()
    }

    func reveal() {
        guard layout.isViable, state == .hidden else { return }
        state = .collapsed
        if !isVisible { orderFrontRegardless() }
        restoreContentScale()
        springs.animate(to: layout.collapsed, parameters: .reveal)
        onStateChange?(state)
    }

    func toggleExpansion() {
        switch state {
        case .expanded: collapse()
        case .collapsed, .hidden: expand()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if state == .expanded { collapse() }
    }
}
