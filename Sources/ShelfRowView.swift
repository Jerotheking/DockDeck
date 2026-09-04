import AppKit

final class ShelfRowView: NSView, NSDraggingSource {
    let item: ShelfItem
    var onOpen: (ShelfItem) -> Void; var onPin: (ShelfItem) -> Void; var onDelete: (ShelfItem) -> Void; var onCopy: (ShelfItem) -> Void; var onMarkdown: (ShelfItem) -> Void; var onPreview: (ShelfItem) -> Void; var onReveal: (ShelfItem) -> Void; var onShare: (ShelfItem) -> Void; var onRename: (ShelfItem) -> Void; var onCompress: (ShelfItem) -> Void
    private let iconView = NSImageView(); private let titleLabel = NSTextField(labelWithString: ""); private let subtitleLabel = NSTextField(labelWithString: ""); private let pinButton = NSButton(title: "★", target: nil, action: nil); private let copyButton = NSButton(title: "⧉", target: nil, action: nil); private let deleteButton = NSButton(title: "✕", target: nil, action: nil); private var tracking: NSTrackingArea?; private var isHovered = false
    // Drag-out state: the mouse-down event that might grow into a drag, and
    // the token for this row's one in-flight thumbnail request.
    private var dragStartEvent: NSEvent?; private var thumbnailToken: ThumbnailProvider.Token = 0
    /// Movement past this many points turns a press into a drag rather than a
    /// click: small enough to feel immediate, large enough to absorb the
    /// jitter of an ordinary click.
    private static let dragThreshold: CGFloat = 4

