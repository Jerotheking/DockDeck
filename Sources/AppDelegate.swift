import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panels: [ShelfGeometry.Slot: ShelfPanel] = [:]
    private var controllers: [ShelfGeometry.Slot: ShelfViewController] = [:]
    private var settings: SettingsStore?
    private var store: ShelfStore?
    private var projectStore: ProjectContextStore?
    private var statusItem: NSStatusItem?
    private var preferences: PreferencesWindowController?
    private var onboarding: OnboardingWindowController?
    private var dockWatcher: DockWatcher?
    private var showHideHotkey: GlobalHotkey?
    private var expandHotkey: GlobalHotkey?
    private var toggleObserver: NSObjectProtocol?
    private var expandObserver: NSObjectProtocol?
    private var pointerMonitors: [Any] = []
    private var dragActivation: DragActivationMonitor?
    private var didCleanUp = false
    /// Auto-hide stays disarmed until this instant. Hiding the shelves before
    /// the user has seen them reproduces, from their side, exactly the bug this
    /// app shipped with: running, but nothing on screen.
    private var autoHideArmedAt = Date.distantFuture

    /// Which shelf goes on which side of the Dock. Matches Dockside: the shelf
    /// you drop things on comes first, the automatic one second.
    private static let roles: [ShelfGeometry.Slot: ShelfRole] = [.leading: .library, .trailing: .recents]

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.trace("didFinishLaunching:enter")
        NSApp.setActivationPolicy(.accessory)

        // Version banner: never again wonder whether the running process is
        // the build you just installed. The executable's mtime plus its build
        // number say exactly which binary this is.
        if let exe = Bundle.main.executableURL {
            let mtime = (try? FileManager.default.attributesOfItem(atPath: exe.path)[.modificationDate]) as? Date
            NSLog("DockDeck: starting build %@ (%@), binary modified %@",
                  Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
                  Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
                  mtime.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .medium) } ?? "?")
        }
        if !DockGeometry.accessibilityAvailable {
            NSLog("DockDeck: Accessibility not granted — Dock position tracking is approximate until granted")
        }

        // The status item is the only permanent affordance and the sole recovery
        // path if shelf construction fails, so it is installed before anything
        // that can go wrong.
        installStatusItem()
        Diagnostics.trace("statusItem:installed")

        let support = Self.supportDirectory()

        let settings = SettingsStore(url: support.appendingPathComponent("settings.json"))
        let isFirstRun = settings.isFirstRun
        settings.save()
        self.settings = settings

        let projectStore = ProjectContextStore(url: support.appendingPathComponent("projects.json"))
        self.projectStore = projectStore

        let store = ShelfStore(fileURL: support.appendingPathComponent("shelf.json"))
        store.limitPerKind = [
            .file: settings.settings.fileLimit,
            .note: settings.settings.noteLimit,
            .clipboard: settings.settings.clipboardLimit,
            .bookmark: 100
        ]
        self.store = store
        Diagnostics.trace("settings:ready")

        let watcher = DockWatcher()
        watcher.onChange = { [weak self] reading in
            // Transient changes (magnification) compress the shelves into the
            // gap as it exists right now and scale their content with a
            // transform — a GPU matrix, no tile rebuilds, no flicker — so the
            // icons track the Dock's own icons while it breathes. Resting
            // changes re-decide placement and re-render at the new thickness.
            if reading.isTransient {
                self?.panels.values.forEach { $0.applyTransient(dock: reading.dock) }
            } else {
                self?.applyDock(reading.dock, animated: true)
            }
        }
        dockWatcher = watcher

        buildShelves(dock: watcher.current, settings: settings, store: store, projectStore: projectStore)
        Diagnostics.trace("panel+controller:constructed")
        Diagnostics.trace("view:attached")

        watcher.start()
        installHotkeys()
        // Under diagnostics the shelves must show their launch state, not react
        // to whatever the pointer happens to be doing while a test runs.
        if !Diagnostics.isEnabled {
            installPointerTracking()
            installDragActivation()
        }
        Diagnostics.trace("services:started")

        presentShelves()
        Diagnostics.trace("shelf:presented")

        toggleObserver = NotificationCenter.default.addObserver(
            forName: .dockDeckToggle, object: nil, queue: .main
        ) { [weak self] _ in self?.toggleShelves() }
        expandObserver = NotificationCenter.default.addObserver(
            forName: .dockDeckExpandToggle, object: nil, queue: .main
        ) { [weak self] _ in self?.toggleExpansion() }

        Diagnostics.scheduleReport(panels: panels, statusItem: statusItem,
                                   dock: { [weak watcher] in watcher?.current ?? DockGeometry.current() },
                                   isFirstRun: isFirstRun,
                                   sensorAttached: { [weak watcher] in watcher?.isSensorAttached ?? false })

        // Deferred: runModal() inside didFinishLaunching stalls the run loop
        // before the shelves finish appearing, so the user would meet the
        // explanation before the thing it explains.
        if isFirstRun && !Diagnostics.isEnabled {
            DispatchQueue.main.async { [weak self] in self?.presentFirstRunGuidance() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { cleanUp() }

    /// A second `open` of a bundle marked `LSMultipleInstancesProhibited` is
    /// routed back here. Revealing the shelves makes "open it again" a working
    /// way to find them instead of a no-op.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        revealShelves()
        panels.values.forEach { $0.expand() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Idempotent: an explicit Quit followed by `applicationWillTerminate` must
    /// not double-invalidate timers or double-remove event monitors.
    private func cleanUp() {
        guard !didCleanUp else { return }
        didCleanUp = true
        controllers.values.forEach { $0.stopServices() }
        dockWatcher?.stop(); dockWatcher = nil
        showHideHotkey?.unregister(); showHideHotkey = nil
        expandHotkey?.unregister(); expandHotkey = nil
        pointerMonitors.forEach { NSEvent.removeMonitor($0) }
        pointerMonitors.removeAll()
        dragActivation?.stop(); dragActivation = nil
        if let toggleObserver { NotificationCenter.default.removeObserver(toggleObserver); self.toggleObserver = nil }
        if let expandObserver { NotificationCenter.default.removeObserver(expandObserver); self.expandObserver = nil }
        preferences?.close(); preferences = nil
        onboarding = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem); self.statusItem = nil }
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
        controllers.removeAll()
    }

    /// Storage location. `DOCKDECK_SUPPORT_DIR` redirects it so the runtime
    /// verifier can exercise first-run behaviour in a scratch directory instead
    /// of deleting the user's real shelf to do it.
    static func supportDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["DOCKDECK_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DockDeck", isDirectory: true)
    }

    // MARK: - Shelves

    private func buildShelves(dock: DockGeometry, settings: SettingsStore, store: ShelfStore, projectStore: ProjectContextStore) {
        for (slot, role) in Self.roles {
            guard isEnabled(role: role, in: settings.settings) else { continue }
            let panel = ShelfPanel(slot: slot, dock: dock, appearance: settings.settings.appearance)
            let controller = ShelfViewController(role: role, store: store, settingsStore: settings, projectStore: projectStore)
            controller.panel = panel

            let content = controller.view
            content.translatesAutoresizingMaskIntoConstraints = false
            panel.contentScaleHost.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: panel.contentScaleHost.topAnchor),
                content.leadingAnchor.constraint(equalTo: panel.contentScaleHost.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: panel.contentScaleHost.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: panel.contentScaleHost.bottomAnchor)
            ])

            panel.onStateChange = { [weak controller] state in controller?.setPresentation(state, animated: true) }
            controller.apply(dock: dock)
            controller.startServices()

            panels[slot] = panel
            controllers[slot] = controller
        }
    }

    private func isEnabled(role: ShelfRole, in settings: ShelfSettings) -> Bool {
        role == .library ? settings.showLibraryShelf : settings.showRecentsShelf
    }

    private func presentShelves() {
        guard let dock = dockWatcher?.current, let settings else { return }
        for panel in panels.values {
            panel.applySettings(settings.settings)
            guard panel.present() else { continue }
            panel.reveal()
        }
        // An auto-hiding Dock means the shelves start hidden too — except on the
        // very first run, where hiding immediately reproduces the original bug
        // from the user's point of view: nothing visible, nothing to click.
        // Grace period before auto-hide can act. Generous on a first run, where
        // the user is still reading the welcome sheet.
        autoHideArmedAt = Date().addingTimeInterval(settings.isFirstRun ? 20 : 2.5)
        if dock.autohides && settings.settings.mirrorDockAutohide && !settings.isFirstRun {
            panels.values.forEach { $0.hide() }
        }
    }

    private func applyDock(_ dock: DockGeometry, animated: Bool) {
        panels.values.forEach { $0.apply(dock: dock, animated: animated) }
        controllers.values.forEach { $0.apply(dock: dock) }
    }

    private func revealShelves() { panels.values.forEach { $0.reveal() } }

    /// Expands or collapses without changing whether the shelves are on screen.
    private func toggleExpansion() {
        let anyExpanded = panels.values.contains { $0.state == .expanded }
        if anyExpanded {
            panels.values.forEach { $0.collapse() }
        } else {
            panels.values.forEach { $0.reveal(); $0.expand() }
        }
    }

    /// Shows or hides the shelves entirely. Hiding is not collapsing: a
    /// collapsed shelf still occupies its gap beside the Dock, while a hidden
    /// one has slid out past the screen edge. The expand/collapse hotkey
    /// answers for the difference between those two; this one answers for
    /// presence. Showing expands, so an explicit request leaves the shelves
    /// findable rather than a Dock-thin strip.
    private func toggleShelves() {
        let onScreen = panels.values.contains { $0.state != .hidden }
        if onScreen {
            panels.values.forEach { $0.hide() }
        } else {
            panels.values.forEach { $0.reveal(); $0.expand() }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Mirrors the Dock's own reveal: when the pointer reaches the Dock's edge,
    /// the shelves come back with it. Global mouse-moved monitors need no
    /// accessibility permission and cost nothing while the pointer is still.
    private func installPointerTracking() {
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.pointerMoved() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            self?.pointerMoved(); return event
        }) {
            pointerMonitors.append(local)
        }
    }

    /// Opens both shelves the moment a drag starts anywhere on the system, so
    /// the user has a full-size target to aim at instead of a Dock-thin strip.
    private func installDragActivation() {
        let monitor = DragActivationMonitor()
        monitor.onDragBegan = { [weak self] in
            guard let self else { return }
            for panel in self.panels.values {
                panel.reveal()
                panel.expand()
                // Held open for the duration of the drag: a shelf that collapses
                // while the user is still travelling toward it is worse than one
                // that never opened.
                panel.isBusy = true
            }
        }
        monitor.onDragEnded = { [weak self] in
            guard let self else { return }
            for panel in self.panels.values { panel.isBusy = false }
        }
        monitor.start()
        dragActivation = monitor
    }

    private func pointerMoved() {
        guard let dock = dockWatcher?.current, let settings, settings.settings.mirrorDockAutohide, dock.autohides else { return }
        let mouse = NSEvent.mouseLocation
        let strip = dock.dockStrip
        // Same trigger band the Dock uses: a few points from the screen edge.
        let reveal: Bool
        switch dock.orientation {
        case .right: reveal = mouse.x >= dock.screen.maxX - 4
        case .left: reveal = mouse.x <= dock.screen.minX + 4
        case .bottom: reveal = mouse.y <= dock.screen.minY + 4
        }
        if reveal {
            panels.values.forEach { $0.reveal() }
            // Reaching the Dock's edge counts as finding them; hiding may arm.
            if autoHideArmedAt == .distantFuture || autoHideArmedAt > Date() {
                autoHideArmedAt = Date().addingTimeInterval(2.5)
            }
        } else if Date() >= autoHideArmedAt, !strip.insetBy(dx: -12, dy: -12).contains(mouse) {
            for panel in panels.values where panel.state != .hidden && !panel.isBusy && !panel.isKeyWindow {
                panel.hide()
            }
        }
    }

    // MARK: - Hotkey

    /// What the delegate actually holds, for diagnostics. A failed hotkey
    /// registration is invisible to every window-level check — the ⌥⇧E
    /// failure shipped that way — so the verifier needs this to assert on.
    static func hotkeyReport() -> [String: Bool] {
        guard let app = NSApp.delegate as? AppDelegate else { return [:] }
        return [
            "showHideRegistered": app.showHideHotkey?.isRegistered ?? false,
            "expandCollapseRegistered": app.expandHotkey?.isRegistered ?? false
        ]
    }

    /// Two bindings, because they are two different intents: one decides whether
    /// the shelves exist on screen at all, the other whether they are open.
    /// Collapsing a shelf you still want nearby is not the same as dismissing it.
    private func installHotkeys() {
        guard let settings else { return }
        showHideHotkey?.unregister()
        expandHotkey?.unregister()

        // The tooltip names the binding the user actually has, and is
        // refreshed here — the one place that runs both at launch and after
        // every shortcut change.
        statusItem?.button?.toolTip = "DockDeck — \(settings.settings.showHideShortcut.displayName) shows or hides the shelves"

        let showHide = GlobalHotkey()
        if !showHide.register(settings.settings.showHideShortcut, action: {
            NotificationCenter.default.post(name: .dockDeckToggle, object: nil)
        }) {
            NSLog("DockDeck: %@ is unavailable; use the menu bar item instead",
                  settings.settings.showHideShortcut.displayName)
        }
        showHideHotkey = showHide

        let expand = GlobalHotkey()
        if !expand.register(settings.settings.expandCollapseShortcut, action: {
            NotificationCenter.default.post(name: .dockDeckExpandToggle, object: nil)
        }) {
            NSLog("DockDeck: %@ is unavailable", settings.settings.expandCollapseShortcut.displayName)
        }
        expandHotkey = expand
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            // A nil SF Symbol would leave an invisible, unclickable status item.
            if let image = NSImage(systemSymbolName: "tray.2", accessibilityDescription: "DockDeck") {
                button.image = image
            } else {
                button.title = "▤"
            }
            button.setAccessibilityLabel("DockDeck")
        }
        item.isVisible = true

        let menu = NSMenu()
        menu.autoenablesItems = false
        let toggle = NSMenuItem(title: "Show DockDeck", action: #selector(toggleAction), keyEquivalent: "")
        menu.addItem(toggle)
        let expand = NSMenuItem(title: "Expand Shelves", action: #selector(expandAction), keyEquivalent: "")
        menu.addItem(expand)
        menu.addItem(NSMenuItem(title: "New Note", action: #selector(newNoteAction), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Preferences…", action: #selector(preferencesAction), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "About DockDeck", action: #selector(aboutAction), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DockDeck", action: #selector(quitAction), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    // MARK: - First run

    private func presentFirstRunGuidance() {
        NSApp.activate(ignoringOtherApps: true)
        panels.values.forEach { $0.reveal(); $0.expand() }

        // The onboarding panel teaches the gestures and offers the
        // Accessibility grant with a live status; granting it re-measures
        // the Dock so the shelves snap to their exact position.
        onboarding = OnboardingWindowController(showHideShortcut: settings?.settings.showHideShortcut.displayName ?? "⌥⇧D")
        // The completion must not clear `onboarding`: it runs *inside* the
        // controller's own action, and nilling the only strong reference there
        // deallocates the controller mid-call — the window then never closes
        // and "Get Started" appears to do nothing. The reference is dropped in
        // cleanUp instead.
        onboarding?.present { [weak self] in
            guard let self else { return }
            self.dockWatcher?.refreshNow()
            if let dock = self.dockWatcher?.current { self.applyDock(dock, animated: true) }
            self.panels.values.forEach { $0.scheduleCollapse() }
        }
    }

    // MARK: - Actions

    @objc private func toggleAction() { toggleShelves() }
    @objc private func expandAction() { toggleExpansion() }

    @objc private func newNoteAction() {
        revealShelves()
        controllers[.leading]?.newNote()
    }

    @objc private func preferencesAction() {
        guard let settings else { return }
        if preferences == nil {
            preferences = PreferencesWindowController(settings: settings) { [weak self] in
                guard let self, let settings = self.settings else { return }
                self.controllers.values.forEach { $0.applySettings() }
                // Surface grade applies without rebuilding: the chrome swaps
                // its effect in place.
                self.panels.values.forEach { $0.applySettings(settings.settings) }
                self.installHotkeys()
                self.dockWatcher?.refreshNow()
                if let dock = self.dockWatcher?.current { self.applyDock(dock, animated: true) }
            }
        }
        preferences?.show()
    }

    @objc private func aboutAction() {
        NSApp.activate(ignoringOtherApps: true)
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let dock = dockWatcher?.current
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "DockDeck \(version) (\(build))"
        alert.informativeText = """
        A private file shelf that lives beside your Dock.

        Dock placement: \(dock.map { "\($0.orientation.rawValue), measured by \($0.source.rawValue)" } ?? "unknown")
        Storage: ~/Library/Application Support/DockDeck
        No network access, no telemetry, no helper process.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quitAction() {
        cleanUp()
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.items.count > 1, let settings else { return }
        let expanded = panels.values.contains { $0.state == .expanded }
        let onScreen = panels.values.contains { $0.state != .hidden }
        // The titles state what the item will do next, and carry the shortcut
        // the user actually has bound rather than a hard-coded one.
        menu.items[0].title = (onScreen ? "Hide DockDeck" : "Show DockDeck")
            + "  " + settings.settings.showHideShortcut.displayName
        menu.items[1].title = (expanded ? "Collapse Shelves" : "Expand Shelves")
            + "  " + settings.settings.expandCollapseShortcut.displayName
    }
}
