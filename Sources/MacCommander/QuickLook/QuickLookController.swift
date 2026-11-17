import AppKit
import Quartz

/// Feeds the shared Quick Look panel with the list's selection. The list's outline view accepts
/// panel control while it is in the responder chain and hands the panel to this controller.
@MainActor
// The QuickLookUI protocols aren't main-actor annotated, but the panel calls them on the main
// thread; `@preconcurrency` checks that at run time.
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource,
    @preconcurrency QLPreviewPanelDelegate
{
    /// The URLs to preview, in display order.
    private let selectedURLs: () -> [URL]
    /// Receives key events the panel doesn't handle (arrow keys move the list selection).
    private weak var keyTarget: NSResponder?
    private var panel: QLPreviewPanel?
    /// Snapshot of `selectedURLs()`, so the data source answers consistently between reloads.
    private var urls: [URL] = []

    init(keyTarget: NSResponder, selectedURLs: @escaping () -> [URL]) {
        self.keyTarget = keyTarget
        self.selectedURLs = selectedURLs
    }

    // MARK: - Panel

    static var isPanelVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    static func showPanel() {
        QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
    }

    static func togglePanel() {
        if isPanelVisible {
            QLPreviewPanel.shared().orderOut(nil)
        } else {
            showPanel()
        }
    }

    // MARK: - Control (called by the list's outline view)

    func beginControl(_ panel: QLPreviewPanel) {
        self.panel = panel
        urls = selectedURLs()
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    func endControl(_ panel: QLPreviewPanel) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
        self.panel = nil
    }

    /// The list is leaving its folder: close a panel showing its items.
    func folderDidChange() {
        guard let panel else { return }
        urls = []
        panel.orderOut(nil)
    }

    /// Follows the list selection while the panel is controlled by this list.
    func selectionDidChange() {
        guard let panel else { return }
        urls = selectedURLs()
        panel.reloadData()
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    // MARK: - QLPreviewPanelDelegate

    /// Arrow keys pressed while the panel is key move the list selection, like in Finder.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        switch event.specialKey {
        case .upArrow?, .downArrow?:
            keyTarget?.keyDown(with: event)
            return true
        default:
            return false
        }
    }
}
