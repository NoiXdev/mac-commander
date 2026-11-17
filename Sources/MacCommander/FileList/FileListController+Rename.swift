import AppKit
import MacCommanderCore
import Observation

/// An inline rename in progress: the item and the name cell being edited.
struct RenameSession {
    let url: URL
    /// The file name on disk, which is what gets edited.
    let originalName: String
    /// The name the cell showed before editing (the localized name).
    let displayName: String
    weak var cell: FileNameCellView?
    /// The field's text, kept up to date while typing, so it survives a reload of the cell.
    var text: String
}

struct InlineRenameState {
    var session: RenameSession?
    /// The pending rename whose parent folder was already re-listed, so it is listed only once.
    var relistedFor: URL?
}

// MARK: - Inline rename

extension FileListController: NSTextFieldDelegate {
    /// Return: renames the single selected row.
    func renameSelection() {
        repairRenameSession()
        guard showsCurrentFolder, rename.session == nil else { return }
        let nodes = selectedNodes
        guard nodes.count == 1 else { return }
        beginRename(of: nodes[0])
    }

    func observePendingRename() {
        withObservationTracking {
            _ = model.pendingRename
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observePendingRename()
                self?.startPendingRename()
            }
        }
    }

    /// Starts editing `model.pendingRename` once its row exists. An item created inside a listed
    /// subfolder isn't loaded yet: that folder is expanded and re-listed first, then this runs
    /// again from `didLoadChildren`.
    func startPendingRename() {
        guard let url = model.pendingRename, showsCurrentFolder else { return }
        if let node = loadedNode(path: url.path) {
            model.pendingRename = nil
            rename.relistedFor = nil
            endRename(commit: true)
            beginRename(of: node)
            return
        }
        guard rename.relistedFor != url,
            let folder = loadedNode(path: url.deletingLastPathComponent().path), folder.item.isDirectory
        else { return }
        rename.relistedFor = url
        loadChildren(of: folder, expand: true)
    }

    /// Edits the node's name cell, with the name before the extension preselected (all of it for
    /// folders and names without an extension). `text` replaces the name, e.g. after a failed try.
    func beginRename(of node: FileNode, text: String? = nil) {
        let row = outlineView.row(forItem: node)
        let column = outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier(FileColumn.name))
        guard row >= 0, column >= 0 else { return }
        outlineView.scrollRowToVisible(row)
        if outlineView.selectedRowIndexes != IndexSet(integer: row) {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        guard let cell = outlineView.view(atColumn: column, row: row, makeIfNecessary: true) as? FileNameCellView,
            let field = cell.textField
        else { return }

        let name = node.url.lastPathComponent
        let initial = text ?? name
        rename.session = RenameSession(
            url: node.url, originalName: name, displayName: node.item.name, cell: cell, text: initial)
        cell.setEditing(true)
        field.delegate = self
        field.stringValue = initial
        guard view.window?.makeFirstResponder(field) == true else {
            endRename(commit: false)
            return
        }
        field.currentEditor()?.selectedRange = Self.baseNameRange(of: field.stringValue, isFolder: node.item.isDirectory)
    }

    /// Ends the edit. With `commit`, a changed name is applied through `model.rename`; on failure
    /// an alert shows the reason and editing resumes with the typed name. `restoreFocus` moves
    /// the keyboard focus back to the list (not when the field lost it to something else).
    func endRename(commit: Bool, restoreFocus: Bool = true) {
        guard let session = rename.session else { return }
        // A reload during the edit may have removed the cell or reused it for another row; its
        // field then isn't the user's input for this item. Resume on the item's current cell
        // instead (unless focus is moving elsewhere), so the typed name isn't silently lost.
        guard isIntact(session) else {
            abandonRename(session, restoreFocus: restoreFocus)
            if restoreFocus, showsCurrentFolder, let node = loadedNode(path: session.url.path) {
                beginRename(of: node, text: session.text)
            }
            return
        }
        rename.session = nil
        let cell = session.cell
        let newName = cell?.textField?.stringValue ?? session.text
        if restoreFocus, let field = cell?.textField, field.currentEditor() != nil {
            view.window?.makeFirstResponder(outlineView)
        }
        cell?.setEditing(false)
        guard let cell else { return }

        guard commit, newName != session.originalName else {
            cell.textField?.stringValue = session.displayName
            return
        }
        commitRename(session, to: newName)
    }

    private func commitRename(_ session: RenameSession, to name: String) {
        // The model reloads only the current folder; an inline-expanded parent is re-listed here.
        let parent = loadedNode(path: session.url.path)?.parent
        Task { @MainActor [weak self, model] in
            do throws(RenameError) {
                _ = try await model.rename(session.url, to: name)
                if let self, let parent, parent.isAttached {
                    self.loadChildren(of: parent, expand: false)
                }
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = error.message
                alert.runModal()
                guard let self else { return }
                let node = self.loadedNode(path: session.url.path)
                guard self.showsCurrentFolder, self.rename.session == nil, let node else {
                    // Editing can't resume: don't leave the rejected name on screen.
                    if let node { self.showDisplayName(of: node) }
                    return
                }
                self.beginRename(of: node, text: name)
            }
        }
    }

    /// True while the session's cell is still the edited name cell of its item's row.
    private func isIntact(_ session: RenameSession) -> Bool {
        guard let cell = session.cell, cell.isEditing else { return false }
        return node(atRow: outlineView.row(for: cell))?.url == session.url
    }

    /// Ends a session whose cell was lost, without renaming.
    private func abandonRename(_ session: RenameSession, restoreFocus: Bool) {
        rename.session = nil
        if let field = session.cell?.textField, field.currentEditor() != nil, restoreFocus {
            view.window?.makeFirstResponder(outlineView)
        }
        if let cell = session.cell, cell.isEditing, outlineView.row(for: cell) < 0 { cell.setEditing(false) }
    }

    /// After rows were reloaded: if the edited cell was replaced, editing restarts on the item's
    /// new cell with the text typed so far; if the item is gone, the session ends.
    func repairRenameSession() {
        guard let session = rename.session, !isIntact(session) else { return }
        let hadFocus = session.cell?.textField?.currentEditor() != nil
        abandonRename(session, restoreFocus: true)
        guard showsCurrentFolder, let node = loadedNode(path: session.url.path) else { return }
        // Resume unless the user had already moved the focus somewhere else.
        let responder = view.window?.firstResponder
        let focusInList =
            responder == nil || responder === view.window
            || (responder as? NSView)?.isDescendant(of: outlineView) == true
        if hadFocus || focusInList {
            beginRename(of: node, text: session.text)
        }
    }

    private func showDisplayName(of node: FileNode) {
        let row = outlineView.row(forItem: node)
        let column = outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier(FileColumn.name))
        guard row >= 0, column >= 0,
            let cell = outlineView.view(atColumn: column, row: row, makeIfNecessary: false) as? FileNameCellView,
            !cell.isEditing
        else { return }
        cell.textField?.stringValue = node.item.name
    }

    /// The loaded node (at any depth) whose URL has this path.
    func loadedNode(path: String) -> FileNode? {
        var stack = roots
        while let node = stack.popLast() {
            if node.url.path == path { return node }
            if let children = node.children { stack.append(contentsOf: children) }
        }
        return nil
    }

    /// The name without its extension, like Finder; all of it for folders and extensionless names.
    static func baseNameRange(of name: String, isFolder: Bool) -> NSRange {
        let full = name as NSString
        let ext = full.pathExtension as NSString
        guard !isFolder, ext.length > 0 else { return NSRange(location: 0, length: full.length) }
        return NSRange(location: 0, length: full.length - ext.length - 1)
    }

    // MARK: NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let session = rename.session, control === session.cell?.textField else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            endRename(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endRename(commit: false)
            return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === rename.session?.cell?.textField else {
            return
        }
        rename.session?.text = field.stringValue
    }

    /// Focus left the field (click elsewhere, Tab): commit, like Finder.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let session = rename.session, notification.object as? NSTextField === session.cell?.textField else {
            return
        }
        endRename(commit: true, restoreFocus: false)
    }
}
