import AppKit
import MacCommanderCore
import Observation
import SwiftUI

extension FileListController {
    // MARK: - Icons

    func scheduleIconPass() {
        guard !iconPassScheduled else { return }
        iconPassScheduled = true
        Task { @MainActor [weak self] in self?.loadVisibleIcons() }
    }

    /// Replaces type placeholders by the files' own icons for the visible rows, in small batches.
    func loadVisibleIcons() {
        iconPassScheduled = false
        let columnIndex = outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier(FileColumn.name))
        guard columnIndex >= 0, let visible = Range(outlineView.rows(in: outlineView.visibleRect)) else { return }
        var loaded = 0
        for row in visible {
            guard
                let cell = outlineView.view(atColumn: columnIndex, row: row, makeIfNecessary: false)
                    as? FileNameCellView,
                !cell.hasFileIcon, let node = node(atRow: row)
            else { continue }
            cell.imageView?.image = icons.loadFileIcon(for: node.url)
            cell.hasFileIcon = true
            loaded += 1
            if loaded >= 32 {
                scheduleIconPass()
                return
            }
        }
    }
}

// MARK: - NSOutlineViewDataSource

extension FileListController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return roots.count }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return roots[index] }
        return node.children?[index] as Any
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.item.isDirectory ?? false
    }

    /// Rows can be dragged out (e.g. onto the sidebar Favorites or Finder) as file URLs. A selected row
    /// inside a selected folder is not dragged on its own: it moves or copies with that folder.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let node = item as? FileNode else { return nil }
        let row = outlineView.row(forItem: node)
        if row >= 0, outlineView.isRowSelected(row), hasSelectedAncestor(node) { return nil }
        return node.url as NSURL
    }

    // MARK: Drop target

    /// A drop on a folder row (also an inline-expanded subfolder) goes into that folder; anywhere else
    /// (between rows, on a file, on empty space) it is retargeted to the whole list, i.e. the current
    /// folder. `DropPolicy` decides copy or move, or refuses (no highlight).
    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard showsCurrentFolder else { return [] }
        let sources = FileActions.fileURLs(on: info.draggingPasteboard)
        guard !sources.isEmpty else { return [] }
        let destination: URL
        if let node = item as? FileNode, node.item.isDirectory, index == NSOutlineViewDropOnItemIndex {
            destination = node.url
        } else {
            outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            destination = model.currentURL
        }
        guard let mode = FileActions.dropMode(for: sources, into: destination) else { return [] }
        return Self.dragOperation(for: mode, allowed: info.draggingSourceOperationMask)
    }

    func outlineView(
        _ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int
    ) -> Bool {
        guard showsCurrentFolder else { return false }
        let sources = FileActions.fileURLs(on: info.draggingPasteboard)
        let destination = (item as? FileNode).flatMap { $0.item.isDirectory ? $0.url : nil } ?? model.currentURL
        guard let mode = FileActions.dropMode(for: sources, into: destination) else { return false }
        let model = model
        let window = outlineView.window
        Task { await FileActions.transfer(sources, into: destination, mode: mode, model: model, window: window) }
        return true
    }

    /// `.copy` or `.move`, so the cursor shows the matching badge. While ⌘ is held AppKit narrows the
    /// source's mask to `.generic`; that then stands for the move.
    static func dragOperation(for mode: TransferMode, allowed: NSDragOperation) -> NSDragOperation {
        let preferred: NSDragOperation = mode == .copy ? .copy : .move
        if allowed.contains(preferred) { return preferred }
        return allowed.contains(.generic) ? .generic : []
    }
}

// MARK: - NSOutlineViewDelegate

extension FileListController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let tableColumn, let node = item as? FileNode else { return nil }
        if tableColumn.identifier == .checkboxColumn {
            // Clicks are handled by `FileOutlineView.mouseDown`; the cell only mirrors the selection.
            let cell =
                outlineView.makeView(withIdentifier: .checkboxCell, owner: self) as? CheckboxCellView
                ?? CheckboxCellView()
            let row = outlineView.row(forItem: node)
            cell.checkbox.state = row >= 0 && outlineView.isRowSelected(row) ? .on : .off
            return cell
        }
        guard let column = FileColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let alpha: CGFloat = node.item.isHidden ? 0.5 : 1

        if column == .name {
            let cell =
                outlineView.makeView(withIdentifier: .nameCell, owner: self) as? FileNameCellView
                ?? FileNameCellView()
            cell.textField?.stringValue = node.item.name
            if let icon = icons.cachedFileIcon(for: node.url) {
                cell.imageView?.image = icon
                cell.hasFileIcon = true
            } else {
                cell.imageView?.image = icons.placeholder(for: node.item)
                cell.hasFileIcon = false
                scheduleIconPass()
            }
            cell.alphaValue = alpha
            return cell
        }

        let identifier: NSUserInterfaceItemIdentifier = column == .size ? .rightAlignedTextCell : .textCell
        let cell =
            outlineView.makeView(withIdentifier: identifier, owner: self) as? FileTextCellView
            ?? FileTextCellView(identifier: identifier, alignment: column == .size ? .right : .left)
        cell.textField?.stringValue = FileListFormat.text(for: column, of: node.item)
        cell.alphaValue = alpha
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        let columnIndex = outlineView.column(withIdentifier: .checkboxColumn)
        guard columnIndex >= 0, let cell = rowView.view(atColumn: columnIndex) as? CheckboxCellView else { return }
        cell.checkbox.state = outlineView.isRowSelected(row) ? .on : .off
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateCheckboxStates()
        outlineView.quickLook?.selectionDidChange()
        guard !isApplyingChanges else { return }
        writeSelectionToModel()
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        if node.children != nil { return true }
        if node.loadTask == nil { loadChildren(of: node, expand: true) }
        return false
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        updateCheckboxStates()
        guard !isApplyingChanges, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        expandedURLs.insert(node.url)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        updateCheckboxStates()
        guard !isApplyingChanges, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        expandedURLs.remove(node.url)
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard tableColumn?.identifier.rawValue == FileColumn.name.rawValue else { return nil }
        return (item as? FileNode)?.item.name
    }

    // Header

    func outlineView(_ outlineView: NSOutlineView, didClick tableColumn: NSTableColumn) {
        if tableColumn.identifier == .checkboxColumn {
            toggleSelectAll()
            return
        }
        guard let column = FileColumn(rawValue: tableColumn.identifier.rawValue) else { return }
        var order = settings.settings.sortOrder
        if order.column == column {
            order.ascending.toggle()
        } else {
            order.column = column
            order.ascending = true
        }
        settings.settings.sortOrder = order
    }

    /// The checkbox column stays first: it can't be moved, and nothing can move before it.
    func outlineView(_ outlineView: NSOutlineView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
        columnIndex != 0 && newColumnIndex != 0
    }

    func outlineViewColumnDidMove(_ notification: Notification) {
        saveColumnLayout()
    }

    func outlineViewColumnDidResize(_ notification: Notification) {
        saveColumnLayout()
    }
}
