import AppKit
import MacCommanderCore
import Observation
import SwiftUI

extension FileListController {
    func applySettings() {
        applyColumnLayout()
        applySortIndicator()
        updateCheckboxStates()
    }

    /// Moves, resizes and hides columns to match the stored layout (checkbox column stays first).
    func applyColumnLayout() {
        isApplyingLayout = true
        defer { isApplyingLayout = false }
        let current = settings.settings
        if let checkbox = checkboxColumn, checkbox.isHidden == current.showCheckboxColumn {
            checkbox.isHidden = !current.showCheckboxColumn
        }
        for (offset, state) in current.columnLayout.columns.enumerated() {
            let target = offset + 1
            let index = outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier(state.column))
            guard index >= 0 else { continue }
            if index != target, target < outlineView.numberOfColumns {
                outlineView.moveColumn(index, toColumn: target)
            }
            guard let column = outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(state.column))
            else { continue }
            if abs(Double(column.width) - state.width) > 0.5 { column.width = CGFloat(state.width) }
            let hidden = isColumnHidden(state)
            if column.isHidden != hidden { column.isHidden = hidden }
        }
    }

    /// Name is always shown; Location only while a search is shown (and the user hasn't hidden it).
    func isColumnHidden(_ state: ColumnState) -> Bool {
        switch state.column {
        case .name: false
        case .location: !state.isVisible || !model.isSearching
        default: !state.isVisible
        }
    }

    /// Writes the outline's column order, widths and visibility to the settings. Outside a search the
    /// Location column is hidden regardless of its setting, which is kept as stored.
    func saveColumnLayout() {
        guard !isApplyingLayout else { return }
        let stored = settings.settings.columnLayout.columns
        let columns = outlineView.tableColumns.compactMap { column -> ColumnState? in
            guard let fileColumn = FileColumn(rawValue: column.identifier.rawValue) else { return nil }
            var isVisible = !column.isHidden
            if fileColumn == .location, !model.isSearching {
                isVisible = stored.first { $0.column == .location }?.isVisible ?? true
            }
            return ColumnState(column: fileColumn, width: Double(column.width), isVisible: isVisible)
        }
        let layout = ColumnLayout(columns: columns)
        if layout != settings.settings.columnLayout {
            settings.settings.columnLayout = layout
        }
    }

    /// The column the list is sorted by: a stored Location sort sorts by name outside a search (one folder's
    /// items share their location, so the model's order is the name order then).
    var effectiveSortColumn: FileColumn {
        let column = settings.settings.sortOrder.column
        return column == .location && !model.isSearching ? .name : column
    }

    func applySortIndicator() {
        let order = settings.settings.sortOrder
        let indicator = NSImage(named: order.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator")
        let sortColumn = effectiveSortColumn
        for column in outlineView.tableColumns {
            let isSortColumn = column.identifier.rawValue == sortColumn.rawValue
            outlineView.setIndicatorImage(isSortColumn ? indicator : nil, in: column)
        }
    }

    @objc func toggleColumnVisibility(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let column = outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(raw))
        else { return }
        column.isHidden.toggle()
        saveColumnLayout()
    }
}

// MARK: - Header menu

extension FileListController: NSMenuDelegate {
    /// Every column except Name (always visible), with a checkmark when shown. Location only while searching.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for column in FileColumn.allCases where column != .name && (column != .location || model.isSearching) {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumnVisibility(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            let isHidden = outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column))?.isHidden ?? true
            item.state = isHidden ? .off : .on
            menu.addItem(item)
        }
    }
}
