import AppKit

/// Activation logic for the notch shelf. Owns the triggers that live *outside*
/// the panel (screen-wide hover detection, outside-click close, screen-change
/// follow); the panel keeps the ones that are naturally window events (click
/// on the silhouette, Esc).
///
/// Hover policy per the brief: the pointer resting on the closed silhouette
/// opens after 0.3 s; leaving cancels a pending open and schedules a close
/// 0.45 s later (the same courtesy delay the Dock shelves use). A pending
/// close never fires while the panel is key (search typing) or while a drag
/// interaction is holding it open (Phase 2).
final class NotchController {
    private let panel: NotchPanel
    private var pointerMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var hoverWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?

    /// Resting on the silhouette this long opens the shelf.
    var hoverDelay: TimeInterval = 0.30
    /// Grace period after the pointer leaves before the shelf closes itself.
    var closeDelay: TimeInterval = 0.45
    /// Extra padding around the open panel for the "still inside" test.
    private static let openSlack: CGFloat = 12

    init(panel: NotchPanel) {
        self.panel = panel
        panel.controller = self
    }

    func start() {
        panel.installTrackingArea()
        installPointerMonitors()
        installScreenObserver()
        reanchor(animated: false)
    }

    func stop() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        pointerMonitors.forEach { NSEvent.removeMonitor($0) }
        pointerMonitors.removeAll()
        hoverWork?.cancel(); hoverWork = nil
        closeWork?.cancel(); closeWork = nil
    }

    // MARK: - Screen follow

    private func installScreenObserver() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.reanchor(animated: false) }
    }

    /// Re-measures the notch screen and re-anchors the panel. When the notch
    /// display disappears (lid closed), the panel orders out; when a notch
    /// screen exists, the closed silhouette is always ordered on screen —
    /// being there is its resting state.
    private func reanchor(animated: Bool) {
        guard let measurement = NotchGeometry.Measurement.measureNotchedScreen() else {
            panel.orderOut(nil)
            return
        }
        panel.apply(measurement: measurement, animate: animated)
        panel.orderFrontRegardless()
    }

    // MARK: - Pointer life (screen-wide: the closed silhouette is tiny)

    private func installPointerMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.pointerMoved() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp], handler: handler) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp], handler: { [weak self] event in
            self?.pointerMoved(); return event
        }) {
            pointerMonitors.append(local)
        }
        // Clicks in *other* apps close an open shelf; clicks inside ours reach
        // the panel and are handled there.
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            self?.closeIfPointerOutside()
        }) {
            pointerMonitors.append(outside)
        }
    }

    private func pointerMoved() {
        guard panelVisible else { return }
        let mouse = NSEvent.mouseLocation
        switch panel.state {
        case .closed:
            let silhouette = NotchGeometry.closedRect(panel.measurement)
            if silhouette.contains(mouse) {
                scheduleOpen()
            } else {
                cancelOpen()
            }
        case .open:
            let inside = panel.frame.insetBy(dx: -Self.openSlack, dy: 0).contains(mouse)
            if inside {
                cancelClose()
            } else {
                scheduleClose()
            }
        }
    }

    // MARK: - Panel callbacks (window events)

    func pointerEntered() {
        guard panel.state == .closed else { cancelClose(); return }
        scheduleOpen()
    }

    func pointerExited() {
        switch panel.state {
        case .closed: cancelOpen()
        case .open: scheduleClose()
        }
    }

    /// The panel changed state on its own (click on the silhouette, Esc):
    /// reset any pending hover/close work so it cannot fire against the new
    /// state.
    func stateDidChange() {
        hoverWork?.cancel(); hoverWork = nil
        closeWork?.cancel(); closeWork = nil
    }

    // MARK: - Scheduling

    private func scheduleOpen() {
        guard hoverWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverWork = nil
            if NotchGeometry.closedRect(self.panel.measurement).contains(NSEvent.mouseLocation) {
                self.panel.open()
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverDelay, execute: work)
    }

    private func cancelOpen() {
        hoverWork?.cancel(); hoverWork = nil
    }

    private func scheduleClose() {
        guard closeWork == nil, !panel.isKeyWindow else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closeWork = nil
            let mouse = NSEvent.mouseLocation
            let inside = self.panel.frame.insetBy(dx: -Self.openSlack, dy: 0).contains(mouse)
            guard !inside, !self.panel.isKeyWindow else { return }
            self.panel.dismiss()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + closeDelay, execute: work)
    }

    private func cancelClose() {
        closeWork?.cancel(); closeWork = nil
    }

    private func closeIfPointerOutside() {
        guard panel.state == .open else { return }
        if !panel.frame.contains(NSEvent.mouseLocation) { panel.dismiss() }
    }

    private var panelVisible: Bool { panel.isVisible || panel.state == .open }
}