    init(item: ShelfItem, onOpen: @escaping (ShelfItem) -> Void, onPin: @escaping (ShelfItem) -> Void, onCopy: @escaping (ShelfItem) -> Void, onDelete: @escaping (ShelfItem) -> Void, onMarkdown: @escaping (ShelfItem) -> Void = { _ in }, onPreview: @escaping (ShelfItem) -> Void = { _ in }, onReveal: @escaping (ShelfItem) -> Void = { _ in }, onShare: @escaping (ShelfItem) -> Void = { _ in }, onRename: @escaping (ShelfItem) -> Void = { _ in }, onCompress: @escaping (ShelfItem) -> Void = { _ in }) {
        self.item = item; self.onOpen = onOpen; self.onPin = onPin; self.onCopy = onCopy; self.onDelete = onDelete; self.onMarkdown = onMarkdown; self.onPreview = onPreview; self.onReveal = onReveal; self.onShare = onShare; self.onRename = onRename; self.onCompress = onCompress
        super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false; wantsLayer = true
        iconView.translatesAutoresizingMaskIntoConstraints = false; iconView.image = Self.icon(for: item); iconView.imageScaling = .scaleProportionallyUpOrDown; addSubview(iconView)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false; titleLabel.font = .systemFont(ofSize: 12, weight: item.pinned ? .semibold : .medium); titleLabel.textColor = .labelColor; titleLabel.lineBreakMode = .byTruncatingTail; titleLabel.stringValue = item.title; addSubview(titleLabel)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false; subtitleLabel.font = .systemFont(ofSize: 10); subtitleLabel.textColor = .secondaryLabelColor; subtitleLabel.lineBreakMode = .byTruncatingMiddle; subtitleLabel.stringValue = Self.subtitle(for: item); addSubview(subtitleLabel)
        for (button, symbol, action, label) in [(pinButton, "pin.fill", #selector(pinTapped), "Pin item"), (copyButton, "doc.on.doc", #selector(copyTapped), "Copy item"), (deleteButton, "xmark", #selector(deleteTapped), "Remove item")] { button.translatesAutoresizingMaskIntoConstraints = false; button.isBordered = false; button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium)); button.imagePosition = .imageOnly; button.target = self; button.action = action; button.isHidden = true; button.toolTip = label; button.setAccessibilityLabel(label); addSubview(button) }
        deleteButton.contentTintColor = .secondaryLabelColor
        copyButton.contentTintColor = .secondaryLabelColor
        pinButton.contentTintColor = item.pinned ? .systemYellow : .secondaryLabelColor
        NSLayoutConstraint.activate([iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), iconView.centerYAnchor.constraint(equalTo: centerYAnchor), iconView.widthAnchor.constraint(equalToConstant: 20), iconView.heightAnchor.constraint(equalToConstant: 20), titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 9), titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6), titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: pinButton.leadingAnchor, constant: -4), subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor), subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2), subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6), subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8), deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor), copyButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -3), copyButton.centerYAnchor.constraint(equalTo: centerYAnchor), pinButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -3), pinButton.centerYAnchor.constraint(equalTo: centerYAnchor)])
        // delaysPrimaryMouseButtonEvents = false: the drag-out mouseDown/mouseDragged
        // overrides below need the raw event stream in real time, not held back
        // until these click gesture recognizers finish deciding.
        let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked)); click.numberOfClicksRequired = 1; click.delaysPrimaryMouseButtonEvents = false; addGestureRecognizer(click); let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(previewClicked)); doubleClick.numberOfClicksRequired = 2; doubleClick.delaysPrimaryMouseButtonEvents = false; addGestureRecognizer(doubleClick); click.shouldBeRequiredToFail(by: doubleClick)
        let menu = NSMenu(); menu.addItem(withTitle: "Open", action: #selector(rowClicked), keyEquivalent: ""); if item.kind == .file { menu.addItem(withTitle: "Quick Look", action: #selector(previewClicked), keyEquivalent: ""); menu.addItem(withTitle: "Show in Finder", action: #selector(revealTapped), keyEquivalent: ""); menu.addItem(withTitle: "Rename", action: #selector(renameTapped), keyEquivalent: ""); menu.addItem(withTitle: "Compress as ZIP", action: #selector(compressTapped), keyEquivalent: ""); menu.addItem(withTitle: "Share", action: #selector(shareTapped), keyEquivalent: "") }; menu.addItem(withTitle: item.kind == .file ? "Copy Path" : "Copy Text", action: #selector(copyTapped), keyEquivalent: ""); menu.addItem(withTitle: "Copy as Markdown", action: #selector(markdownTapped), keyEquivalent: ""); menu.addItem(withTitle: item.pinned ? "Unpin" : "Pin to Top", action: #selector(pinTapped), keyEquivalent: ""); menu.addItem(.separator()); menu.addItem(withTitle: "Remove from Shelf", action: #selector(deleteTapped), keyEquivalent: ""); menu.items.forEach { $0.target = self }; self.menu = menu
        loadThumbnailIfNeeded()
    }
    required init?(coder: NSCoder) { return nil }
    override func updateTrackingAreas() { super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }; let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil); addTrackingArea(area); tracking = area }
    override func mouseEntered(with event: NSEvent) { isHovered = true; [pinButton, copyButton, deleteButton].forEach { $0.isHidden = false }; NSAnimationContext.runAnimationGroup { context in context.duration = 0.14; self.animator().alphaValue = 1 }; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; [pinButton, copyButton, deleteButton].forEach { $0.isHidden = true }; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) { let radius: CGFloat = 8; let rect = bounds.insetBy(dx: 4, dy: 2); let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius); (isHovered ? NSColor.controlAccentColor.withAlphaComponent(0.10) : NSColor.labelColor.withAlphaComponent(0.035)).setFill(); path.fill(); if item.pinned { NSColor.systemYellow.withAlphaComponent(0.18).setStroke(); path.lineWidth = 1; path.stroke() } }
    @objc private func rowClicked() { onOpen(item) }; @objc private func previewClicked() { onPreview(item) }; @objc private func pinTapped() { onPin(item) }; @objc private func copyTapped() { onCopy(item) }; @objc private func markdownTapped() { onMarkdown(item) }; @objc private func deleteTapped() { onDelete(item) }; @objc private func revealTapped() { onReveal(item) }; @objc private func shareTapped() { onShare(item) }; @objc private func renameTapped() { onRename(item) }; @objc private func compressTapped() { onCompress(item) }
    static func icon(for item: ShelfItem) -> NSImage { switch item.kind { case .note: return NSImage(systemSymbolName: "note.text", accessibilityDescription: "Note") ?? NSImage(); case .clipboard: return NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard") ?? NSImage(); case .bookmark: return NSImage(systemSymbolName: "link", accessibilityDescription: "Bookmark") ?? NSImage(); case .file: if let path = item.path, FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }; return NSImage(systemSymbolName: "doc.question", accessibilityDescription: "Missing file") ?? NSImage() } }
    static func subtitle(for item: ShelfItem) -> String { switch item.kind { case .file: return item.path ?? ""; case .note, .clipboard: return item.text ?? ""; case .bookmark: return item.urlString ?? "" } }

    // MARK: - Thumbnails

    /// Kicks off the async upgrade from generic icon to real thumbnail. Only
    /// `.file` items have anything for QuickLook to render.
    private func loadThumbnailIfNeeded() {
        guard item.kind == .file, let path = item.path else { return }
        var requestToken: ThumbnailProvider.Token = 0
        requestToken = ThumbnailProvider.shared.requestThumbnail(for: path, size: NSSize(width: 20, height: 20)) { [weak self] image in
            guard let self, self.thumbnailToken == requestToken else { return }
            Self.applyThumbnail(image, to: self.iconView)
        }
        thumbnailToken = requestToken
    }

    /// Swaps in a thumbnail with a short crossfade instead of a hard cut, so
    /// an icon that resolves after the row is already on screen reads as a
    /// polish detail rather than a flicker. Shared with `ShelfTileView`, which
    /// shows the same upgrade path at a different size.
    static func applyThumbnail(_ image: NSImage, to imageView: NSImageView) {
        guard let layer = imageView.layer else { imageView.image = image; return }
        let transition = CATransition(); transition.type = .fade; transition.duration = 0.15; transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(transition, forKey: "thumbnailFade")
        imageView.image = image
    }

    // MARK: - Drag out

    /// Builds the pasteboard payload for dragging `item` out of the shelf, or
    /// nil when it cannot be dragged — currently only a `.file` item whose
    /// target has vanished. Mirrors the per-kind content
    /// `ShelfViewController.copyItem` writes, so a drag and a copy always
    /// carry the same thing.
    static func draggingWriter(for item: ShelfItem) -> NSPasteboardWriting? {
        switch item.kind {
        case .file:
            guard let path = item.path, FileManager.default.fileExists(atPath: path) else { return nil }
            return NSURL(fileURLWithPath: path)
        case .note, .clipboard:
            return NSString(string: item.text ?? "")
        case .bookmark:
            return NSString(string: item.urlString ?? "")
        }
    }

    override func mouseDown(with event: NSEvent) { dragStartEvent = event; super.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { dragStartEvent = nil; super.mouseUp(with: event) }
    override func mouseDragged(with event: NSEvent) {
        guard let startEvent = dragStartEvent else { super.mouseDragged(with: event); return }
        let dx = event.locationInWindow.x - startEvent.locationInWindow.x
        let dy = event.locationInWindow.y - startEvent.locationInWindow.y
        guard hypot(dx, dy) >= Self.dragThreshold else { super.mouseDragged(with: event); return }
        dragStartEvent = nil
        beginDrag(with: startEvent)
    }

    private func beginDrag(with event: NSEvent) {
        guard let writer = Self.draggingWriter(for: item) else { NSSound.beep(); return }
        let draggingItem = NSDraggingItem(pasteboardWriter: writer)
        draggingItem.setDraggingFrame(iconView.frame, contents: iconView.image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
