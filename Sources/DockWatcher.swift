import AppKit

/// Notices when the Dock moves, resizes, or changes item count, and when the
/// display arrangement changes.
///
/// Three layers, fastest first:
///
/// 1. **`DockSensor`** — an `AXObserver` attached to the Dock process itself.
///    The Dock's *own* window and item-list notifications are the only signal
///    that fires for every change the Dock undergoes: position, orientation,
///    auto-hide reveal, magnification, divider drags, tile additions. This is
///    push, not inference.
/// 2. **Event inference** — screen-parameter changes, workspace launches and
///    quits, `com.apple.dock.prefchanged`, and pointer movement (the Dock only
///    magnifies while the pointer is on it). These still matter: the sensor
///    cannot run without the Accessibility grant, and prefchange fires before
///    the Dock has finished relaying out.
/// 3. **Confirmation poll** — a slow backstop that also re-attaches the
///    sensor if the Dock relaunched or its elements died.
///
/// Every differing reading is reported — never frozen out — because a shelf
/// that stands still while the Dock grows is a shelf the Dock draws over. The
/// watcher classifies: size-only changes are transient (hug the edge), any
/// change in position/orientation/screen/auto-hide/tile-size is structural
/// (re-place now).
final class DockWatcher {
    struct Reading: Equatable {
        let dock: DockGeometry
        /// True when only the Dock's size changed — magnification while the
        /// pointer is over it, or a relayout still settling. Recipients should
        /// compress into the remaining gap rather than re-decide placement.
        let isTransient: Bool
    }

    var onChange: ((Reading) -> Void)?
    private(set) var current: DockGeometry
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var pointerMonitors: [Any] = []
    /// A size-only reading waiting for confirmation as the new resting geometry.
    private var pendingReading: DockGeometry?
    /// Rate limit for pointer-driven re-evaluation. Zero on purpose: the
    /// pointer path is what makes magnification follow when the push sensor is
    /// not running, and mouse-moved events land at most once per hardware
    /// event — throttling them only added visible lag between the Dock's own
    /// icons and the shelf. (The guard stays for future tuning; the value is
    /// the fix.)
    private var lastEvaluation = Date.distantPast
    private static let pointerThrottle: TimeInterval = 0
    /// How long a size-only reading is given to repeat itself before it is
    /// promoted to resting geometry. Short on purpose: the promotion only
    /// rebuilds tiles, and the geometry itself was already applied live, so
    /// the user-visible effect of confirming early is nil and the benefit is
    /// a resting state that settles in the same beat as the Dock's animation.
    private static let confirmDelay: TimeInterval = 0.15
    /// Backstop poll for changes nothing else observes — and the sensor's
    /// health check. The event net is primary; this just keeps drift from
    /// outliving a few seconds.
    private static let pollInterval: TimeInterval = 1.5

    /// The push sensor. Nil only before `start()`; inert (start() returning
    /// false) whenever Accessibility is not granted, in which case the older
    /// inference layers carry tracking exactly as before.
    private let sensor = DockSensor()

    /// Whether the AXObserver push path is live right now. False simply means
    /// no Accessibility grant yet — tracking still works, just inferred.
    var isSensorAttached: Bool { sensor.isHealthy }

    init() { current = DockGeometry.current() }

    deinit { stop() }

