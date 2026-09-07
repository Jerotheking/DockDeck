import AppKit
import Carbon.HIToolbox

/// What a shelf holds. The two shelves flank the Dock and carry different
/// material, mirroring Dockside's split: things you put there, and things the
/// system produced for you.
enum ShelfRole: String, Codable {
    /// Files, notes, clipboard history, links — everything the user drops.
    case library
    /// Recent screenshots and downloads, gathered automatically.
    case recents

    var title: String { self == .library ? "Shelf" : "Recents" }
    var symbol: String { self == .library ? "tray.full" : "clock.arrow.circlepath" }
}

/// Contents of one shelf, laid out for whichever state its panel is in.
///
/// Two layouts, not one that stretches:
/// - **collapsed** — a strip only as thick as the Dock. Icons at the Dock's tile
///   size, stacked along the strip. No text: there is no room for any.
/// - **expanded** — a full vertical layout with search, tabs, and rows.
///
/// The switch is a crossfade rather than a reflow, because reflowing a list into
/// a 53-point strip produces a frame of garbage on the way through.
final class ShelfViewController: NSViewController, NSSearchFieldDelegate {
    let role: ShelfRole
    let store: ShelfStore
    let settingsStore: SettingsStore
    weak var panel: ShelfPanel?

    private var presentation: ShelfPanel.State = .collapsed
    private var stripIsVertical = true
    private var tileSize: CGFloat = 39

    // Collapsed
    private let collapsedHost = NSView()
    private let collapsedScroll = NSScrollView()
    private let collapsedStack = NSStackView()
    private let overflowLabel = NSTextField(labelWithString: "")

    // Expanded
    private let expandedContainer = NSView()
    /// The expanded layout is added to and removed from this view rather than
    /// merely hidden. A hidden subtree still contributes its constraints, and
    /// AppKit sizes a window to its content view's fitting size — so leaving the
    /// expanded layout mounted forced the *collapsed* shelf to 193 pt wide
    /// instead of the Dock's 53 pt. Measured, not guessed: `chromeFittingSize`
    /// in the diagnostics report.
    private weak var expandedHost: NSView?
    private let titleLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let tabBar = NSSegmentedControl(labels: ["Files", "Notes", "Clipboard", "Links"], trackingMode: .selectOne, target: nil, action: nil)
    private let listScroll = NSScrollView()
    private let listStack = NSStackView()
    private let newNoteButton = NSButton(title: "＋ Note", target: nil, action: nil)
    private let commandButton = NSButton(title: "⌘", target: nil, action: nil)

    private var tab: ItemKind = .file
    private var query = ""
    private var lastRenderedRevision = -1
    private var lastRenderedKey = ""
    private var lastPasteboardChange: Int
    private var clipboardTimer: Timer?
    private var recentsTimer: Timer?
    /// Coalescing state for recents scans (learned from a live runaway): a
    /// debounced request, an in-flight flag, and a trailing marker so scans
    /// never stack — a burst of Downloads events costs exactly one scan.
    private var recentsScanWork: DispatchWorkItem?
    private var recentsScanInFlight = false
    private var recentsScanDirty = false
    private var searchWorkItem: DispatchWorkItem?
    private var pendingSaveWorkItem: DispatchWorkItem?
    private var monitor: WorkspaceMonitor?
    private var commandMonitor: Any?
    private var trackingArea: NSTrackingArea?
    private let quickLook = QuickLookPreviewController()
    private let commandPalette = CommandPaletteController()
    private let projectStore: ProjectContextStore
    private var recentsCache: [ShelfItem] = []

