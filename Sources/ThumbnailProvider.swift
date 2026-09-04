import AppKit
import QuickLookThumbnailing

/// Renders and caches QuickLook thumbnails for shelf items.
///
/// A shelf is a visual object; a generic document glyph for every image, PDF
/// and video wastes the one thing it is for. But `QLThumbnailGenerator` only
/// ever answers off the main thread — its own docs are explicit that the
/// completion handler runs on an arbitrary background queue — so this never
/// blocks a row's construction. Callers paint `NSWorkspace`'s generic file
/// icon first, which is synchronous and always available, then upgrade to the
/// real thumbnail once `completion` fires.
final class ThumbnailProvider {
    static let shared = ThumbnailProvider()

    /// Identifies one outstanding request. A caller keeps the token it gets
    /// back and compares it against its own state inside the completion
    /// closure; a mismatch means the view has since moved on — a fresh
    /// request superseded this one, or the view is gone — so the answer is
    /// discarded rather than painted somewhere it no longer belongs.
    typealias Token = UInt64

    private let cache = NSCache<NSString, NSImage>()
    private let generator = QLThumbnailGenerator.shared
    private var nextToken: Token = 0

    private init() {
        // Thumbnails are small bitmaps at row/tile size; a generous limit
        // costs little memory and avoids re-rendering while flipping tabs.
        cache.countLimit = 400
    }

    /// Requests a thumbnail for the file at `path`, sized in points.
    /// `completion` always runs on the main thread, and is skipped entirely
    /// for a file that has vanished by the time QuickLook would have
    /// delivered an answer — the caller's existing fallback icon just stays
    /// put in that case.
    @discardableResult
    func requestThumbnail(for path: String, size: CGSize, completion: @escaping (NSImage) -> Void) -> Token {
        nextToken += 1
        let token = nextToken

        guard let key = cacheKey(path: path, size: size) else { return token }
        if let cached = cache.object(forKey: key) {
            // Still asynchronous: a synchronous callout from inside a caller's
            // own `init` would run before it has anywhere to put the result.
            DispatchQueue.main.async { completion(cached) }
            return token
        }
        guard FileManager.default.fileExists(atPath: path) else { return token }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: size, scale: scale, representationTypes: .thumbnail)
        generator.generateBestRepresentation(for: request) { [weak self] representation, error in
            guard let self, let representation, error == nil, FileManager.default.fileExists(atPath: path) else { return }
            let image = representation.nsImage
            DispatchQueue.main.async {
                self.cache.setObject(image, forKey: key)
                completion(image)
            }
        }
        return token
    }

    /// Path, requested size and a modification signature together: a file
    /// replaced at the same path (re-saved from an editor, say) must re-render,
    /// but revisiting an unchanged file should never pay for that again.
    private func cacheKey(path: String, size: CGSize) -> NSString? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return "\(path)|\(Int(size.width))x\(Int(size.height))|\(byteCount)|\(modified)" as NSString
    }
}
