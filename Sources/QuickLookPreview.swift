import AppKit
import QuickLookUI

final class QuickLookPreviewController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var url: URL?
    private var onDismiss: (() -> Void)?

    /// `onDismiss` lets the shelf re-arm auto-hide only once the preview is
    /// actually gone; hiding the shelf underneath an open Quick Look panel left
    /// the user with no way back to it.
    func preview(_ url: URL, from owner: NSWindow?, onDismiss: (() -> Void)? = nil) {
        self.url = url
        self.onDismiss = onDismiss
        guard let panel = QLPreviewPanel.shared() else { onDismiss?(); self.onDismiss = nil; return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        owner?.makeKeyAndOrderFront(nil)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        if let panel = QLPreviewPanel.shared(), panel.isVisible { panel.orderOut(nil) }
        finish()
    }

    private func finish() {
        let callback = onDismiss
        onDismiss = nil
        url = nil
        callback?()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem { (url ?? URL(fileURLWithPath: "/")) as NSURL }
    func windowWillClose(_ notification: Notification) { finish() }
}
