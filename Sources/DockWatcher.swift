import AppKit

/// Notices when the Dock moves, resizes, or changes item count, and when the
/// display arrangement changes.
///
/// Architecture — the runloop is sovereign, decisions are pure:
///
/// 1. **`DockSensor`** — an `AXObserver` attached to the Dock process. Its
///    callbacks do nothing but mark the watcher dirty: no AX reads, no work.
/// 2. **Coalesced evaluation** — every dirty-mark funnels into *one* scheduled
///    evaluation, never closer than `coalesceInterval` (33 ms ≈ one frame)
///    apart. A burst of a hundred Dock notifications costs one evaluation and
///    one AX read, not a hundred. This is where the CPU runaway died.
/// 3. **The decision core** (`fold(_:reading:pointerOnDock:)`) — a pure
///    function from (state, reading, pointer) to a decision. It replaces the
///    old `asyncAfter` confirmation cascade: a size-only reading becomes the
///    resting geometry when it *repeats* (the Dock stopped breathing) or the
///    pointer is not on the Dock (magnification only happens under the
///    pointer), whichever comes first. At most one `onChange` per evaluation.
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
    private let sensor = DockSensor()

    var isSensorAttached: Bool { sensor.isHealthy }

    init() {
        current = DockGeometry.current()
        state = PromotionState(accepted: current)
    }

    deinit { stop() }

    func start() {
        stop()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in self?.requestEvaluation() })

        let workspace = NSWorkspace.shared.notificationCenter
        // Launching or quitting an app adds or removes a Dock tile, which moves
        // both gaps.
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.requestEvaluation()
            })
        }

        // Dock preference changes (position, auto-hide, size, magnification).
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.dock.prefchanged"), object: nil, queue: .main
        ) { [weak self] _ in self?.requestEvaluation() })

        // The push sensor: Dock-driven notifications, the fastest signal that
        // exists. Its callback only marks us dirty — the coalescer decides
        // when the actual measurement happens.
        sensor.onEvent = { [weak self] in self?.requestEvaluation() }
        sensor.start()

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.pollTicked() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        // Pointer-driven tracking covers the no-Accessibility case: the Dock
        // only magnifies while the pointer is on it, so mouse-moved events near
        // the strip are the signal. They mark dirty like everything else.
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
        evaluationScheduled = false
    }

    /// Forces a re-read, e.g. right after the Accessibility grant is given and
    /// exact measurement — and the push sensor — become possible.
    func refreshNow() {
        sensor.refresh()
        evaluate()
    }

    // MARK: - The coalescer

    /// Minimum spacing between two evaluations: one frame. Every dirty-mark
    /// lands within the same window, so a notification storm costs exactly one
    /// synchronous AX read per window instead of one per event.
    static let coalesceInterval: TimeInterval = 0.033
    /// Backstop poll for changes nothing else observes — and the sensor's
    /// health check.
    private static let pollInterval: TimeInterval = 1.5

    private var evaluationScheduled = false
    private var lastEvaluationStart = Date.distantPast
    /// Re-entrancy guard: if an event fires while an evaluation is mid-flight
    /// (possible when a recipient calls back into the watcher), it schedules
    /// the next tick instead of recursing.
    private var evaluating = false

    /// Marks the Dock dirty. At most one evaluation is ever scheduled; the
    /// first mark inside a fresh coalesce window books it.
    private func requestEvaluation() {
        guard !evaluationScheduled else { return }
        evaluationScheduled = true
        let elapsed = Date().timeIntervalSince(lastEvaluationStart)
        let delay = max(0, Self.coalesceInterval - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.evaluationScheduled else { return }
            self.evaluationScheduled = false
            self.evaluate()
        }
    }

    private func pollTicked() {
        if !sensor.isHealthy { sensor.refresh() }
        requestEvaluation()
    }

    private func pointerMoved() {
        // A generous approach zone around the strip: magnification only starts
        // once the pointer is essentially on the Dock, but measuring slightly
        // early hides the first frame of the reveal.
        let strip = current.dockStrip.insetBy(dx: -60, dy: -120)
        guard strip.contains(NSEvent.mouseLocation) else { return }
        requestEvaluation()
    }

    /// One coalesced evaluation: one AX read, one pure decision, at most one
    /// report.
    private func evaluate() {
        guard !evaluating else { requestEvaluation(); return }
        evaluating = true
        lastEvaluationStart = Date()

        let latest = DockGeometry.current()
        let decision = Self.fold(&state,
                                 reading: latest,
                                 pointerOnDock: latest.dockStrip.contains(NSEvent.mouseLocation))
        evaluating = false

        switch decision {
        case .idle:
            break
        case .offerTransient(let dock):
            onChange?(Reading(dock: dock, isTransient: true))
        case .adopt(let dock):
            onChange?(Reading(dock: dock, isTransient: false))
        }
    }

    // MARK: - The decision core (pure — the headless suite covers it directly)

    /// What one reading decides, given the promotion state.
    enum Decision: Equatable {
        /// The reading matches the accepted geometry; nothing to report.
        case idle
        /// Report as transient: the Dock is breathing (magnification) under
        /// the pointer. The reading is held as the promotion candidate.
        case offerTransient(DockGeometry)
        /// The reading becomes the resting geometry and is reported as such.
        case adopt(DockGeometry)
    }

    /// The promotion model: which reading is accepted as resting geometry, and
    /// which size-only reading is currently awaiting confirmation.
    struct PromotionState: Equatable {
        var accepted: DockGeometry
        var candidate: DockGeometry?
        var repeatedReadings: Int = 0
    }

    /// How many consecutive identical size-only readings promote a candidate
    /// to resting geometry. Two: the Dock's magnification animation never
    /// holds a frame still long enough to repeat inside two coalesce windows,
    /// but a settled Dock (divider drag done, reveal finished) reads the same
    /// on every tick until promoted.
    static let promotionQuorum = 2

    /// Folds one coalesced reading into the state and decides what to emit.
    ///
    /// The promotion rules, in order:
    /// - Same as accepted → idle. This is also the "animation unwound" case:
    ///   it clears any stale candidate so a later blip starts fresh.
    /// - Structurally different (edge, screen, auto-hide, tile size) → adopt
    ///   immediately. These cannot be animation artefacts.
    /// - Size-only: a new shape resets the count; a repeated shape counts up.
    ///   Adopt when the count reaches quorum *or* the pointer is off the Dock
    ///   — magnification happens only under the pointer, so a size-only
    ///   reading without it can only be a real resize (a divider drag without
    ///   tile-size change, a settings-slider resize, the tail of a reveal).
    static func fold(_ state: inout PromotionState, reading: DockGeometry, pointerOnDock: Bool) -> Decision {
        if reading == state.accepted {
            state.candidate = nil
            state.repeatedReadings = 0
            return .idle
        }
        if isStructural(reading, comparedTo: state.accepted) {
            state.candidate = nil
            state.repeatedReadings = 0
            state.accepted = reading
            return .adopt(reading)
        }
        if reading == state.candidate {
            state.repeatedReadings += 1
        } else {
            state.candidate = reading
            state.repeatedReadings = 1
        }
        if !pointerOnDock || state.repeatedReadings >= promotionQuorum {
            state.accepted = reading
            state.candidate = nil
            state.repeatedReadings = 0
            return .adopt(reading)
        }
        return .offerTransient(reading)
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

    /// The promotion state — private storage for `fold`, exposed as a stored
    /// property so the struct stays a value type the tests can also drive.
    private var state: PromotionState
}
