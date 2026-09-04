import Foundation

struct ProjectContext: Codable, Equatable {
    var name: String
    var path: String
    var lastOpenedAt = Date()
}

final class ProjectContextStore {
    let url: URL
    private(set) var contexts: [ProjectContext]
    private(set) var activePath: String?

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([ProjectContext].self, from: data) { contexts = saved } else { contexts = [] }
    }

    @discardableResult
    func save() -> Bool { do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(contexts).write(to: url, options: .atomic); return true } catch { return false } }
    @discardableResult
    func activate(_ url: URL) -> ProjectContext { let normalized = url.standardizedFileURL.path; if let index = contexts.firstIndex(where: { $0.path == normalized }) { contexts[index].lastOpenedAt = Date(); activePath = normalized; _ = save(); return contexts[index] }; let context = ProjectContext(name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent, path: normalized); contexts.insert(context, at: 0); activePath = normalized; _ = save(); return context }
    func deactivate() { activePath = nil }
    func activeContext() -> ProjectContext? { guard let activePath else { return nil }; return contexts.first { $0.path == activePath } }
    func remove(path: String) { contexts.removeAll { $0.path == path }; if activePath == path { activePath = nil }; _ = save() }

    static func discover(from fileURL: URL) -> URL? {
        var candidate = fileURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
        if !exists || !isDirectory.boolValue { candidate = candidate.deletingLastPathComponent() }
        let markers = [".git", "Package.swift", "package.json", "Cargo.toml", "pyproject.toml", "Makefile"]
        for _ in 0..<8 {
            if markers.contains(where: { FileManager.default.fileExists(atPath: candidate.appendingPathComponent($0).path) }) { return candidate }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
            if candidate.path == "/tmp" || candidate.path == "/" { break }
        }
        return nil
    }
}
