import Foundation

enum ItemKind: String, Codable, CaseIterable { case file, note, clipboard, bookmark }
enum StorageMode: String, Codable { case reference, copy }
enum ShelfAction: String, Codable { case opened, copied, pinned, removed, renamed, moved, compressed, shared }

struct ShelfItem: Codable, Equatable {
    var id: String = UUID().uuidString
    var kind: ItemKind
    var title: String
    var path: String?
    var text: String?
    var urlString: String?
    var createdAt: Date = Date()
    var lastUsedAt: Date = Date()
    var pinned = false
    var storageMode: StorageMode = .reference
    var sourcePath: String?
    var haystack: String { [title, path ?? "", text ?? "", urlString ?? ""].joined(separator: "\n").lowercased(with: Locale.current) }
    static func == (lhs: ShelfItem, rhs: ShelfItem) -> Bool { lhs.id == rhs.id }
}

struct ShelfHistoryEntry: Codable, Equatable { var id = UUID().uuidString; var itemID: String; var action: ShelfAction; var date = Date() }

final class ShelfStore {
    private(set) var items: [ShelfItem] = []
    private(set) var history: [ShelfHistoryEntry] = []
    let fileURL: URL
    var limitPerKind: [ItemKind: Int] = [.file: 200, .note: 100, .clipboard: 50, .bookmark: 100]
    var historyLimit = 500 { didSet { trimHistory() } }
    private var pathIndex: [String: String] = [:]
    private var urlIndex: [String: String] = [:]
    private var textIndex: [String: String] = [:]
    private var searchCache: [String: [ShelfItem]] = [:]
    /// Bumped on every mutation. Lets the view layer skip a full rebuild when
    /// a periodic refresh finds nothing has actually changed.
    private(set) var revision = 0

    init(fileURL: URL, loadImmediately: Bool = true) { self.fileURL = fileURL; if loadImmediately { _ = load() } }
    private struct Persisted: Codable { var items: [ShelfItem]; var history: [ShelfHistoryEntry] }

