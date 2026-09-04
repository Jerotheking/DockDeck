import AppKit
import ApplicationServices

/// The first-run welcome.
///
/// A plain alert cannot do the two jobs a first run has: teach the three
/// gestures that make the shelves findable, and walk the user through the one
/// permission DockDeck benefits from. This is a purpose-built panel instead:
/// the Accessibility step has a live status that flips the moment the grant is
/// given in System Settings, and finishing it re-measures the Dock so the
/// shelves visibly snap to their exact position.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let showHideShortcut: String
    private var window: NSWindow?
    private var pollTimer: Timer?
    private var onFinish: (() -> Void)?

    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let grantButton = NSButton(title: "Grant Access…", target: nil, action: nil)
    private let doneButton = NSButton(title: "Get Started", target: nil, action: nil)
    /// Whatever ends the panel — the button, closing the window, or the grant
    /// flipping the status — must hand control back exactly once.
    private var hasFinished = false

    private func finishOnce() {
        guard !hasFinished else { return }
        hasFinished = true
        pollTimer?.invalidate(); pollTimer = nil
        onFinish?()
    }

    init(showHideShortcut: String) {
        self.showHideShortcut = showHideShortcut
        super.init()
    }

    deinit { pollTimer?.invalidate() }

    func present(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        if window == nil { build() }
        refreshStatus()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        startPolling()
    }

    private func build() {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 330),
                             styleMask: [.titled, .fullSizeContentView],
                             backing: .buffered, defer: false)
        panel.title = ""
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        // Same frosted material as the shelves, so the first thing the user
        // reads is also a sample of what they just installed.
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .active
        panel.contentView = background

        let iconView = NSImageView(image: NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "DockDeck")!)
        iconView.contentTintColor = .controlAccentColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Welcome to DockDeck")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let intro = NSTextField(wrappingLabelWithString: """
        Two shelves now live beside your Dock — one for things you drop on it, one for recent screenshots and downloads. They stay as thin strips and open when you need them.
        """)
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        intro.alignment = .center
        intro.translatesAutoresizingMaskIntoConstraints = false

        func step(_ symbol: String, _ text: String) -> NSView {
            let row = NSStackView(views: [
                { let v = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!); v.contentTintColor = .secondaryLabelColor; return v }(),
                { let l = NSTextField(labelWithString: text); l.font = .systemFont(ofSize: 12); l.textColor = .labelColor; return l }()
            ])
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .firstBaseline
            return row
        }
        let gestures = NSStackView(views: [
            step("hand.draw", "Hover a strip to open it"),
            step("cursorarrow.and.square.on.square.dashed", "Drag anything onto a shelf"),
            step("keyboard", "\(showHideShortcut) shows or hides both shelves")
        ])
        gestures.orientation = .vertical
        gestures.spacing = 6
        gestures.alignment = .leading
        gestures.translatesAutoresizingMaskIntoConstraints = false

        statusIcon.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
        statusIcon.contentTintColor = .secondaryLabelColor
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        grantButton.bezelStyle = .rounded
        grantButton.controlSize = .small
        grantButton.target = self
        grantButton.action = #selector(requestAccessibility)
        grantButton.translatesAutoresizingMaskIntoConstraints = false

        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .regular
        doneButton.keyEquivalent = "\r"
        doneButton.target = self
        doneButton.action = #selector(finish)
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        let card = NSVisualEffectView()
        card.material = .contentBackground
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        let cardStack = NSStackView(views: [statusIcon, statusLabel, grantButton])
        cardStack.orientation = .vertical
        cardStack.spacing = 6
        cardStack.alignment = .leading
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)

        background.addSubview(iconView)
        background.addSubview(title)
        background.addSubview(intro)
        background.addSubview(gestures)
        background.addSubview(card)
        background.addSubview(doneButton)

        NSLayoutConstraint.activate([
            panel.contentView!.widthAnchor.constraint(equalToConstant: 420),
            panel.contentView!.heightAnchor.constraint(equalToConstant: 330),

            iconView.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            iconView.topAnchor.constraint(equalTo: background.topAnchor, constant: 26),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),

            title.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 6),
            title.centerXAnchor.constraint(equalTo: background.centerXAnchor),

            intro.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            intro.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 34),
            intro.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -34),

            gestures.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 14),
            gestures.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 48),

            card.topAnchor.constraint(equalTo: gestures.bottomAnchor, constant: 16),
            card.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -24),

            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            cardStack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -12),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),

            doneButton.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 14),
            doneButton.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            doneButton.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor, constant: -20)
        ])
        window = panel
    }

    // MARK: - Accessibility status

    private func startPolling() {
        pollTimer?.invalidate()
        guard DockGeometry.accessibilityAvailable == false else { refreshStatus(); return }
        // macOS grants Accessibility out of process and sends no notification;
        // polling while this panel is up is the only way to see it happen.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refreshStatus() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func refreshStatus() {
        let granted = DockGeometry.accessibilityAvailable
        statusIcon.image = NSImage(systemSymbolName: granted ? "checkmark.shield.fill" : "lock.shield", accessibilityDescription: nil)
        statusIcon.contentTintColor = granted ? .systemGreen : .secondaryLabelColor
        statusLabel.stringValue = granted
            ? "Accessibility granted — the shelves sit exactly against your Dock."
            : "Optional: grant Accessibility so the shelves measure your Dock exactly."
        grantButton.isHidden = granted
        if granted { finishOnce() }
    }

    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func finish() {
        finishOnce()
        window?.orderOut(nil); window = nil
    }

    func windowWillClose(_ notification: Notification) {
        finishOnce()
        window = nil
    }
}
