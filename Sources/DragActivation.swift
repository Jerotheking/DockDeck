import AppKit

/// Detects that a drag has started anywhere on the system, so the shelves can
/// open before the pointer arrives.
///
/// A collapsed shelf is only as thick as the Dock — 53 points on the reference
/// machine. Requiring the user to hit that strip with a dragged file before it
/// expands is a target far below what Fitts's law says is comfortable for a
/// moving pointer. Dockside solves this by activating its drop area "when the
/// drag begins" rather than on hover, and it is the right call: the shelf is
/// already open and wide by the time the pointer gets near it.
///
/// AppKit exposes no "a drag is in progress" flag, but a drag always writes to
/// the drag pasteboard, so its `changeCount` moving during a mouse-drag is a
/// reliable signal. Both monitors are global mouse events, which need no
/// accessibility permission and cost nothing while the pointer is still.
final class DragActivationMonitor {
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    private var monitors: [Any] = []
    private var lastChangeCount: Int
    private var isDragging = false

    init() { lastChangeCount = NSPasteboard(name: .drag).changeCount }

    deinit { stop() }

    func start() {
        stop()
        lastChangeCount = NSPasteboard(name: .drag).changeCount

        let dragHandler: (NSEvent) -> Void = { [weak self] _ in self?.evaluateDrag() }
        let endHandler: (NSEvent) -> Void = { [weak self] _ in self?.endDrag() }

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged], handler: dragHandler) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: endHandler) {
            monitors.append(monitor)
        }
        // Local variants so the behaviour also holds while DockDeck itself is
        // the active app, where global monitors do not fire.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged], handler: { [weak self] event in
            self?.evaluateDrag(); return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] event in
            self?.endDrag(); return event
        }) { monitors.append(monitor) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        isDragging = false
    }

    private func evaluateDrag() {
        guard !isDragging else { return }
        let changeCount = NSPasteboard(name: .drag).changeCount
        // A plain mouse-drag on the desktop writes nothing to the drag
        // pasteboard; only a real item drag bumps the count.
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        isDragging = true
        onDragBegan?()
    }

    private func endDrag() {
        guard isDragging else { return }
        isDragging = false
        // Resync: the drop itself may bump the count again, and a stale value
        // would make the next drag look like a continuation of this one.
        lastChangeCount = NSPasteboard(name: .drag).changeCount
        onDragEnded?()
    }
}
