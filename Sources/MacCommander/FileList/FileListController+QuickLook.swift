import AppKit

// MARK: - Quick Look and context menu

extension FileListController {
    /// Space: shows the panel for the selection, or hides it.
    func toggleQuickLook() {
        guard showsCurrentFolder else { return }
        if !QuickLookController.isPanelVisible, selectedNodes.isEmpty { return }
        QuickLookController.togglePanel()
    }

    /// `FileOutlineView.menu(for:)` already adjusted the selection: a row's menu acts on it.
    func contextMenu(forRow row: Int) -> NSMenu? {
        guard showsCurrentFolder else { return nil }
        if row < 0 {
            return FileContextMenu.forEmptySpace(
                model: model, settings: settings, clipboard: clipboard, window: outlineView.window,
                openInfo: openInfo)
        }
        let items = actionItems(forClickedRow: row)
        return FileContextMenu.forItems(
            items.topLevel, all: items.all, model: model, settings: settings, clipboard: clipboard,
            window: outlineView.window, openInfo: openInfo)
    }
}
