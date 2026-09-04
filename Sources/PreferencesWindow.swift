import AppKit
import ApplicationServices

/// Settings window.
///
/// An `LSUIElement` app has no menu bar of its own, so this is the only place
/// behaviour can be changed — including turning a shelf back on after switching
/// it off, and granting the Accessibility permission that makes Dock placement
/// exact rather than estimated.
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private let onChange: () -> Void
    private var window: NSWindow?
    private var accessibilityTimer: Timer?

    private let libraryCheckbox = NSButton(checkboxWithTitle: "Shelf for files, notes, clipboard and links", target: nil, action: nil)
    private let recentsCheckbox = NSButton(checkboxWithTitle: "Shelf for recent screenshots and downloads", target: nil, action: nil)
    private let hoverCheckbox = NSButton(checkboxWithTitle: "Expand when the pointer rests on a shelf", target: nil, action: nil)
    private let mirrorCheckbox = NSButton(checkboxWithTitle: "Hide together with an auto-hiding Dock", target: nil, action: nil)
    private let clipboardCheckbox = NSButton(checkboxWithTitle: "Record clipboard history", target: nil, action: nil)
    private let downloadsCheckbox = NSButton(checkboxWithTitle: "Watch the Downloads folder", target: nil, action: nil)
    private let screenshotsCheckbox = NSButton(checkboxWithTitle: "Collect recent screenshots", target: nil, action: nil)
    private let appearancePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let depthSlider = NSSlider(value: Double(ShelfGeometry.defaultDepth),
                                       minValue: Double(ShelfGeometry.minimumDepth),
                                       maxValue: Double(ShelfGeometry.maximumDepth),
                                       target: nil, action: nil)
    private let depthLabel = NSTextField(labelWithString: "")
    private let showHideRecorder = ShortcutRecorderButton()
    private let expandRecorder = ShortcutRecorderButton()
    private let placementStatus = NSTextField(wrappingLabelWithString: "")
    private let grantButton = NSButton(title: "Open Privacy Settings…", target: nil, action: nil)

    init(settings: SettingsStore, onChange: @escaping () -> Void) {
        self.settings = settings
        self.onChange = onChange
        super.init()
    }

    deinit { accessibilityTimer?.invalidate() }

    func show() {
        if window == nil { build() }
        loadValues()
        refreshPlacementStatus()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        startWatchingAccessibility()
    }

    func close() {
        accessibilityTimer?.invalidate(); accessibilityTimer = nil
        window?.orderOut(nil)
        window = nil
    }

    private func build() {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 470),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
        panel.title = "DockDeck Preferences"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.level = .floating

        // Same material as the shelves, so preferences feel like part of the app.
        let background = NSVisualEffectView()
        background.material = .windowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        panel.contentView = background

        for control in [libraryCheckbox, recentsCheckbox, hoverCheckbox, mirrorCheckbox,
                        clipboardCheckbox, downloadsCheckbox, screenshotsCheckbox] {
            control.target = self
            control.action = #selector(commit)
        }
        depthSlider.target = self
        depthSlider.action = #selector(commit)
        depthSlider.isContinuous = true
        appearancePopup.addItems(withTitles: ShelfAppearance.allCases.map(\.displayName))
        appearancePopup.target = self
        appearancePopup.action = #selector(commit)
        depthLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        depthLabel.textColor = .secondaryLabelColor

        showHideRecorder.onCapture = { [weak self] shortcut in
            guard let self else { return }
            // Refuse a binding already used by the other action: the second
            // registration would silently never fire.
            guard shortcut != self.settings.settings.expandCollapseShortcut else {
                NSSound.beep()
                self.showHideRecorder.shortcut = self.settings.settings.showHideShortcut
                return
            }
            self.settings.update { $0.showHideShortcut = shortcut }
            self.onChange()
        }
        expandRecorder.onCapture = { [weak self] shortcut in
            guard let self else { return }
            guard shortcut != self.settings.settings.showHideShortcut else {
                NSSound.beep()
                self.expandRecorder.shortcut = self.settings.settings.expandCollapseShortcut
                return
            }
            self.settings.update { $0.expandCollapseShortcut = shortcut }
            self.onChange()
        }

        placementStatus.font = .systemFont(ofSize: 11)
        placementStatus.textColor = .secondaryLabelColor
        grantButton.bezelStyle = .rounded
        grantButton.controlSize = .small
        grantButton.target = self
        grantButton.action = #selector(requestAccessibility)

        let stack = NSStackView(views: [
            header("Shelves"),
            libraryCheckbox,
            recentsCheckbox,
            separator(),
            header("Behaviour"),
            hoverCheckbox,
            mirrorCheckbox,
            row(label: "Expanded size", control: depthSlider, trailing: depthLabel),
            separator(),
            header("Appearance"),
            row(label: "Surface", control: appearancePopup),
            separator(),
            header("Shortcuts"),
            row(label: "Show / hide", control: showHideRecorder),
            row(label: "Expand / collapse", control: expandRecorder),
            separator(),
            header("Sources"),
            clipboardCheckbox,
            downloadsCheckbox,
            screenshotsCheckbox,
            separator(),
            header("Dock placement"),
            placementStatus,
            grantButton
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -20)
        ])
        window = panel
    }

    private func header(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func row(label text: String, control: NSView, trailing: NSView? = nil) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let views: [NSView] = trailing.map { [label, control, $0] } ?? [label, control]
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.widthAnchor.constraint(equalToConstant: 410).isActive = true
        return stack
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 410).isActive = true
        return line
    }

    private func loadValues() {
        let current = settings.settings
        libraryCheckbox.state = current.showLibraryShelf ? .on : .off
        recentsCheckbox.state = current.showRecentsShelf ? .on : .off
        hoverCheckbox.state = current.expandOnHover ? .on : .off
        mirrorCheckbox.state = current.mirrorDockAutohide ? .on : .off
        clipboardCheckbox.state = current.monitorClipboard ? .on : .off
        downloadsCheckbox.state = current.monitorDownloads ? .on : .off
        screenshotsCheckbox.state = current.monitorScreenshots ? .on : .off
        if let index = ShelfAppearance.allCases.firstIndex(of: current.appearance) {
            appearancePopup.selectItem(at: index)
        }
        showHideRecorder.shortcut = current.showHideShortcut
        expandRecorder.shortcut = current.expandCollapseShortcut
        depthSlider.doubleValue = Double(current.expandedDepth)
        depthLabel.stringValue = "\(Int(depthSlider.doubleValue.rounded())) pt"
    }

    /// Says plainly which measurement is in use. An estimated Dock still works,
    /// it is just less precise, and the user deserves to know which they have
    /// rather than wondering why the shelves sit a few points off.
    private func refreshPlacementStatus() {
        let dock = DockGeometry.current()
        switch dock.source {
        case .accessibility:
            placementStatus.stringValue = "Exact. DockDeck measures your Dock directly (\(dock.orientation.rawValue) edge, \(Int(dock.thickness)) pt thick)."
            grantButton.isHidden = true
        case .estimated:
            placementStatus.stringValue = """
            Estimated. Without Accessibility, DockDeck infers the Dock's size from your preferences, so the shelves may sit slightly off. \
            Granting access lets it measure the Dock exactly and follow it as it changes.
            """
            grantButton.isHidden = false
        }
    }

    /// Polls while the window is open: macOS grants Accessibility in System
    /// Settings, out of process, and sends no notification when it happens.
    private func startWatchingAccessibility() {
        accessibilityTimer?.invalidate()
        guard !DockGeometry.accessibilityAvailable else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard DockGeometry.accessibilityAvailable else { return }
            self.accessibilityTimer?.invalidate()
            self.accessibilityTimer = nil
            self.refreshPlacementStatus()
            self.onChange()
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityTimer = timer
    }

    @objc private func requestAccessibility() {
        // Shows the system's own consent prompt, then opens the pane directly so
        // the user is not left hunting through System Settings.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startWatchingAccessibility()
    }

    @objc private func commit() {
        settings.update { values in
            values.showLibraryShelf = libraryCheckbox.state == .on
            values.showRecentsShelf = recentsCheckbox.state == .on
            values.expandOnHover = hoverCheckbox.state == .on
            values.mirrorDockAutohide = mirrorCheckbox.state == .on
            values.monitorClipboard = clipboardCheckbox.state == .on
            values.monitorDownloads = downloadsCheckbox.state == .on
            values.monitorScreenshots = screenshotsCheckbox.state == .on
            values.expandedDepth = CGFloat(depthSlider.doubleValue.rounded())
            let index = min(max(appearancePopup.indexOfSelectedItem, 0), ShelfAppearance.allCases.count - 1)
            values.appearance = ShelfAppearance.allCases[index]
        }
        depthLabel.stringValue = "\(Int(depthSlider.doubleValue.rounded())) pt"
        onChange()
    }

    func windowWillClose(_ notification: Notification) {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        window = nil
    }
}