    init(role: ShelfRole, store: ShelfStore, settingsStore: SettingsStore, projectStore: ProjectContextStore) {
        self.role = role
        self.store = store
        self.settingsStore = settingsStore
        self.projectStore = projectStore
        lastPasteboardChange = NSPasteboard.general.changeCount
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { return nil }

    // MARK: - View

    override func loadView() {
        let container = DropRootView()
        container.onDragEnter = { [weak self] in self?.panel?.expand() }
        container.onDragExit = { [weak self] in self?.panel?.scheduleCollapse() }
        container.onDrop = { [weak self] info in self?.handleDrop(info) ?? false }
        container.onPointerEnter = { [weak self] in
            guard let self, self.settingsStore.settings.expandOnHover else { return }
            self.panel?.expand()
        }
        container.onPointerExit = { [weak self] in self?.panel?.scheduleCollapse() }
        container.translatesAutoresizingMaskIntoConstraints = false
        container.registerForDraggedTypes([.fileURL, .URL, .string])

        buildCollapsed(in: container)
        buildExpanded(in: container)
        expandedHost = container
        view = container
        applyPresentation(animated: false)
        reload(force: true)
    }

    private func buildCollapsed(in container: NSView) {
        collapsedHost.translatesAutoresizingMaskIntoConstraints = true
        collapsedHost.autoresizingMask = [.width, .height]
        collapsedHost.frame = container.bounds
        container.addSubview(collapsedHost)
        collapsedStack.spacing = 3
        collapsedStack.alignment = .centerX
        collapsedStack.translatesAutoresizingMaskIntoConstraints = false

        collapsedScroll.drawsBackground = false
        collapsedScroll.hasVerticalScroller = false
        collapsedScroll.hasHorizontalScroller = false
        collapsedScroll.automaticallyAdjustsContentInsets = false
        collapsedScroll.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(collapsedStack)
        collapsedScroll.documentView = document
        collapsedHost.addSubview(collapsedScroll)

        overflowLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        overflowLabel.textColor = .tertiaryLabelColor
        overflowLabel.alignment = .center
        overflowLabel.translatesAutoresizingMaskIntoConstraints = false
        collapsedHost.addSubview(overflowLabel)

        NSLayoutConstraint.activate([
            collapsedScroll.topAnchor.constraint(equalTo: collapsedHost.topAnchor, constant: 5),
            collapsedScroll.leadingAnchor.constraint(equalTo: collapsedHost.leadingAnchor),
            collapsedScroll.trailingAnchor.constraint(equalTo: collapsedHost.trailingAnchor),
            collapsedScroll.bottomAnchor.constraint(equalTo: overflowLabel.topAnchor, constant: -2),
            overflowLabel.leadingAnchor.constraint(equalTo: collapsedHost.leadingAnchor),
            overflowLabel.trailingAnchor.constraint(equalTo: collapsedHost.trailingAnchor),
            overflowLabel.bottomAnchor.constraint(equalTo: collapsedHost.bottomAnchor, constant: -3),
            collapsedStack.topAnchor.constraint(equalTo: document.topAnchor),
            collapsedStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            collapsedStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            collapsedStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: collapsedScroll.widthAnchor)
        ])
    }

    private func buildExpanded(in container: NSView) {
        // Autoresizing, not constraints: the expanded layout needs ~190 pt of
        // width, and as an Auto Layout child that minimum would propagate up and
        // force the *collapsed* window to 190 pt too — the shelf would no longer
        // be as thin as the Dock. Sized by mask, its constraints stay internal.
        expandedContainer.translatesAutoresizingMaskIntoConstraints = true
        expandedContainer.autoresizingMask = [.width, .height]
        expandedContainer.frame = container.bounds

        titleLabel.stringValue = role.title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        expandedContainer.addSubview(titleLabel)

        searchField.placeholderString = role == .library ? "Search shelf…" : "Search recents…"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 12)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        expandedContainer.addSubview(searchField)

        tabBar.selectedSegment = 0
        tabBar.target = self
        tabBar.action = #selector(tabChanged)
        tabBar.controlSize = .small
        tabBar.font = .systemFont(ofSize: 10, weight: .semibold)
        tabBar.isHidden = role != .library
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        expandedContainer.addSubview(tabBar)

        newNoteButton.bezelStyle = .rounded
        newNoteButton.controlSize = .small
        newNoteButton.font = .systemFont(ofSize: 10, weight: .semibold)
        newNoteButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        newNoteButton.imagePosition = .imageLeading
        newNoteButton.target = self
        newNoteButton.action = #selector(newNote)
        newNoteButton.isHidden = role != .library
        newNoteButton.setAccessibilityLabel("New note")
        newNoteButton.translatesAutoresizingMaskIntoConstraints = false
        expandedContainer.addSubview(newNoteButton)

