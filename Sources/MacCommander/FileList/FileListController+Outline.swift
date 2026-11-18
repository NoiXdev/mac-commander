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

    /// Replaces type placeholders by the files' own icons for the visible rows, in batches of 32 loaded off
    /// the main actor (one batch per folder at a time; on an unresponsive server the placeholders simply stay).
    func loadVisibleIcons() {
        iconPassScheduled = false
        // Archive entries have virtual paths: their type icons are final (see `outlineView(_:viewFor:item:)`).
        let folder = model.listedURL
        guard !isInArchive, folder == nil || iconBatchFolder != folder else { return }
        let urls = visibleNameCells().filter { !$0.cell.hasFileIcon }.prefix(32).map(\.url)
        guard !urls.isEmpty else { return }
        iconBatchFolder = folder
        Task { @MainActor [weak self] in
            guard let self else { return }
            let loaded = await icons.loadFileIcons(for: urls)
            if iconBatchFolder == folder { iconBatchFolder = nil }
            // Rows may have scrolled or been reused meanwhile: apply by URL to what is visible now.
            if !isInArchive {
                for (cell, url) in visibleNameCells() where !cell.hasFileIcon {
                    guard let icon = loaded[url] else { continue }
                    cell.imageView?.image = icon
                    cell.hasFileIcon = true
                }
            }
            // The next pass picks up whatever is still without its icon, and stops when nothing is.
            scheduleIconPass()
        }
    }

    /// The name cells of the visible rows with their rows' URLs.
    private func visibleNameCells() -> [(cell: FileNameCellView, url: URL)] {
        let columnIndex = outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier(FileColumn.name))
        guard columnIndex >= 0, let visible = Range(outlineView.rows(in: outlineView.visibleRect)) else { return [] }
        return visible.compactMap { row in
            guard
                let cell = outlineView.view(atColumn: columnIndex, row: row, makeIfNecessary: false)
                    as? FileNameCellView,
                let node = node(atRow: row)
            else { return nil }
            return (cell, node.url)
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
    /// Archive entries are dragged as file promises plus the `archiveEntries` type (`ArchiveEntryDragProvider`).
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let node = item as? FileNode else { return nil }
        let row = outlineView.row(forItem: node)
        let isSelected = row >= 0 && outlineView.isRowSelected(row)
        if isSelected, hasSelectedAncestor(node) { return nil }
        guard let archive = model.archiveLocation?.archive else { return node.url as NSURL }
        guard let entry = Self.entryPath(of: node.url, in: archive) else { return nil }
        let payload =
            isSelected
            ? selectionDragPayload(archive: archive)
            : ArchiveDragPayload(archive: archive, entries: [entry])
        return ArchiveEntryDragProvider(archive: archive, entry: entry, isDirectory: node.item.isDirectory, payload: payload)
    }

    /// Archive rows drag as copies only (nothing leaves the archive); other rows keep copy, move and
    /// generic (⌘ = move), as set up in `configureOutline`.
    func outlineView(
        _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
        forItems draggedItems: [Any]
    ) {
        // All writers of this drag exist now: the payload cache must not outlive it.
        archiveDragPayload = nil
        let mask: NSDragOperation = isInArchive ? .copy : Self.fileDragOperations
        outlineView.setDraggingSourceOperationMask(mask, forLocal: false)
        outlineView.setDraggingSourceOperationMask(mask, forLocal: true)
    }

    /// The payload for dragging the selection: every selected top-level entry. AppKit asks for one writer
    /// per dragged row, so it is computed once per drag (the cache is cleared when the session begins).
    private func selectionDragPayload(archive: URL) -> ArchiveDragPayload {
        let selection = outlineView.selectedRowIndexes
        if let cached = archiveDragPayload, cached.selection == selection, cached.payload.archive == archive {
            return cached.payload
        }
        let urls = selection.compactMap { node(atRow: $0)?.url }
        let entries = PathUtilities.topLevel(urls).compactMap { Self.entryPath(of: $0, in: archive) }
        let payload = ArchiveDragPayload(archive: archive, entries: entries)
        archiveDragPayload = (selection, payload)
        return payload
    }

    /// The inner path of a row's virtual URL inside `archive` (by path prefix, no file-system access);
    /// nil for the archive itself or a URL outside it.
    static func entryPath(of url: URL, in archive: URL) -> String? {
        ArchivePath.inner(of: url, in: archive)
    }

    // MARK: Drop target

    /// A drop on a folder row (also an inline-expanded subfolder) goes into that folder; anywhere else
    /// (between rows, on a file, on empty space) it is retargeted to the whole list, i.e. the current
    /// folder. `DropPolicy` decides copy or move, or refuses (no highlight).
    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        // Archives are read-only: nothing can be dropped into one.
        guard showsCurrentFolder, !isInArchive else { return [] }
        let destination: URL
        if let node = item as? FileNode, node.item.isDirectory, index == NSOutlineViewDropOnItemIndex {
            destination = node.url
        } else {
            outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            destination = model.currentURL
        }
        // Entries dragged out of an archive (checked first: their promises are no file URLs) are extracted.
        // The destination is a real folder (drops inside an archive were refused above): no path check.
        if ArchiveDragPayload.isOn(info.draggingPasteboard) {
            return info.draggingSourceOperationMask.contains(.copy) ? .copy : []
        }
        // Cached per drag, destination and modifier keys: this runs on every mouse move.
        guard let mode = FileActions.hoverDropMode(on: info.draggingPasteboard, into: destination) else { return [] }
        return Self.dragOperation(for: mode, allowed: info.draggingSourceOperationMask)
    }

    func outlineView(
        _ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int
    ) -> Bool {
        guard showsCurrentFolder, !isInArchive else { return false }
        let destination = (item as? FileNode).flatMap { $0.item.isDirectory ? $0.url : nil } ?? model.currentURL
        if ArchiveDragPayload.isOn(info.draggingPasteboard) {
            guard let payload = ArchiveDragPayload(pasteboard: info.draggingPasteboard) else { return false }
            let model = model
            let window = outlineView.window
            Task {
                await FileActions.extract(
                    payload.entries, from: payload.archive, into: destination, model: model, window: window)
            }
            return true
        }
        let sources = FileActions.fileURLs(on: info.draggingPasteboard)
        guard !sources.isEmpty else { return false }
        // The keys held at drop time; the policy check runs off the main actor and beeps if it refuses.
        let modifiers = FileActions.currentDropModifiers()
        let model = model
        let window = outlineView.window
        Task {
            guard let mode = await FileActions.dropMode(for: sources, into: destination, modifiers: modifiers) else {
                return NSSound.beep()
            }
            await FileActions.transfer(sources, into: destination, mode: mode, model: model, window: window)
        }
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
            cell.showTags(node.item.tags)
            if isInArchive {
                // Entries inside an archive don't exist on disk: the type icon is all there is.
                cell.imageView?.image = icons.placeholder(for: node.item)
                cell.hasFileIcon = true
            } else if let icon = icons.cachedFileIcon(for: node.url) {
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

        let identifier: NSUserInterfaceItemIdentifier =
            switch column {
            case .size: .rightAlignedTextCell
            case .location: .locationCell
            default: .textCell
            }
        let cell =
            outlineView.makeView(withIdentifier: identifier, owner: self) as? FileTextCellView
            ?? FileTextCellView(
                identifier: identifier, alignment: column == .size ? .right : .left,
                lineBreakMode: column == .location ? .byTruncatingMiddle : .byTruncatingTail)
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
        selectionDidChangeForQuickLook()
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
        if effectiveSortColumn == column {
            order.column = column
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
