import AppKit
import Carbon.HIToolbox

struct ShelfCommand {
    let title: String
    let shortcut: String
    let action: () -> Void
}

/// Keyboard-first command list.
///
/// Deliberately not a child window of the shelf: a child window follows its
/// parent, and the shelf's parent frame moves whenever it expands or collapses,
/// which would drag the palette around mid-typing.
final class CommandPaletteController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var window: NSWindow?
    private let search = NSSearchField()
    private let table = NSTableView()
    private var commands: [ShelfCommand] = []
    private var filtered: [ShelfCommand] = []
    private var onDismiss: (() -> Void)?
    private var keyMonitor: Any?

    func present(commands: [ShelfCommand], from owner: NSWindow?, onDismiss: (() -> Void)? = nil) {
        self.commands = commands
        self.filtered = commands
        self.onDismiss = onDismiss
        if window == nil { buildWindow() }
        search.stringValue = ""
        table.reloadData()
        if table.numberOfRows > 0 { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }

        if let palette = window {
            if let owner {
                // Centre over the shelf's screen rather than the main screen, so
                // the palette appears where the user is looking.
                let screen = owner.screen ?? NSScreen.main
                if let frame = screen?.visibleFrame {
                    palette.setFrameOrigin(NSPoint(x: frame.midX - palette.frame.width / 2,
                                                   y: frame.midY - palette.frame.height / 2))
                } else {
                    palette.center()
                }
            } else {
                palette.center()
            }
            palette.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            palette.makeFirstResponder(search)
        }

        installKeyMonitor()
    }

    private func buildWindow() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
                            styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "DockDeck Commands"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.hidesOnDeactivate = false

        // Same frosted material as the shelves, so the palette reads as part of
        // the same app rather than a stock dialog.
        let chrome = ShelfChromeView()
        chrome.cornerRadius = 10
        chrome.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = chrome

        search.placeholderString = "Type a command…"
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(search)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.title = "Command"
        column.width = 460
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 32
        table.backgroundColor = .clear
        table.style = .inset
        table.target = self
        table.doubleAction = #selector(activateSelected)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(scroll)

        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 34),
            search.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 14),
            search.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -8)
        ])
        window = panel
    }

    /// Esc dismisses, Return runs the selection, arrows move it while the search
    /// field keeps focus — the behaviour a command palette is expected to have.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, window.isKeyWindow else { return event }
            switch Int(event.keyCode) {
            case kVK_Escape:
                self.dismiss(); return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                self.activateSelected(); return nil
            case kVK_DownArrow:
                self.move(by: 1); return nil
            case kVK_UpArrow:
                self.move(by: -1); return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func move(by delta: Int) {
        guard table.numberOfRows > 0 else { return }
        let next = max(0, min(table.numberOfRows - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    func dismiss() {
        window?.orderOut(nil)
        removeKeyMonitor()
        let callback = onDismiss
        onDismiss = nil
        callback?()
    }

    func controlTextDidChange(_ notification: Notification) {
        let query = search.stringValue.lowercased()
        filtered = query.isEmpty ? commands : commands.filter { $0.title.lowercased().contains(query) }
        table.reloadData()
        if table.numberOfRows > 0 { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filtered.count else { return nil }
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: filtered[row].title)
        title.font = .systemFont(ofSize: 13)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        let shortcut = NSTextField(labelWithString: filtered[row].shortcut)
        shortcut.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        shortcut.textColor = .tertiaryLabelColor
        shortcut.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(title)
        cell.addSubview(shortcut)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            shortcut.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            shortcut.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    @objc private func activateSelected() {
        let row = table.selectedRow >= 0 ? table.selectedRow : 0
        guard row < filtered.count else { dismiss(); return }
        let command = filtered[row]
        dismiss()
        command.action()
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
    func windowWillClose(_ notification: Notification) { removeKeyMonitor(); let c = onDismiss; onDismiss = nil; c?() }
    func windowDidResignKey(_ notification: Notification) { dismiss() }
}