        commandButton.isBordered = false
        commandButton.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Command palette")?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        commandButton.imagePosition = .imageOnly
        commandButton.contentTintColor = .secondaryLabelColor
        commandButton.target = self
        commandButton.action = #selector(showCommands)
        commandButton.toolTip = "Open command palette (⌘⌥P)"
        commandButton.setAccessibilityLabel("Open command palette")
        commandButton.translatesAutoresizingMaskIntoConstraints = false
        expandedContainer.addSubview(commandButton)

        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)
        listScroll.documentView = document
        expandedContainer.addSubview(listScroll)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: expandedContainer.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 12),
            commandButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            commandButton.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor, constant: -10),
            commandButton.widthAnchor.constraint(equalToConstant: 26),

            searchField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor, constant: -10),

            tabBar.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 7),
            tabBar.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 10),
            tabBar.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor, constant: -10),

            newNoteButton.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 7),
            newNoteButton.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 10),

            listScroll.topAnchor.constraint(equalTo: newNoteButton.bottomAnchor, constant: 7),
            listScroll.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: expandedContainer.bottomAnchor, constant: -6),

            listStack.topAnchor.constraint(equalTo: document.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            listStack.widthAnchor.constraint(equalTo: listScroll.widthAnchor),
            listStack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
    }

    // MARK: - Dock-driven layout

    /// Adopts the Dock's current shape: the strip's axis decides how collapsed
    /// tiles stack, and the Dock's thickness decides how big they are, so the
    /// shelf's icons line up with the Dock's.
    func apply(dock: DockGeometry) {
        stripIsVertical = dock.orientation != .bottom
        tileSize = max(24, dock.thickness - 14)
        collapsedStack.orientation = stripIsVertical ? .vertical : .horizontal
        collapsedStack.alignment = stripIsVertical ? .centerX : .centerY
        reload(force: true)
    }

    func setPresentation(_ state: ShelfPanel.State, animated: Bool) {
        guard presentation != state else { return }
        presentation = state
        applyPresentation(animated: animated)
        reload(force: true)
    }

    /// Crossfade rather than reflow. The two layouts have nothing in common, so
    /// animating between them would show a frame of collapsed-width rows.
    ///
    /// WS-2 rewrote the *expansion* leg: the panel calls `beginExpansionFrom`
    /// before its spring starts, so the expanded layout is mounted, rendered,
    /// and fully opaque at the spring's first frame — content grows with the
    /// glass instead of arriving after it. The old 80 ms delay + fade produced
    /// the "empty drawer" frame the audit measured (B3). Collapse keeps a
    /// short fade: disappearing content may soften, appearing content may not.
    private func applyPresentation(animated: Bool) {
        let expanded = presentation == .expanded
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if expanded { mountExpanded() }

        guard animated && !reduceMotion else {
            expandedContainer.alphaValue = expanded ? 1 : 0
            collapsedHost.isHidden = expanded
            collapsedHost.alphaValue = expanded ? 0 : 1
            if !expanded { unmountExpanded() }
            return
        }

        if expanded {
            // WS-2, frame one: fully present. The arrivals carry all the
            // entrance motion — content fading in *while* growing reads as
            // two clocks anyway.
            collapsedHost.isHidden = true
            collapsedHost.alphaValue = 0
            expandedContainer.alphaValue = 1
            animateRowArrivals()
            return
        }

        collapsedHost.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            collapsedHost.animator().alphaValue = 1
            expandedContainer.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            if self.presentation != .expanded {
                self.collapsedHost.isHidden = false
                self.unmountExpanded()
            }
        }
    }

    /// Called by the panel *before* its expansion spring takes its first
    /// step (WS-2): adopt the frame the shelf has right now, mount the
    /// expanded layout, and render it — so when the window's next frame
    /// arrives the content is already there. Also bypasses the reload()
    /// presentation guard so a transition queued inside the spring's first
    /// frame can never blank the list again.
    func beginExpansionFrom(currentFrame: CGRect) {
        presentation = .expanded
        expandedContainer.frame = currentFrame
        mountExpanded()
        lastRenderedKey = "" // force the next reload to run
        reload(force: true)
    }

    /// Staggered spring entrance for the expanded list: rows travel in from
    /// the Dock-facing edge (down from a bottom Dock, from the left for a
    /// right Dock, from the right for a left Dock) with a slight scale-up and
    /// fade. AppKit rows need views, so each row gets its own layer-backed
    /// host transform; the stagger is 45 ms per row, capped so long lists do
    /// not turn the whole reveal into a slow parade.
    private func animateRowArrivals() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        guard let panelDock = panel?.dock.orientation else { return }
        let rows = listStack.arrangedSubviews.prefix(8)
        for (index, row) in rows.enumerated() {
            row.wantsLayer = true
            let offset: CGSize
            switch panelDock {
            case .bottom: offset = CGSize(width: 0, height: 14)
            case .right: offset = CGSize(width: -10, height: 0)
            case .left: offset = CGSize(width: 10, height: 0)
            }
            row.layer?.add(MaterialLayerStyles.makeArrival(offset: offset, index: index),
                           forKey: "rowArrival")
        }
    }

    private func mountExpanded() {
        guard expandedContainer.superview == nil, let host = expandedHost else { return }
        expandedContainer.frame = host.bounds
        host.addSubview(expandedContainer)
    }

    private func unmountExpanded() {
        guard presentation != .expanded else { return }
        expandedContainer.removeFromSuperview()
    }

    // MARK: - Services

    func startServices() {
        applySettings()
        commandMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .option], event.keyCode == 35 {
                self?.showCommands()
                return nil
            }
            return event
        }
    }

    func applySettings() {
        let values = settingsStore.settings
        store.limitPerKind = [.file: values.fileLimit, .note: values.noteLimit, .clipboard: values.clipboardLimit, .bookmark: 100]

        // Only the library shelf watches the pasteboard, and only while the
        // feature is on: there is no change notification for it, so the timer is
        // the cost of the feature and should not run when it is off.
        let wantsClipboard = role == .library && values.monitorClipboard
        if wantsClipboard, clipboardTimer == nil {
            let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in self?.pollClipboard() }
            RunLoop.main.add(timer, forMode: .common)
            clipboardTimer = timer
        } else if !wantsClipboard {
            clipboardTimer?.invalidate(); clipboardTimer = nil
        }

        let wantsDownloads = values.monitorDownloads && role == .recents
        if wantsDownloads, monitor == nil {
            let watcher = WorkspaceMonitor()
            watcher.onChange = { [weak self] in self?.refreshRecents() }
            watcher.start()
            monitor = watcher
        } else if !wantsDownloads {
            monitor?.stop(); monitor = nil
        }

        if role == .recents, recentsTimer == nil {
            // Screenshots land on the Desktop, which the Downloads watcher does
            // not cover; a slow poll is enough for a shelf you glance at.
            let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.refreshRecents() }
            RunLoop.main.add(timer, forMode: .common)
            recentsTimer = timer
            refreshRecents()
        }
    }

    func stopServices() {
        clipboardTimer?.invalidate(); clipboardTimer = nil
        recentsTimer?.invalidate(); recentsTimer = nil
        recentsScanWork?.cancel(); recentsScanWork = nil
        recentsScanInFlight = false
        recentsScanDirty = false
        searchWorkItem?.cancel(); searchWorkItem = nil
        pendingSaveWorkItem?.cancel(); pendingSaveWorkItem = nil
        monitor?.stop(); monitor = nil
        if let commandMonitor { NSEvent.removeMonitor(commandMonitor); self.commandMonitor = nil }
        quickLook.dismiss()
        if role == .library { _ = store.save() }
    }

    private func refreshRecents() {
        // The timer fires every 20 s and every Downloads change fires again;
        // each scan touches thousands of entries. Overlapping passes stack
        // into a multi-core burn with RSS churn. So: debounce (a burst costs
        // one scan 0.75 s after the last request), never run two scans at
        // once, and run one trailing pass when a request lands mid-scan.
        recentsScanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runRecentsScan() }
        recentsScanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    private func runRecentsScan() {
        recentsScanWork = nil
        guard !recentsScanInFlight else { recentsScanDirty = true; return }
        let limit = settingsStore.settings.smartLimit
        let showScreenshots = settingsStore.settings.monitorScreenshots
        let showDownloads = settingsStore.settings.monitorDownloads
        // Filesystem enumeration off the main thread: the Downloads folder can
        // hold thousands of entries, and this runs on a timer.
        recentsScanInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var items: [ShelfItem] = []
            if showScreenshots { items += SmartSectionResolver.items(for: .screenshots, store: self.store, limit: limit) }
            if showDownloads { items += SmartSectionResolver.items(for: .downloads, store: self.store, limit: limit) }
            let ordered = Array(items.sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(limit))
            DispatchQueue.main.async {
                self.recentsScanInFlight = false
                if self.recentsScanDirty {
                    self.recentsScanDirty = false
                    self.refreshRecents()
                }
                guard self.recentsCache.map(\.id) != ordered.map(\.id) else { return }
                self.recentsCache = ordered
                self.reload(force: true)
            }
        }
    }

    // MARK: - Content

    private func currentItems() -> [ShelfItem] {
        switch role {
        case .recents:
            guard !query.isEmpty else { return recentsCache }
            return recentsCache.filter { $0.haystack.contains(query.lowercased(with: Locale.current)) }
        case .library:
            return query.isEmpty ? store.displayOrder(kind: tab, query: "") : store.searchAll(query).filter { $0.kind == tab }
        }
    }

    private func reload(force: Bool) {
        let key = "\(role.rawValue)|\(tab.rawValue)|\(query)|\(presentation)|\(tileSize)"
        if !force, store.revision == lastRenderedRevision, key == lastRenderedKey { return }
        lastRenderedRevision = store.revision
        lastRenderedKey = key

        let items = currentItems()
        if presentation == .expanded { renderRows(items) } else { renderTiles(items) }
    }

    private func renderTiles(_ items: [ShelfItem]) {
        collapsedStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Only as many tiles as physically fit; the rest are reported as a count
        // rather than being silently dropped.
        let available = stripIsVertical ? view.bounds.height - 18 : view.bounds.width - 18
        let capacity = max(1, Int(available / (tileSize + 3)))
        let shown = items.prefix(capacity)
        for item in shown {
            collapsedStack.addArrangedSubview(ShelfTileView(
                item: item,
                tileSize: tileSize,
                onOpen: { [weak self] in self?.openItem($0) },
                onPreview: { [weak self] in self?.preview($0) }
            ))
        }
        let hidden = items.count - shown.count
        overflowLabel.stringValue = hidden > 0 ? "+\(hidden)" : ""
        if items.isEmpty {
            let glyph = NSImageView(image: NSImage(systemSymbolName: role.symbol, accessibilityDescription: role.title) ?? NSImage())
            glyph.contentTintColor = .tertiaryLabelColor
            glyph.translatesAutoresizingMaskIntoConstraints = false
            collapsedStack.addArrangedSubview(glyph)
            NSLayoutConstraint.activate([
                glyph.widthAnchor.constraint(equalToConstant: tileSize * 0.6),
                glyph.heightAnchor.constraint(equalToConstant: tileSize * 0.6)
            ])
        }
    }

    private func renderRows(_ items: [ShelfItem]) {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        defer { animateRowArrivals() }
        guard !items.isEmpty else { addEmptyState(); return }
        for item in items {
            let row = ShelfRowView(
                item: item,
                onOpen: { [weak self] in self?.openItem($0) },
                onPin: { [weak self] in self?.pinItem($0) },
                onCopy: { [weak self] in self?.copyItem($0) },
                onDelete: { [weak self] in self?.deleteItem($0) },
                onMarkdown: { MarkdownExport.copy($0) },
                onPreview: { [weak self] in self?.preview($0) },
                onReveal: { FinderActions.reveal($0) },
                onShare: { [weak self] in guard let self else { return }; FinderActions.share($0, from: self.view) },
                onRename: { [weak self] in self?.rename($0) },
                onCompress: { [weak self] item in
                    FinderActions.compress(item) { success in
                        guard let self else { return }
                        if success { self.store.touch(id: item.id, action: .compressed); self.saveSoon() }
                        else { self.report("Could not compress “\(item.title)”.", detail: "The archive may already exist, or the location is not writable.") }
                    }
                }
            )
            // Add before constraining against listStack: a constraint between
            // views with no common ancestor raises an NSException that AppKit
            // swallows mid-callback, which used to abort the entire launch.
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 38).isActive = true
        }
    }

    private func addEmptyState() {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: emptySymbol, accessibilityDescription: emptyMessage) ?? NSImage())
        icon.contentTintColor = .tertiaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(wrappingLabelWithString: emptyMessage)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(icon); wrap.addSubview(label)
        listStack.addArrangedSubview(wrap)
        NSLayoutConstraint.activate([
            wrap.widthAnchor.constraint(equalTo: listStack.widthAnchor),
            wrap.heightAnchor.constraint(equalToConstant: 110),
            icon.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            icon.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 20),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            label.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 8)
        ])
    }

    private var emptyMessage: String {
        switch role {
        case .recents: return "Recent screenshots and downloads show up here."
        case .library:
            switch tab {
            case .file: return "Drag files and folders here."
            case .note: return "No notes yet. Create one with ＋ Note."
            case .clipboard: return "Clipboard history fills up as you copy."
            case .bookmark: return "No saved links."
            }
        }
    }

    private var emptySymbol: String {
        switch role {
        case .recents: return "clock.arrow.circlepath"
        case .library:
            switch tab {
            case .file: return "tray"
            case .note: return "note.text"
            case .clipboard: return "doc.on.clipboard"
            case .bookmark: return "link"
            }
        }
    }

    // MARK: - Actions

    @objc private func tabChanged() { tab = [.file, .note, .clipboard, .bookmark][max(0, min(3, tabBar.selectedSegment))]; reload(force: true) }

    func controlTextDidChange(_ obj: Notification) {
        query = searchField.stringValue
        searchWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload(force: true) }
        searchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    @objc func newNote() {
        guard role == .library else { return }
        panel?.expand()
        let note = ShelfItem(kind: .note, title: "New note", text: "")
        store.add(note)
        saveSoon()
        tab = .note
        tabBar.selectedSegment = 1
        reload(force: true)
        editNote(note)
    }

    private func pollClipboard() {
        guard settingsStore.settings.monitorClipboard else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastPasteboardChange else { return }
        lastPasteboardChange = pb.changeCount
        guard let text = pb.string(forType: .string), !text.isEmpty else { return }
        store.add(ShelfItem(kind: .clipboard, title: ShelfStore.title(forText: text), text: text), action: .copied)
        saveSoon()
        reload(force: false)
    }

    private func saveSoon() {
        pendingSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.store.save() }
        pendingSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    @objc private func showCommands() {
        panel?.expand()
        panel?.isBusy = true
        commandPalette.present(commands: [
            ShelfCommand(title: "New Note", shortcut: "⌘N") { [weak self] in self?.newNote() },
            ShelfCommand(title: "Show Files", shortcut: "1") { [weak self] in self?.select(tab: .file, segment: 0) },
            ShelfCommand(title: "Show Notes", shortcut: "2") { [weak self] in self?.select(tab: .note, segment: 1) },
            ShelfCommand(title: "Show Clipboard", shortcut: "3") { [weak self] in self?.select(tab: .clipboard, segment: 2) },
            ShelfCommand(title: "Show Links", shortcut: "4") { [weak self] in self?.select(tab: .bookmark, segment: 3) },
            ShelfCommand(title: "Copy first item as Markdown", shortcut: "⌥M") { [weak self] in
                guard let item = self?.currentItems().first else { return }
                MarkdownExport.copy(item)
            },
            ShelfCommand(title: "Set current folder as Project", shortcut: "⌥P") { [weak self] in self?.activateProjectFromSelection() }
        ], from: view.window) { [weak self] in self?.panel?.isBusy = false }
    }

    private func select(tab kind: ItemKind, segment: Int) {
        guard role == .library else { return }
        tab = kind
        tabBar.selectedSegment = segment
        reload(force: true)
    }

    private func activateProjectFromSelection() {
        guard let item = currentItems().first, let path = item.path,
              let root = ProjectContextStore.discover(from: URL(fileURLWithPath: path)) else { return }
        _ = projectStore.activate(root)
    }

    private func openItem(_ item: ShelfItem) {
        switch item.kind {
        case .file:
            guard let path = item.path else { return }
            guard FileManager.default.fileExists(atPath: path) else {
                NSSound.beep()
                report("“\(item.title)” is no longer at that location.", detail: path)
                return
            }
            FinderActions.open(item)
            store.touch(id: item.id, action: .opened)
            saveSoon()
        case .note:
            editNote(item)
        case .clipboard:
            copyItem(item)
        case .bookmark:
            // Re-validate: the store is a file on disk and can be hand-edited.
            guard let raw = item.urlString, let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else {
                NSSound.beep(); return
            }
            NSWorkspace.shared.open(url)
            store.touch(id: item.id, action: .opened)
            saveSoon()
        }
    }

    private func preview(_ item: ShelfItem) {
        guard item.kind == .file, let path = item.path, FileManager.default.fileExists(atPath: path) else { NSSound.beep(); return }
        panel?.isBusy = true
        quickLook.preview(URL(fileURLWithPath: path), from: view.window) { [weak self] in self?.panel?.isBusy = false }
    }

    private func editNote(_ item: ShelfItem) {
        guard let window = view.window else { return }
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 120))
        field.string = item.text ?? ""
        field.isRichText = false
        field.font = .systemFont(ofSize: 13)
        let alert = NSAlert()
        alert.messageText = "Note"
        alert.informativeText = item.title
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        panel?.isBusy = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.panel?.isBusy = false
            guard response == .alertFirstButtonReturn else { return }
            self.store.setText(id: item.id, text: field.string)
            self.saveSoon()
            self.reload(force: true)
        }
    }

    private func pinItem(_ item: ShelfItem) { store.togglePin(id: item.id); saveSoon(); reload(force: true) }

    private func copyItem(_ item: ShelfItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if item.kind == .file, let path = item.path {
            pb.writeObjects([NSURL(fileURLWithPath: path)])
            pb.setString(path, forType: .string)
        } else if item.kind == .bookmark {
            pb.setString(item.urlString ?? "", forType: .string)
        } else {
            pb.setString(item.text ?? "", forType: .string)
        }
        lastPasteboardChange = pb.changeCount
        store.touch(id: item.id, action: .copied)
        saveSoon()
    }

    /// Removes the shelf entry only. The file on disk is never touched: the
    /// shelf holds references, so clearing a row must not destroy user data.
    private func deleteItem(_ item: ShelfItem) { store.remove(id: item.id); saveSoon(); reload(force: true) }

    private func rename(_ item: ShelfItem) {
        panel?.isBusy = true
        FinderActions.rename(item, from: view.window) { [weak self] result in
            guard let self else { return }
            self.panel?.isBusy = false
            switch result {
            case .cancelled:
                return
            case .renamed(let path):
                self.store.rename(id: item.id, title: URL(fileURLWithPath: path).lastPathComponent, path: path)
                self.saveSoon()
                self.reload(force: true)
            case .failed(let reason):
                self.report("Could not rename “\(item.title)”.", detail: reason)
            }
        }
    }

    /// Every user-initiated action that can fail says so. Silent failure was the
    /// single largest source of "it did nothing" in this app.
    private func report(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            panel?.isBusy = true
            alert.beginSheetModal(for: window) { [weak self] _ in self?.panel?.isBusy = false }
        } else {
            alert.runModal()
        }
    }

    // MARK: - Drop

    func handleDrop(_ sender: NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            var changed = false
            for url in urls {
                changed = store.add(ShelfItem(kind: .file, title: url.lastPathComponent, path: url.standardizedFileURL.path), action: .opened) || changed
            }
            saveSoon()
            if changed { select(tab: .file, segment: 0); reload(force: true) }
            return changed
        }
        if let raw = sender.draggingPasteboard.string(forType: .URL), let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            let added = store.add(ShelfItem(kind: .bookmark, title: url.host ?? raw, urlString: raw))
            saveSoon()
            if added { select(tab: .bookmark, segment: 3); reload(force: true) }
            return added
        }
        return false
    }
}

/// Root view of a shelf: owns drag-and-drop and pointer tracking for the whole
/// surface, so the panel can expand on hover and on drag without either
/// behaviour depending on which subview happens to be under the pointer.
final class DropRootView: NSView {
    var onDrop: ((NSDraggingInfo) -> Bool)?
    var onDragEnter: (() -> Void)?
    var onDragExit: (() -> Void)?
    var onPointerEnter: (() -> Void)?
    var onPointerExit: (() -> Void)?

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onPointerEnter?() }
    override func mouseExited(with event: NSEvent) { onPointerExit?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { onDragEnter?(); return .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragExit?() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { onDrop?(sender) ?? false }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { onDragExit?() }
}

extension Notification.Name {
    static let dockDeckToggle = Notification.Name("DockDeckToggle")
    static let dockDeckExpandToggle = Notification.Name("DockDeckExpandToggle")
}
