import AppKit
import MacCommanderCore
import Observation
import SwiftUI

extension FileListController {
    func node(atRow row: Int) -> FileNode? {
        outlineView.item(atRow: row) as? FileNode
    }

    /// The selected rows' nodes, in row order.
    var selectedNodes: [FileNode] {
        outlineView.selectedRowIndexes.compactMap { node(atRow: $0) }
    }

    // MARK: - Selection

    /// Selects the visible rows whose URLs are in `model.selection`.
    func syncSelectionFromModel() {
        let wanted = model.selection
        syncedSelection = wanted
        var rows = IndexSet()
        if !wanted.isEmpty {
            for row in 0..<outlineView.numberOfRows {
                if let node = node(atRow: row), wanted.contains(node.url) { rows.insert(row) }
            }
        }
        if rows != outlineView.selectedRowIndexes {
            applyingChanges { outlineView.selectRowIndexes(rows, byExtendingSelection: false) }
        }
        updateCheckboxStates()
    }

    func writeSelectionToModel() {
        guard showsCurrentFolder else { return }
        var urls = Set<URL>()
        for row in outlineView.selectedRowIndexes {
            if let node = node(atRow: row) { urls.insert(node.url) }
        }
        syncedSelection = urls
        if model.selection != urls { model.selection = urls }
    }

    /// Updates the header checkbox and the visible row checkboxes from `selectedRowIndexes`.
    func updateCheckboxStates() {
        let selected = outlineView.selectedRowIndexes
        guard let column = checkboxColumn else { return }
        if let header = column.headerCell as? CheckboxHeaderCell {
            let state: NSControl.StateValue =
                selected.isEmpty ? .off : (selected.count == outlineView.numberOfRows ? .on : .mixed)
            if header.checkState != state {
                header.checkState = state
                outlineView.headerView?.needsDisplay = true
            }
        }
        guard !column.isHidden else { return }
        let columnIndex = outlineView.column(withIdentifier: .checkboxColumn)
        guard let visible = Range(outlineView.rows(in: outlineView.visibleRect)) else { return }
        for row in visible {
            if let cell = outlineView.view(atColumn: columnIndex, row: row, makeIfNecessary: false)
                as? CheckboxCellView
            {
                cell.checkbox.state = selected.contains(row) ? .on : .off
            }
        }
    }

    func toggleSelectAll() {
        if outlineView.numberOfRows > 0, outlineView.selectedRowIndexes.count == outlineView.numberOfRows {
            outlineView.deselectAll(nil)
        } else {
            outlineView.selectAll(nil)
        }
    }

    // MARK: - Opening

    @objc func openClickedRow() {
        let row = outlineView.clickedRow
        guard showsCurrentFolder, row >= 0, let node = node(atRow: row) else { return }
        let item = node.item
        Task { await model.open(item) }
    }

    /// ⌘↓ and File ▸ Open (⌘O): a single item opens (folders navigate); with several, only the
    /// files are opened. Not while a name is being edited.
    func openSelection() {
        guard showsCurrentFolder, rename.session == nil else { return }
        let items = selectedItems
        guard !items.isEmpty else { return }
        let toOpen = items.count == 1 ? items : items.filter { !$0.isDirectory }
        Task {
            for item in toOpen { await model.open(item) }
        }
    }
}

// MARK: - Selection contract

extension FileListController {
    /// The items of the selected rows in row order, including rows of inline-expanded subfolders.
    /// Keyboard and menu commands act on this; nothing else reads the outline's selection for that.
    var selectedItems: [FileItem] {
        outlineView.selectedRowIndexes.compactMap { node(atRow: $0)?.item }
    }

    /// What a context-menu command on `row` acts on: the whole selection if the row is selected,
    /// otherwise just that row; nothing for `row < 0`.
    func actionItems(forClickedRow row: Int) -> [FileItem] {
        guard row >= 0 else { return [] }
        if outlineView.isRowSelected(row) { return selectedItems }
        return node(atRow: row).map { [$0.item] } ?? []
    }
}
