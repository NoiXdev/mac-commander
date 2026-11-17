import AppKit
import MacCommanderCore

// MARK: - Quick Look and context menu

extension FileListController {
    /// Space: shows the panel for the selection, or hides it.
    /// Inside an archive, Space while the selection is being extracted cancels that instead; with another
    /// selection it starts over for that one.
    func toggleQuickLook() {
        guard showsCurrentFolder else { return }
        if model.archiveLocation != nil {
            if let pending = quickLookTask {
                if pending.selection == selectedNodes.map(\.url) {
                    cancelArchiveQuickLook()
                } else {
                    showArchiveQuickLook()
                }
            } else if QuickLookController.isPanelVisible {
                QuickLookController.togglePanel()
            } else {
                showArchiveQuickLook()
            }
            return
        }
        if !QuickLookController.isPanelVisible, selectedNodes.isEmpty { return }
        QuickLookController.togglePanel()
    }

    /// Inside an archive: extracts the selected files (folders and symlinks are skipped) through the preview cache, then
    /// shows the panel with the extracted copies in row order. Beeps when no file is selected. The panel
    /// isn't shown until the extraction finished; it isn't shown at all if the folder or the selection
    /// changed meanwhile.
    func showArchiveQuickLook() {
        guard showsCurrentFolder, let archive = model.archiveLocation?.archive else { return }
        // A symlink would be followed out of the cache by the panel.
        let files = selectedItems.filter { !$0.isDirectory && !$0.isSymlink }
        // Cheap stats only (`ArchivePath.split`).
        let entries = files.compactMap { ArchivePath.split($0.url)?.inner }
        guard !entries.isEmpty, entries.count == files.count else {
            NSSound.beep()
            return
        }
        cancelArchiveQuickLook()
        let selection = selectedNodes.map(\.url)
        let folder = model.currentURL
        let window = outlineView.window
        let name = files.count == 1 ? files[0].name : archive.lastPathComponent
        let task = Task { [weak self] in
            let extracted = await FileActions.extractForPreview(entries, of: archive, name: name, window: window)
            // A cancelled task was already replaced or cleared by whoever cancelled it.
            guard let self, !Task.isCancelled else { return }
            quickLookTask = nil
            guard let extracted, showsCurrentFolder, model.currentURL == folder,
                selectedNodes.map(\.url) == selection
            else { return }
            outlineView.quickLook?.show(extracted, for: selection)
        }
        quickLookTask = (task, selection)
    }

    /// Stops a running Quick Look extraction (bsdtar is terminated); the panel isn't shown.
    func cancelArchiveQuickLook() {
        quickLookTask?.task.cancel()
        quickLookTask = nil
    }

    /// A different selection makes a running Quick Look extraction pointless: cancel it (bsdtar stops).
    func selectionDidChangeForQuickLook() {
        if let pending = quickLookTask, pending.selection != selectedNodes.map(\.url) {
            cancelArchiveQuickLook()
        }
        outlineView.quickLook?.selectionDidChange()
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
            window: outlineView.window, openInfo: openInfo,
            archiveQuickLook: { [weak self] in self?.showArchiveQuickLook() })
    }
}