    func start() {
        stop()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in self?.refresh(afterDelay: Self.confirmDelay) })

        let workspace = NSWorkspace.shared.notificationCenter
        // Launching or quitting an app adds or removes a Dock tile, which moves
        // both gaps.
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh(afterDelay: Self.confirmDelay)
            })
        }

        // Dock preference changes (position, auto-hide, size, magnification).
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.dock.prefchanged"), object: nil, queue: .main
        ) { [weak self] _ in self?.refresh(afterDelay: Self.confirmDelay) })

        // The push sensor: Dock-driven notifications, the fastest path that
        // exists — so fast its event must be used raw, with no throttle or
        // delay, or the whole point of push is lost. Inert without
        // Accessibility; started here and re-attached whenever the grant
        // appears or the Dock relaunches.
        sensor.onEvent = { [weak self] in self?.evaluate() }
        sensor.start()

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.pollTicked() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        // Pointer-driven tracking is what makes magnification follow in real
        // time when the sensor is not running (no Accessibility): the Dock
        // only magnifies while the pointer is on it, and mouse-moved events
        // are exactly the signal that this is happening.
        func track(_ monitor: Any?) {
            if let monitor { pointerMonitors.append(monitor) }
        }
        track(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] _ in
            self?.pointerMoved()
        })
        track(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.pointerMoved(); return event
        })
    }

    func stop() {
        sensor.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        pointerMonitors.forEach { NSEvent.removeMonitor($0) }
        pointerMonitors.removeAll()
        pendingReading = nil
    }

    /// Forces a re-read, e.g. right after the Accessibility grant is given and
    /// exact measurement — and the push sensor — become possible.
    func refreshNow() {
        sensor.refresh()
        evaluate()
    }

    private func refresh(afterDelay delay: TimeInterval) {
        guard delay > 0 else { evaluate(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.evaluate() }
    }

    /// Poll backstop: re-measure, and keep the sensor attached. A Dock relaunch
    /// or a destroyed element invalidates the observer; the health check here
    /// re-attaches within one poll instead of never.
    private func pollTicked() {
        if !sensor.isHealthy { sensor.refresh() }
        evaluate()
    }

    private func evaluate() {
        lastEvaluation = Date()
        let latest = DockGeometry.current()
        guard latest != current else {
            // Reverted to the accepted geometry — nothing to confirm anymore.
            pendingReading = nil
            return
        }

        if Self.isStructural(latest, comparedTo: current) {
            pendingReading = nil
            current = latest
            onChange?(Reading(dock: latest, isTransient: false))
            return
        }

        // Size-only change. The one change that is *only* size is
        // magnification — and magnification happens exclusively while the
        // pointer is on the Dock. A size-only reading taken while the pointer
        // is anywhere else is therefore a real resize, not an animation
        // artefact, and becomes the resting geometry immediately.
        let pointerOnDock = latest.dockStrip.contains(NSEvent.mouseLocation)
        let isConfirmation = pendingReading == latest
        pendingReading = latest
        onChange?(Reading(dock: latest, isTransient: pointerOnDock))
        if isConfirmation || !pointerOnDock {
            pendingReading = nil
            current = latest
            onChange?(Reading(dock: latest, isTransient: false))
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmDelay) { [weak self] in self?.evaluate() }
        }
    }

    /// Re-measures while the pointer moves near or on the Dock — the
    /// magnification path when the sensor is not running. Unthrottled while
    /// the pointer is *near the Dock's strip* (that is the only place the Dock
    /// can be changing), ignored elsewhere, so the Dock's own magnification
    /// animation is tracked at event rate instead of being sampled.
    private func pointerMoved() {
        guard Date().timeIntervalSince(lastEvaluation) >= Self.pointerThrottle else { return }
        // A generous approach zone around the strip: magnification only starts
        // once the pointer is essentially on the Dock, but starting the
        // re-measure slightly early hides the first frame of the reveal.
        let strip = current.dockStrip.insetBy(dx: -60, dy: -120)
        guard strip.contains(NSEvent.mouseLocation) else { return }
        evaluate()
    }

    /// Changes that cannot be an animation artefact: a different edge, screen,
    /// auto-hide state, or tile size. Tile size is the divider drag's signature.
    /// Internal, not private: it is a pure classifier, so the headless suite
    /// covers it directly.
    static func isStructural(_ latest: DockGeometry, comparedTo current: DockGeometry) -> Bool {
        latest.orientation != current.orientation
            || latest.screen != current.screen
            || latest.autohides != current.autohides
            || latest.tileSize != current.tileSize
    }
}
