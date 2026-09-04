import AppKit

/// One item as it appears on a collapsed shelf: an icon at the Dock's own tile
/// size, nothing else.
///
/// A collapsed shelf is only as thick as the Dock, so there is no room for text.
/// The tile therefore has to carry identity through the icon alone, and its hit
/// target has to stay comfortable — hence a tile that fills the strip rather
/// than a small icon floating in it.
final class ShelfTileView: NSView, NSDraggingSource {
    let item: ShelfItem
    var onOpen: (ShelfItem) -> Void
    var onPreview: (ShelfItem) -> Void

    private let iconView = NSImageView()
    private var tracking: NSTrackingArea?
    private var isHovered = false { didSet { if isHovered != oldValue { animateHover() } } }
    // Drag-out state, mirroring ShelfRowView: the mouse-down event that might
    // grow into a drag, and the token for this tile's one in-flight thumbnail
    // request.
    private var dragStartEvent: NSEvent?
    private var thumbnailToken: ThumbnailProvider.Token = 0
    private static let dragThreshold: CGFloat = 4

    init(item: ShelfItem, tileSize: CGFloat, onOpen: @escaping (ShelfItem) -> Void, onPreview: @escaping (ShelfItem) -> Void) {
        self.item = item
        self.onOpen = onOpen
        self.onPreview = onPreview
        super.init(frame: NSRect(x: 0, y: 0, width: tileSize, height: tileSize))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false

        iconView.image = ShelfRowView.icon(for: item)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        let inset = max(3, tileSize * 0.12)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: tileSize),
            heightAnchor.constraint(equalToConstant: tileSize),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            iconView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            iconView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        ])

        toolTip = item.title
        setAccessibilityLabel(item.title)
        setAccessibilityRole(.button)

        // delaysPrimaryMouseButtonEvents = false: the drag-out mouseDown/mouseDragged
        // overrides below need the raw event stream in real time, not held back
        // until this click gesture recognizer finishes deciding.
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)

        loadThumbnailIfNeeded()
    }
    required init?(coder: NSCoder) { return nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    @objc private func clicked() { onOpen(item) }

    /// The Dock's own hover response: the tile lifts slightly. Scaling from the
    /// centre keeps it from drifting, and the short spring keeps it feeling
    /// attached to the pointer rather than lagging behind it.
    private func animateHover() {
        guard let layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        let scale: CGFloat = isHovered ? 1.14 : 1.0
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            layer.transform = CATransform3DMakeScale(scale, scale, 1)
            return
        }
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = layer.value(forKeyPath: "transform.scale") ?? 1.0
        spring.toValue = scale
        spring.mass = 1
        spring.stiffness = SpringParameters.reveal.stiffness
        spring.damping = SpringParameters.reveal.damping
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "hover")
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
    }

    // MARK: - Thumbnails

    /// Same upgrade path as `ShelfRowView`: paint the generic icon
    /// immediately, then swap in QuickLook's real thumbnail once it resolves.
    private func loadThumbnailIfNeeded() {
        guard item.kind == .file, let path = item.path else { return }
        var requestToken: ThumbnailProvider.Token = 0
        requestToken = ThumbnailProvider.shared.requestThumbnail(for: path, size: bounds.size) { [weak self] image in
            guard let self, self.thumbnailToken == requestToken else { return }
            ShelfRowView.applyThumbnail(image, to: self.iconView)
        }
        thumbnailToken = requestToken
    }

    // MARK: - Drag out

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
        guard let writer = ShelfRowView.draggingWriter(for: item) else { NSSound.beep(); return }
        let draggingItem = NSDraggingItem(pasteboardWriter: writer)
        draggingItem.setDraggingFrame(iconView.frame, contents: iconView.image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
