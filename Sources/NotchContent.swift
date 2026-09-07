import AppKit

/// The notch shelf's content: what hangs from the silhouette when it opens.
///
/// Phase 1's open state was an empty black slab — the morph was real, the
/// product was not. This view is the product: a glass sheet that carries the
/// user's shelf — search, kind tabs, and the newest items as tappable rows
/// with real actions (open, reveal in Finder, copy path, delete).
///
/// Deliberately self-contained: it reads items through `delegate` at open
/// time and after every action, so it never holds stale state and never
/// observes the store directly.
protocol NotchContentStoreDelegate: AnyObject {
    /// Items for a kind tab; `nil` means "All". Newest first, pinned first.
    func notchItems(for kind: ItemKind?) -> [ShelfItem]
    /// Deletes an item from the underlying store.
    func notchDelete(_ item: ShelfItem)
}

final class NotchContentView: NSView {

    weak var delegate: NotchContentStoreDelegate?
    /// Opening an item defaults to the workspace open; overridable for tests.
    var onOpen: ((ShelfItem) -> Void)?

    private let glass = NSVisualEffectView()
    private let searchField = NSSearchField()
    private let tabBar = NSStackView()
    /// Rows are frame-laid by hand inside a flipped container: a required
    /// width-equality against the arranging stack aborted in CoreAutoLayout
    /// (`mutuallyExclusiveConstraints`) — manual layout is deterministic.
    private let rowsContainer = FlippedView()
    private var rowViews: [NotchRowView] = []
    private let emptyLabel = NSTextField(labelWithString: "Nothing on the shelf")
    private var selectedKind: ItemKind?
    private var currentItems: [ShelfItem] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }
    required init?(coder: NSCoder) { return nil }

    // MARK: - Build

    private func build() {
        wantsLayer = true

        glass.material = .sidebar
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 22
        glass.layer?.masksToBounds = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        searchField.placeholderString = "Search the shelf"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 12)
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchField)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            searchField.heightAnchor.constraint(equalToConstant: 30),
        ])

        tabBar.orientation = .horizontal
        tabBar.alignment = .centerY
        tabBar.spacing = 6
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabBar)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
        ])

        rowsContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowsContainer)
        NSLayoutConstraint.activate([
            rowsContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 12),
            rowsContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            rowsContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            rowsContainer.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -14),
        ])

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        emptyLabel.isHidden = true
    }

    // MARK: - Public surface

    /// Called when the panel opens: rebuilds tabs and rows from the delegate.
    func prepareForDisplay() {
        reloadTabs()
        reloadItems()
    }

    /// Rebuilds the kind tabs with live counts.
    func reloadTabs() {
        tabBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let all = delegate?.notchItems(for: nil) ?? []
        let tabs: [(ItemKind?, String, Int)] = [
            (nil, "All", all.count),
            (.file, "Files", all.filter { $0.kind == .file }.count),
            (.note, "Notes", all.filter { $0.kind == .note }.count),
            (.clipboard, "Clips", all.filter { $0.kind == .clipboard }.count),
            (.bookmark, "Links", all.filter { $0.kind == .bookmark }.count),
        ]
        for (kind, title, count) in tabs {
            let button = KindTabButton(kind: kind, title: count > 0 ? "\(title)  \(count)" : title)
            button.target = self
            button.action = #selector(tabClicked(_:))
            restyle(button, selected: kind == selectedKind)
            tabBar.addArrangedSubview(button)
        }
    }

    /// Re-renders the rows from the delegate for the current tab + query.
    func reloadItems() {
        let items = delegate?.notchItems(for: selectedKind) ?? []
        let needle = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: Locale.current)
        currentItems = needle.isEmpty ? items : items.filter { $0.haystack.contains(needle) }
        renderRows()
    }

    // MARK: - Rows

    private func renderRows() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()
        let rows = Array(currentItems.prefix(8))
        emptyLabel.isHidden = !rows.isEmpty
        for item in rows {
            let row = NotchRowView(item: item)
            row.target = self
            row.action = #selector(rowActivated(_:))
            row.menu = contextMenu(for: item)
            rowsContainer.addSubview(row)
            rowViews.append(row)
        }
        rowsContainer.needsLayout = true
    }

    private func contextMenu(for item: ShelfItem) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(menuOpen(_:)), keyEquivalent: "")
        if item.path != nil {
            menu.addItem(withTitle: "Reveal in Finder", action: #selector(menuReveal(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Copy Path", action: #selector(menuCopyPath(_:)), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Remove from Shelf", action: #selector(menuDelete(_:)), keyEquivalent: "")
        for entry in menu.items { entry.representedObject = item; entry.target = self }
        return menu
    }

    // MARK: - Actions

    @objc private func searchChanged() { reloadItems() }

    @objc private func tabClicked(_ sender: KindTabButton) {
        selectedKind = sender.kind
        tabBar.arrangedSubviews.compactMap { $0 as? KindTabButton }.forEach { restyle($0, selected: $0.kind == selectedKind) }
        reloadItems()
    }

    @objc private func rowActivated(_ sender: NotchRowView) { open(sender.item) }

    @objc private func menuOpen(_ sender: NSMenuItem) { open(sender.representedObject as! ShelfItem) }
    @objc private func menuReveal(_ sender: NSMenuItem) { FinderActions.reveal(sender.representedObject as! ShelfItem) }
    @objc private func menuCopyPath(_ sender: NSMenuItem) { FinderActions.copyPath(sender.representedObject as! ShelfItem) }
    @objc private func menuDelete(_ sender: NSMenuItem) {
        let item = sender.representedObject as! ShelfItem
        delegate?.notchDelete(item)
        reloadItems()
        reloadTabs()
    }

    private func open(_ item: ShelfItem) { onOpen?(item) ?? FinderActions.open(item) }

    private func restyle(_ button: NSButton, selected: Bool) {
        button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
    }
}

