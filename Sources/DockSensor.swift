import AppKit
import ApplicationServices

/// Push-based Dock geometry sensor.
///
/// The Dock's geometry is not observable through AppKit, but its accessibility
/// tree is: the Dock process exposes its item list, and the AX API can attach
/// an `AXObserver` to *another* process's elements, receiving push
/// notifications on the run loop the moment the Dock's windows change — the
/// mechanism Dockside-class apps use to follow the Dock without polling.
///
/// Subscribed events and what each one catches:
/// - Window-level `AXWindowCreated/Moved/Resized/Miniaturized/TitleChanged` —
///   orientation changes, position on screen, auto-hide reveal, growth when
///   items are added (the Dock's window is one element).
/// - Item-list `AXMoved/AXResized` — the frame events that drive the shelves.
/// - `AXUIElementDestroyed` — the Dock rebuilt its tree (logout/login, Dock
///   relaunch); `isHealthy` notices and `refresh()` re-attaches.
///
/// The observer is a CF object scheduled manually on a run loop; callbacks
/// arrive on the run loop it was added to (main, common modes). This sensor
/// owns it end-to-end and forwards every event as a single closure.
final class DockSensor {
    /// Called on the main run loop whenever the Dock's accessibility tree
    /// reports any change. Cheap enough to call `DockGeometry.current()` inside.
    var onEvent: (() -> Void)?

    private var observer: AXObserver?
    /// The Dock's item list element; the item-level notifications attach here.
    private var itemList: AXUIElement?
    /// Every element that currently has notifications registered, so `stop()`
    /// can unregister symmetrically.
    private var observedElements: [AXUIElement] = []
    /// Retained so the refcon pointer stays valid for the observer's lifetime.
    private var contextSelf: UnsafeMutableRawPointer?

    init() {}

    deinit { teardown() }

    /// True while the observer exists, the item list is still alive, and the
    /// Dock process is still running — the health check the polling path
    /// re-attaches on.
    var isHealthy: Bool {
        guard observer != nil, itemList != nil else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first != nil
    }

    /// Attaches to the Dock process. Returns false when Accessibility is not
    /// granted or the Dock process is momentarily unreachable — the caller
    /// keeps its event net and retry timer either way.
    @discardableResult
    func start() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        teardown()
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return false }

        var observer: AXObserver?
        let result = AXObserverCreate(dockApp.processIdentifier, { _, element, notification, refcon in
            guard let refcon else { return }
            let sensor = Unmanaged<DockSensor>.fromOpaque(refcon).takeUnretainedValue()
            sensor.onEvent?()
        }, &observer)
        guard result == .success, let observer else {
            NSLog("DockDeck: AXObserverCreate failed (osstatus %d)", result.rawValue)
            return false
        }
        self.observer = observer
        contextSelf = Unmanaged.passUnretained(self).toOpaque()

        // Schedule on the main run loop, common modes: callbacks keep firing
        // while menus track or scroll loops run — exactly when the Dock moves.
        CFRunLoopAddSource(RunLoop.main.getCFRunLoop(), AXObserverGetRunLoopSource(observer), .commonModes)

        let application = AXUIElementCreateApplication(dockApp.processIdentifier)
        guard let list = Self.findItemList(in: application) else {
            NSLog("DockDeck: Dock process reachable but no AXList found; sensor idle")
            return false
        }
        itemList = list

        // Item-list events: the Dock's geometry lives in this element's frame.
        observe(list, notifications: [
            "AXMoved", "AXResized", "AXValueChanged", "AXUIElementDestroyed",
        ])
        // Window-level events: position, orientation, auto-hide reveal, and
        // the growth that comes with a new tile. Registered on every window
        // that exists now, plus AXWindowCreated so windows appearing later
        // (auto-hide reveal, Dock relaunch) join the net too.
        if let windows = Self.windows(of: application) {
            for window in windows {
                observe(window, notifications: [
                    "AXWindowMoved", "AXWindowResized", "AXWindowMiniaturized",
                    "AXTitleChanged", "AXUIElementDestroyed",
                ])
            }
        }
        observe(application, notifications: ["AXWindowCreated"])
        return true
    }

    /// Re-attaches from scratch. Called by the watcher when the health check
    /// fails (Dock relaunched, element destroyed) or when Accessibility is
    /// newly granted — the exact moment onboarding offers it.
    func refresh() { start() }

    func stop() { teardown() }

    // MARK: - Plumbing

    private func observe(_ element: AXUIElement, notifications: [String]) {
        guard let observer else { return }
        for name in notifications {
            let result = AXObserverAddNotification(observer, element, name as CFString, contextSelf)
            if result != .success {
                // Not fatal: some windows briefly reject individual events.
                // The poll backstop still catches anything missed here.
                NSLog("DockDeck: AXObserverAddNotification(%@) → %d", name, result.rawValue)
            }
        }
        observedElements.append(element)
    }

    private func teardown() {
        if let observer {
            for element in observedElements {
                for name in ["AXMoved", "AXResized", "AXValueChanged", "AXUIElementDestroyed",
                             "AXWindowMoved", "AXWindowResized", "AXWindowMiniaturized",
                             "AXTitleChanged", "AXWindowCreated"] {
                    AXObserverRemoveNotification(observer, element, name as CFString)
                }
            }
            CFRunLoopRemoveSource(RunLoop.main.getCFRunLoop(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        itemList = nil
        observedElements.removeAll()
        contextSelf = nil
    }

    /// The item list is the only AXList the Dock exposes at the top level —
    /// the same identification DockGeometry's measurement path uses.
    private static func findItemList(in application: AXUIElement) -> AXUIElement? {
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return nil }
        for child in children {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            if role as? String == "AXList" { return child }
        }
        return nil
    }

    private static func windows(of application: AXUIElement) -> [AXUIElement]? {
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement], !windows.isEmpty else { return nil }
        return windows
    }
}
