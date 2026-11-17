import AppKit
import Quartz

/// Feeds the shared Quick Look panel with the list's selection. The list's outline view accepts
/// panel control while it is in the responder chain and hands the panel to this controller.
///
/// Inside an archive the selection's URLs are virtual and must never reach the panel: the list extracts
/// the selected files first and shows those temporary copies with `show(_:for:)` ("override" mode).
@MainActor
// The QuickLookUI protocols aren't main-actor annotated, but the panel calls them on the main
// thread; `@preconcurrency` checks that at run time.
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource,
    @preconcurrency QLPreviewPanelDelegate
{
    /// The selected rows' URLs, in display order.
    private let selectedURLs: () -> [URL]
    /// False while the selection can't be previewed as is (inside an archive); the panel then shows
    /// only an override set.
    private let previewsSelection: () -> Bool
    /// Receives key events the panel doesn't handle (arrow keys move the list selection).
    private weak var keyTarget: NSResponder?
    private var panel: QLPreviewPanel?
    /// Snapshot of `selectedURLs()`, so the data source answers consistently between reloads.
    private var urls: [URL] = []
    /// Override mode: the extracted files shown instead of the selection, and the selection they were
    /// extracted for. Used only while that is still the selection.
    private var override: (urls: [URL], selection: [URL])?

    init(keyTarget: NSResponder, previewsSelection: @escaping () -> Bool, selectedURLs: @escaping () -> [URL]) {
        self.keyTarget = keyTarget
        self.previewsSelection = previewsSelection
        self.selectedURLs = selectedURLs
    }

    /// The URLs the panel shows: the selection when it can be previewed, otherwise the override set made
    /// for the current selection, otherwise nothing (virtual URLs never reach the panel).
    private var currentURLs: [URL] {
        if previewsSelection() { return selectedURLs() }
        if let override, override.selection == selectedURLs() { return override.urls }
        return []
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
        urls = currentURLs
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    func endControl(_ panel: QLPreviewPanel) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
        self.panel = nil
    }

    /// Shows the panel with `files` (real, extracted files) instead of the selection, which is `selection`
    /// (the rows they were extracted for). The panel's own ← and → move through `files`; it closes when the
    /// selection changes.
    func show(_ files: [URL], for selection: [URL]) {
        override = (files, selection)
        if let panel {
            urls = files
            panel.reloadData()
            panel.currentPreviewItemIndex = 0
        }
        Self.showPanel()
    }

    /// The list is leaving its folder: close a panel showing its items.
    func folderDidChange() {
        override = nil
        guard let panel else { return }
        urls = []
        panel.orderOut(nil)
    }

    /// Follows the list selection while the panel is controlled by this list.
    /// Inside an archive a different selection closes the panel instead (its files would need extracting).
    func selectionDidChange() {
        guard let panel else { return }
        if !previewsSelection() {
            if override?.selection != selectedURLs() {
                override = nil
                urls = []
                panel.orderOut(nil)
            }
            return
        }
        override = nil
        urls = currentURLs
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

    /// Arrow keys pressed while the panel is key move the list selection, like in Finder. Inside an archive
    /// the panel handles them itself and moves within the extracted set.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard previewsSelection(), let event, event.type == .keyDown else { return false }
        switch event.specialKey {
        case .upArrow?, .downArrow?:
            keyTarget?.keyDown(with: event)
            return true
        default:
            return false
        }
    }
}
