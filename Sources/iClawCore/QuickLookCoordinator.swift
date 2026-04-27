#if canImport(AppKit)
import AppKit
import QuickLookUI

/// Presents a QuickLook preview panel for a given file URL.
@MainActor
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookCoordinator()

    private var previewURL: URL?

    func preview(url: URL) {
        previewURL = url
        if let panel = QLPreviewPanel.shared() {
            panel.dataSource = self
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        1
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            previewURL as? NSURL
        }
    }
}
#endif