/// y-down coordinate view: rows are laid out from the top edge.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    private static let rowHeight: CGFloat = 36
    private static let rowGap: CGFloat = 4

    override func layout() {
        super.layout()
        for (index, row) in subviews.compactMap({ $0 as? NotchRowView }).enumerated() {
            let y = CGFloat(index) * (Self.rowHeight + Self.rowGap)
            row.frame = CGRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight)
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: CGFloat(subviews.count) * Self.rowHeight + max(0, CGFloat(subviews.count - 1)) * Self.rowGap)
    }
}

/// One row: kind icon, title, relative age. A control so a click is an action.
final class NotchRowView: NSControl {
    let item: ShelfItem
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")

    init(item: ShelfItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.045).cgColor

        iconView.image = NSImage(systemSymbolName: Self.symbol(for: item.kind), accessibilityDescription: nil)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
        ])

        titleLabel.stringValue = item.title
        titleLabel.font = .systemFont(ofSize: 12.5)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        dateLabel.stringValue = formatter.localizedString(for: item.lastUsedAt, relativeTo: Date())
        dateLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        dateLabel.textColor = .tertiaryLabelColor
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dateLabel)
        NSLayoutConstraint.activate([
            dateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            dateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityLabel("Shelf item \(item.title)")
    }
    required init?(coder: NSCoder) { return nil }

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.045).cgColor }

    private static func symbol(for kind: ItemKind) -> String {
        switch kind {
        case .file: return "doc"
        case .note: return "note.text"
        case .clipboard: return "doc.on.doc"
        case .bookmark: return "link"
        }
    }
}

/// A kind tab: a recessed button that carries its `ItemKind` (nil = All).
final class KindTabButton: NSButton {
    let kind: ItemKind?
    init(kind: ItemKind?, title: String) {
        self.kind = kind
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .recessed
        controlSize = .small
        setButtonType(.pushOnPushOff)
    }
    required init?(coder: NSCoder) { return nil }
}

/// Bridges `ShelfStore` into the notch content's delegate so the view never
/// depends on the store directly (and can be tested with a stub).
final class NotchStoreBridge: NotchContentStoreDelegate {
    private let store: ShelfStore
    init(store: ShelfStore) { self.store = store }

    func notchItems(for kind: ItemKind?) -> [ShelfItem] {
        store.items
            .filter { kind == nil || $0.kind == kind }
            .sorted { if $0.pinned != $1.pinned { return $0.pinned }; return $0.lastUsedAt > $1.lastUsedAt }
    }

    func notchDelete(_ item: ShelfItem) {
        store.remove(id: item.id)
        _ = store.save()
    }
}
