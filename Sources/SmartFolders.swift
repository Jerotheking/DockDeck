import AppKit
import Foundation

enum SmartSection: String, CaseIterable { case pinned = "Pinned", recent = "Recent", downloads = "Downloads", screenshots = "Screenshots", project = "Project" }

struct SmartSectionResolver {
    static func items(for section: SmartSection, store: ShelfStore, projectURL: URL? = nil, limit: Int = 40) -> [ShelfItem] {
        switch section {
        case .pinned: return store.items.filter(\.pinned).sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(limit).map { $0 }
        case .recent: return store.items.sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(limit).map { $0 }
        case .downloads: return files(in: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0], store: store, limit: limit)
        case .screenshots:
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            return files(in: desktop, store: store, limit: limit).filter { $0.title.localizedCaseInsensitiveContains("screenshot") || $0.title.localizedCaseInsensitiveContains("screen shot") }
        case .project: guard let projectURL else { return [] }; return files(in: projectURL, store: store, limit: limit, recursive: false)
        }
    }

    private static func files(in folder: URL, store: ShelfStore, limit: Int, recursive: Bool = true) -> [ShelfItem] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        let candidates = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: options)?.compactMap { $0 as? URL }.filter { recursive || $0.deletingLastPathComponent() == folder } ?? []
        return candidates.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true || values.isDirectory == true else { return nil }
            if let existing = store.items.first(where: { $0.path == url.standardizedFileURL.path }) { return existing }
            return ShelfItem(kind: .file, title: url.lastPathComponent, path: url.standardizedFileURL.path, createdAt: values.contentModificationDate ?? Date(), lastUsedAt: values.contentModificationDate ?? Date())
        }.sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(limit).map { $0 }
    }
}
