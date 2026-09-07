import AppKit
import Foundation

enum SmartSection: String, CaseIterable { case pinned = "Pinned", recent = "Recent", downloads = "Downloads", screenshots = "Screenshots", project = "Project" }

struct SmartSectionResolver {
    static func items(for section: SmartSection, store: ShelfStore, projectURL: URL? = nil, limit: Int = 40) -> [ShelfItem] {
        switch section {
        case .pinned: return store.items.filter(\.pinned).sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(limit).map { $0 }
        case .recent: return store.items.sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(limit).map { $0 }
        case .downloads: return files(in: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0], store: store, limit: limit, recursive: false)
        case .screenshots:
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            return files(in: desktop, store: store, limit: limit, recursive: false).filter { $0.title.localizedCaseInsensitiveContains("screenshot") || $0.title.localizedCaseInsensitiveContains("screen shot") }
        case .project: guard let projectURL else { return [] }; return files(in: projectURL, store: store, limit: limit, recursive: false)
        }
    }

    /// Lists a folder's most recently modified entries.
    ///
    /// Performance contract, learned from a live runaway: this runs on a timer
    /// and on every Downloads change, against whatever the user's folder holds
    /// — a few entries today, thousands tomorrow. It must therefore:
    /// - **not recurse** for the smart sections (the Dock shows top-level
    ///    Downloads; screenshots land on the Desktop's top level) — a
    ///    recursive walk of a real Downloads folder descends into everything;
    /// - **never call `standardizedFileURL`** — it performs a reachability
    ///    syscall (`faccessat`) *per file*, which on a big folder is the
    ///    difference between an idle shelf and a pegged CPU;
    /// - **cap the scan** even when recursion is asked for, and materialize
    ///    `ShelfItem`s only for the `limit` newest entries.
    private static func files(in folder: URL, store: ShelfStore, limit: Int, recursive: Bool = false) -> [ShelfItem] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: options) else { return [] }
        // Values are prefetched by the enumerator (one pass, no per-file
        // syscalls); the hard cap bounds even a recursive walk.
        let scanCap = recursive ? 20_000 : 8_000
        // Bounded consumption: pull at most `scanCap` entries *out of the
        // enumerator* and stop. The previous version streamed the whole
        // sequence through compactMap first — on a big folder that
        // materialized every entry into an array before the cap applied,
        // churning hundreds of MB per scan pass.
        var collected: [(url: URL, modified: Date)] = []
        collected.reserveCapacity(512)
        while collected.count < scanCap, let entry = enumerator.nextObject() as? URL {
            guard let values = try? entry.resourceValues(forKeys: keys),
                  values.isRegularFile == true || values.isDirectory == true else { continue }
            collected.append((entry, values.contentModificationDate ?? .distantPast))
        }
        let newest = collected
            .sorted { $0.modified > $1.modified }
            .prefix(limit)
        return newest.map { entry in
            let path = entry.url.path
            if let existing = store.items.first(where: { $0.path == path }) { return existing }
            return ShelfItem(kind: .file, title: entry.url.lastPathComponent, path: path,
                             createdAt: entry.modified, lastUsedAt: entry.modified)
        }
    }
}
