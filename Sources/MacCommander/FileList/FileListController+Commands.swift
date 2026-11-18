import AppKit
import MacCommanderCore

/// The file commands from the menu bar and the keyboard (see `FileOutlineView`). Copy, cut, duplicate and
/// trash act on `topLevelSelectedItems`; Get Info and Copy Path on all `selectedItems`.
/// Paste from the menu bar goes into the current folder.
extension FileListController: FileCommandHandler {
    var isEditingText: Bool { rename.session != nil }

    var undoTitle: String? { model.operations.undo.undoTitle }

    /// True while the list shows a folder inside an archive: everything that writes is disabled.
    var isInArchive: Bool { model.archiveLocation != nil }

    func canPerform(_ command: FileCommand) -> Bool {
        // Only in the key window without a sheet: `sendAction` also tries the main window, which stays main
        // under a sheet (e.g. Go to Folder), and ⌘⌫ there must not trash the list's selection.
        guard let window = outlineView.window, window.isKeyWindow, window.attachedSheet == nil,
            showsCurrentFolder, !isEditingText
        else { return false }
        // Archives are read-only, and their entries have no real paths to copy or inspect. Undo acts on
        // the app-wide history, not on this folder, so it stays available.
        if isInArchive, command != .undo { return false }
        switch command {
        case .getInfo:
            return true
        case .copy, .cut, .duplicate, .moveToTrash, .copyPath:
            return !outlineView.selectedRowIndexes.isEmpty
        case .paste, .pasteAsMove:
            // Into the current folder, whose items a shown search hides.
            return !clipboard.fileURLs.isEmpty && !model.isSearching
        case .undo:
            // Also off while an undo runs, so a quick double ⌘Z doesn't queue a second one.
            let undo = model.operations.undo
            return undo.undoTitle != nil && !undo.isUndoing
        }
    }

    func perform(_ command: FileCommand) {
        guard canPerform(command) else {
            NSSound.beep()
            return
        }
        let model = model
        let clipboard = clipboard
        let window = outlineView.window
        let items = selectedItems
        let topLevel = Self.topLevel(items)
        switch command {
        case .copy:
            FileActions.copy(topLevel, clipboard: clipboard)
        case .cut:
            FileActions.cut(topLevel, clipboard: clipboard)
        case .copyPath:
            FileActions.copyPath(items)
        case .paste, .pasteAsMove:
            let destination = model.currentURL
            Task {
                await FileActions.paste(
                    into: destination, forceMove: command == .pasteAsMove, model: model, clipboard: clipboard,
                    window: window)
            }
        case .duplicate:
            Task { await FileActions.duplicate(topLevel, model: model, window: window) }
        case .moveToTrash:
            Task { await FileActions.moveToTrash(topLevel, model: model, window: window) }
        case .undo:
            Task { await FileActions.undo(model: model, window: window) }
        case .getInfo:
            // Nothing selected: the current folder.
            FileActions.getInfo(items.isEmpty ? [model.currentURL] : items.map(\.url), open: openInfo)
        }
    }
}
