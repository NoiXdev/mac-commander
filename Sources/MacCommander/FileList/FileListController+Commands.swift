import AppKit
import MacCommanderCore

/// The file commands from the menu bar and the keyboard (see `FileOutlineView`), acting on `selectedItems`.
/// Paste from the menu bar goes into the current folder.
extension FileListController: FileCommandHandler {
    var isEditingText: Bool { rename.session != nil }

    var undoTitle: String? { model.operations.undo.undoTitle }

    func canPerform(_ command: FileCommand) -> Bool {
        // Only in the key window without a sheet: `sendAction` also tries the main window, which stays main
        // under a sheet (e.g. Go to Folder), and ⌘⌫ there must not trash the list's selection.
        guard let window = outlineView.window, window.isKeyWindow, window.attachedSheet == nil,
            showsCurrentFolder, !isEditingText
        else { return false }
        switch command {
        case .getInfo:
            return true
        case .copy, .cut, .duplicate, .moveToTrash, .copyPath:
            return !outlineView.selectedRowIndexes.isEmpty
        case .paste, .pasteAsMove:
            return !clipboard.fileURLs.isEmpty
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
        switch command {
        case .copy:
            FileActions.copy(items, clipboard: clipboard)
        case .cut:
            FileActions.cut(items, clipboard: clipboard)
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
            Task { await FileActions.duplicate(items, model: model, window: window) }
        case .moveToTrash:
            Task { await FileActions.moveToTrash(items, model: model, window: window) }
        case .undo:
            Task { await FileActions.undo(model: model, window: window) }
        case .getInfo:
            // Nothing selected: the current folder.
            FileActions.getInfo(items.isEmpty ? [model.currentURL] : items.map(\.url), open: openInfo)
        }
    }
}
