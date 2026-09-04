import AppKit

struct FinderActions {
    static func open(_ item: ShelfItem) { guard let path = item.path else { return }; NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    static func reveal(_ item: ShelfItem) { guard let path = item.path else { return }; NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    static func copyPath(_ item: ShelfItem) { guard let path = item.path else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }

    /// Outcome of a rename, so the caller can tell "the user cancelled" apart
    /// from "the rename failed" and report only the second.
    enum RenameResult {
        case renamed(String)
        case cancelled
        case failed(String)
    }

    static func rename(_ item: ShelfItem, from owner: NSWindow?, completion: @escaping (RenameResult) -> Void) {
        guard let path = item.path else { completion(.failed("This item has no file path.")); return }
        guard FileManager.default.fileExists(atPath: path) else { completion(.failed("The original file is no longer at \(path).")); return }
        guard let owner else { completion(.cancelled); return }
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = "Enter a new name for \(URL(fileURLWithPath: path).lastPathComponent)."
        let field = NSTextField(string: URL(fileURLWithPath: path).lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: owner) { response in
            guard response == .alertFirstButtonReturn else { completion(.cancelled); return }
            switch validateRename(field.stringValue, of: path) {
            case .failure(let rejection):
                completion(.failed(rejection.reason))
            case .success(let destination):
                do {
                    try FileManager.default.moveItem(at: URL(fileURLWithPath: path), to: destination)
                    completion(.renamed(destination.path))
                } catch {
                    completion(.failed(error.localizedDescription))
                }
            }
        }
    }

    /// Why a proposed name was refused. A typed error keeps the reason
    /// user-presentable instead of collapsing every rejection into nil.
    struct RenameRejection: Error { let reason: String }

    /// Name validation, split out from the sheet so it can be tested directly.
    /// Rejects every input that would either fail at the filesystem layer or
    /// silently write somewhere the user did not intend.
    static func validateRename(_ raw: String, of path: String) -> Result<URL, RenameRejection> {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(RenameRejection(reason: "A file name cannot be empty.")) }
        guard !name.contains("/"), !name.contains(":") else { return .failure(RenameRejection(reason: "A file name cannot contain a slash or a colon.")) }
        guard name != ".", name != ".." else { return .failure(RenameRejection(reason: "\u{201C}\(name)\u{201D} is not a usable file name.")) }
        let source = URL(fileURLWithPath: path)
        let destination = source.deletingLastPathComponent().appendingPathComponent(name)
        // appendingPathComponent normalises, so re-check the parent survived: a
        // name that escapes its folder must never be accepted.
        guard destination.deletingLastPathComponent().standardizedFileURL.path == source.deletingLastPathComponent().standardizedFileURL.path else {
            return .failure(RenameRejection(reason: "That name would move the file out of its folder."))
        }
        guard destination.standardizedFileURL.path != source.standardizedFileURL.path else {
            return .failure(RenameRejection(reason: "That is already the file's name."))
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else { return .failure(RenameRejection(reason: "\u{201C}\(name)\u{201D} already exists in that folder.")) }
        return .success(destination)
    }

    @discardableResult
    static func compress(_ item: ShelfItem, completion: ((Bool) -> Void)? = nil) -> Process? {
        guard let path = item.path, FileManager.default.fileExists(atPath: path) else { completion?(false); return nil }
        let output = path + ".zip"
        guard !FileManager.default.fileExists(atPath: output) else { completion?(false); return nil }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", path, output]
        process.terminationHandler = { process in DispatchQueue.main.async { completion?(process.terminationStatus == 0) } }
        do { try process.run(); return process } catch { completion?(false); return nil }
    }

    static func share(_ item: ShelfItem, from view: NSView) { guard let path = item.path else { return }; NSSharingServicePicker(items: [URL(fileURLWithPath: path)]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY) }
}