    @discardableResult
    func load() -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return false }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let persisted = try? decoder.decode(Persisted.self, from: data) { items = persisted.items; history = persisted.history }
        else if let legacy = try? decoder.decode([ShelfItem].self, from: data) { items = legacy; history = [] }
        else { return false }
        rebuildIndexes(); housekeeping(); trimHistory(); return true
    }

    @discardableResult
    func save() -> Bool { do { try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true); let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(Persisted(items: items, history: history)).write(to: fileURL, options: .atomic); return true } catch { return false } }

    @discardableResult
    func add(_ item: ShelfItem, action: ShelfAction? = nil) -> Bool {
        guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let existing = findDuplicate(of: item) { touch(id: existing.id); return false }
        items.append(item); index(item); invalidateSearch(); if let action { record(itemID: item.id, action: action) }; housekeeping(); return true
    }
    func touch(id: String, action: ShelfAction? = nil) { guard let index = items.firstIndex(where: { $0.id == id }) else { return }; items[index].lastUsedAt = Date(); invalidateSearch(); if let action { record(itemID: id, action: action) } }
    func remove(id: String) { guard items.contains(where: { $0.id == id }) else { return }; items.removeAll { $0.id == id }; rebuildIndexes(); record(itemID: id, action: .removed); invalidateSearch() }
    func item(id: String) -> ShelfItem? { items.first { $0.id == id } }
    func togglePin(id: String) { guard let i = items.firstIndex(where: { $0.id == id }) else { return }; items[i].pinned.toggle(); items[i].lastUsedAt = Date(); record(itemID: id, action: .pinned); invalidateSearch() }
    func setText(id: String, text: String) { guard let i = items.firstIndex(where: { $0.id == id }) else { return }; items[i].text = text; items[i].title = Self.title(forText: text); items[i].lastUsedAt = Date(); rebuildIndexes(); invalidateSearch() }
    func rename(id: String, title: String, path: String? = nil) { guard let i = items.firstIndex(where: { $0.id == id }), !title.isEmpty else { return }; items[i].title = title; if let path { items[i].path = path }; items[i].lastUsedAt = Date(); rebuildIndexes(); record(itemID: id, action: .renamed); invalidateSearch() }
    func clear(kind: ItemKind, keepPinned: Bool = true) { let removed = items.filter { $0.kind == kind && !(keepPinned && $0.pinned) }.map(\.id); items.removeAll { $0.kind == kind && !(keepPinned && $0.pinned) }; rebuildIndexes(); removed.forEach { record(itemID: $0, action: .removed) }; invalidateSearch() }
    func record(itemID: String, action: ShelfAction) { history.insert(ShelfHistoryEntry(itemID: itemID, action: action), at: 0); trimHistory() }

    func housekeeping() { var changed = false; for kind in ItemKind.allCases { guard let limit = limitPerKind[kind] else { continue }; if limit <= 0 { let before = items.count; items.removeAll { $0.kind == kind && !$0.pinned }; changed = changed || before != items.count; continue }; let ordered = displayOrder(kind: kind, query: ""); guard ordered.count > limit else { continue }; let survivors = Set(ordered.prefix(limit).map(\.id)); let before = items.count; items.removeAll { $0.kind == kind && !survivors.contains($0.id) }; changed = changed || before != items.count }; if changed { rebuildIndexes(); invalidateSearch() } }

    func displayOrder(kind: ItemKind, query: String) -> [ShelfItem] { let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: Locale.current); let key = "\(kind.rawValue)|\(needle)"; if let cached = searchCache[key] { return cached }; let result = items.lazy.filter { $0.kind == kind && (needle.isEmpty || $0.haystack.contains(needle)) }.sorted { if $0.pinned != $1.pinned { return $0.pinned }; if $0.lastUsedAt != $1.lastUsedAt { return $0.lastUsedAt > $1.lastUsedAt }; return $0.id < $1.id }; searchCache[key] = result; return result }
    func searchAll(_ query: String) -> [ShelfItem] { let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: Locale.current); let key = "all|\(needle)"; if let cached = searchCache[key] { return cached }; let result = items.filter { needle.isEmpty || $0.haystack.contains(needle) }.sorted { if $0.pinned != $1.pinned { return $0.pinned }; return $0.lastUsedAt > $1.lastUsedAt }; searchCache[key] = result; return result }

    private func invalidateSearch() { searchCache.removeAll(keepingCapacity: true); revision &+= 1 }
    private func trimHistory() { let count = max(0, historyLimit); if history.count > count { history.removeLast(history.count - count) } }
    private func normalized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
    private func index(_ item: ShelfItem) { if let path = item.path, !path.isEmpty { pathIndex[normalized(path)] = item.id }; if let url = item.urlString, !url.isEmpty { urlIndex[url] = item.id }; if let text = item.text, !text.isEmpty { textIndex["\(item.kind.rawValue)|\(text)"] = item.id } }
    private func rebuildIndexes() { pathIndex.removeAll(keepingCapacity: true); urlIndex.removeAll(keepingCapacity: true); textIndex.removeAll(keepingCapacity: true); items.forEach(index) }
    private func findDuplicate(of item: ShelfItem) -> ShelfItem? { if let path = item.path, !path.isEmpty, let id = pathIndex[normalized(path)] { return self.item(id: id) }; if let url = item.urlString, !url.isEmpty, let id = urlIndex[url] { return self.item(id: id) }; if let text = item.text, !text.isEmpty, let id = textIndex["\(item.kind.rawValue)|\(text)"] { return self.item(id: id) }; return nil }
    static func title(forText text: String) -> String { let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "Empty note"; let trimmed = first.trimmingCharacters(in: .whitespaces); if trimmed.isEmpty { return "Empty note" }; return trimmed.count <= 60 ? trimmed : String(trimmed.prefix(59)) + "…" }
}
