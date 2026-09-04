import AppKit
import Foundation

struct MarkdownExport {
    static func markdown(for item: ShelfItem) -> String {
        switch item.kind {
        case .file:
            guard let path = item.path else { return "- \(item.title)" }
            return "- [\(escape(item.title))](file://\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path))"
        case .bookmark:
            guard let url = item.urlString else { return "- \(escape(item.title))" }
            return "- [\(escape(item.title))](\(url))"
        case .note:
            return "## \(escape(item.title))\n\n\(item.text ?? "")"
        case .clipboard:
            return "```text\n\(item.text ?? "")\n```"
        }
    }

    static func copy(_ item: ShelfItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown(for: item), forType: .string)
    }

    static func export(_ items: [ShelfItem], to url: URL) throws {
        let content = items.map { markdown(for: $0) }.joined(separator: "\n\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
}