/// A click-then-press control for binding a global shortcut.
///
/// While recording it installs a local key monitor and swallows every keystroke,
/// so the combination being captured cannot also trigger whatever it is
/// currently bound to. Escape cancels; a combination with no modifiers is
/// rejected rather than stored, because a global shortcut without modifiers
/// would intercept a bare keystroke in every other app.
final class ShortcutRecorderButton: NSButton {
    var onCapture: ((Shortcut) -> Void)?
    var shortcut: Shortcut = .showHide { didSet { refreshTitle() } }

    private var monitor: Any?
    private var isRecording = false { didSet { refreshTitle() } }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        target = self
        action = #selector(beginRecording)
        widthAnchor.constraint(equalToConstant: 130).isActive = true
        refreshTitle()
    }
    required init?(coder: NSCoder) { return nil }

    deinit { stopRecording() }

    private func refreshTitle() {
        title = isRecording ? "Press keys…" : shortcut.displayName
        contentTintColor = isRecording ? .controlAccentColor : nil
        setAccessibilityLabel(isRecording ? "Recording a shortcut" : "Shortcut \(shortcut.displayName)")
    }

    @objc private func beginRecording() {
        guard !isRecording else { stopRecording(); return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            guard event.type == .keyDown else { return nil }
            if event.keyCode == 53 { self.stopRecording(); return nil }   // Escape
            if let captured = Shortcut.from(event: event) {
                self.shortcut = captured
                self.stopRecording()
                self.onCapture?(captured)
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }
}
