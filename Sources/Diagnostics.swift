import AppKit

/// Self-reporting for the one question that cannot be answered from outside the
/// process without a Screen Recording grant: *is the shelf actually on screen?*
///
/// `NSWindow.occlusionState` is the window server's own answer to that, read
/// from inside the app that owns the window. Enabled with
/// `DOCKDECK_DIAGNOSTICS=1`; writes JSON to `DOCKDECK_DIAGNOSTICS_PATH` (or
/// stdout) and, with `DOCKDECK_DIAGNOSTICS_EXIT=1`, quits afterwards so CI can
/// assert on the result. Off in every normal launch.
enum Diagnostics {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["DOCKDECK_DIAGNOSTICS"] == "1" }

    /// Phase marker for start-up. Emitted synchronously so the last line
    /// written names the stage that stalled or threw.
    static func trace(_ stage: String) {
        guard isEnabled else { return }
        let line = "DOCKDECK-TRACE \(stage)\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let outputPath {
            let tracePath = outputPath + ".trace"
            if let handle = FileHandle(forWritingAtPath: tracePath) {
                handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
            } else {
                try? line.write(toFile: tracePath, atomically: true, encoding: .utf8)
            }
        }
    }
    private static var shouldExit: Bool { ProcessInfo.processInfo.environment["DOCKDECK_DIAGNOSTICS_EXIT"] == "1" }
    private static var outputPath: String? { ProcessInfo.processInfo.environment["DOCKDECK_DIAGNOSTICS_PATH"] }
    /// Re-emit the report every N seconds. Lets a test observe the app reacting
    /// to something that changes after launch — a resized Dock, a moved Dock —
    /// instead of only its state at start-up.
    private static var repeatInterval: TimeInterval? {
        guard let raw = ProcessInfo.processInfo.environment["DOCKDECK_DIAGNOSTICS_INTERVAL"],
              let value = TimeInterval(raw), value >= 0.2 else { return nil }
        return value
    }
    private static var repeatTimer: Timer?

    /// Delay so the report describes a settled window: ordering front, the
    /// placement pass, and the first layout all have to finish first.
    static func scheduleReport(panels: [ShelfGeometry.Slot: ShelfPanel], statusItem: NSStatusItem?,
                               dock: @escaping () -> DockGeometry, isFirstRun: Bool, sensorAttached: @escaping () -> Bool) {
        guard isEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            emit(report(panels: panels, statusItem: statusItem, dock: dock(), isFirstRun: isFirstRun, sensorAttached: sensorAttached()))
            if let interval = repeatInterval {
                let timer = Timer(timeInterval: interval, repeats: true) { _ in
                    emit(report(panels: panels, statusItem: statusItem, dock: dock(), isFirstRun: isFirstRun, sensorAttached: sensorAttached()))
                }
                RunLoop.main.add(timer, forMode: .common)
                repeatTimer = timer
            }
            if shouldExit { NSApp.terminate(nil) }
        }
    }

    static func report(panels: [ShelfGeometry.Slot: ShelfPanel], statusItem: NSStatusItem?, dock: DockGeometry, isFirstRun: Bool, sensorAttached: Bool = false) -> [String: Any] {
        let info = Bundle.main.infoDictionary
        var payload: [String: Any] = [
            "version": info?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": info?["CFBundleVersion"] as? String ?? "unknown",
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "none",
            "activationPolicy": String(describing: NSApp.activationPolicy()),
            "delegateAttached": NSApp.delegate != nil,
            "dockSensorAttached": sensorAttached,
            "windowCount": NSApp.windows.count,
            "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "supportDirectory": AppDelegate.supportDirectory().path,
            "isFirstRun": isFirstRun,
            "screens": NSScreen.screens.map { NSStringFromRect($0.visibleFrame) }
        ]

        if let button = statusItem?.button {
            payload["statusItem"] = [
                "present": true,
                "visible": statusItem?.isVisible ?? false,
                "hasImage": button.image != nil,
                "hasTitle": !button.title.isEmpty,
                "menuItems": statusItem?.menu?.items.map(\.title) ?? []
            ]
        } else {
            payload["statusItem"] = ["present": false]
        }

        // The ⌥⇧E failure that shipped proves a failed hotkey registration is
        // invisible to every check that only inspects windows: report what the
        // delegate actually holds so the runtime verifier can assert on it.
        payload["hotkeys"] = AppDelegate.hotkeyReport()

        payload["dock"] = [
            "orientation": dock.orientation.rawValue,
            "autohides": dock.autohides,
            "source": dock.source.rawValue,
            "frame": NSStringFromRect(dock.frame),
            "thickness": dock.thickness,
            "tileSize": dock.tileSize,
            "strip": NSStringFromRect(dock.dockStrip),
            "gapLeading": NSStringFromRect(dock.gaps.leading),
            "gapTrailing": NSStringFromRect(dock.gaps.trailing),
            "accessibilityGranted": DockGeometry.accessibilityAvailable
        ]

        let screens = NSScreen.screens.map(\.frame)
        var shelves: [String: Any] = [:]
        for (slot, panel) in panels {
            let frame = panel.frame
            shelves[slot.rawValue] = [
                "state": String(describing: panel.state),
                "frame": NSStringFromRect(frame),
                "isVisible": panel.isVisible,
                "occlusionVisible": panel.occlusionState.contains(.visible),
                "isOnActiveSpace": panel.isOnActiveSpace,
                "alphaValue": panel.alphaValue,
                "usableFrame": ShelfGeometry.isUsable(frame, onAnyOf: screens),
                "layoutViable": panel.layout.isViable,
                "placementMode": panel.layout.mode.rawValue,
                "collapsedFrame": NSStringFromRect(panel.layout.collapsed),
                "compressedFrame": NSStringFromRect(ShelfGeometry.compressIntoGap(slot: panel.slot, dock: dock)),
                "expandedFrame": NSStringFromRect(panel.layout.expanded),
                "adjacentToDock": adjacency(of: panel.layout.collapsed, to: dock),
                "contentSubviews": panel.chrome.subviews.count,
                "windowMinSize": NSStringFromSize(panel.minSize),
                "contentMinSize": NSStringFromSize(panel.contentMinSize),
                "chromeFittingSize": NSStringFromSize(panel.chrome.fittingSize),
                "contentFittingSize": NSStringFromSize(panel.chrome.subviews.first?.fittingSize ?? .zero)
            ]
        }
        payload["shelves"] = shelves
        payload["shelfCount"] = panels.count
        return payload
    }

    /// Straight-line distance from the shelf to the Dock, zero when they touch.
    ///
    /// The whole premise of the app is that this is ~0. Measured rect-to-rect
    /// rather than along one axis, so it stays meaningful for a sidecar shelf,
    /// which touches the Dock on the perpendicular edge instead of end-to-end.
    private static func adjacency(of frame: CGRect, to dock: DockGeometry) -> CGFloat {
        let target = dock.frame
        let dx = max(0, max(target.minX - frame.maxX, frame.minX - target.maxX))
        let dy = max(0, max(target.minY - frame.maxY, frame.minY - target.maxY))
        return dx.isFinite && dy.isFinite ? hypot(dx, dy) : .greatestFiniteMagnitude
    }

    private static func emit(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        if let outputPath { try? text.write(toFile: outputPath, atomically: true, encoding: .utf8) }
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
}
