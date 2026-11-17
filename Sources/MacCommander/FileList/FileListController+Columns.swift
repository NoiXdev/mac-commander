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
            let hidden = state.column != .name && !state.isVisible
            if column.isHidden != hidden { column.isHidden = hidden }
        }
    }

    /// Writes the outline's column order, widths and visibility to the settings.
    func saveColumnLayout() {
        guard !isApplyingLayout else { return }
        let columns = outlineView.tableColumns.compactMap { column -> ColumnState? in
            guard let fileColumn = FileColumn(rawValue: column.identifier.rawValue) else { return nil }
            return ColumnState(column: fileColumn, width: Double(column.width), isVisible: !column.isHidden)
        }
        let layout = ColumnLayout(columns: columns)
        if layout != settings.settings.columnLayout {
            settings.settings.columnLayout = layout
        }
    }

    func applySortIndicator() {
        let order = settings.settings.sortOrder
        let indicator = NSImage(named: order.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator")
        for column in outlineView.tableColumns {
            let isSortColumn = column.identifier.rawValue == order.column.rawValue
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
    /// Every column except Name (always visible), with a checkmark when shown.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for column in FileColumn.allCases where column != .name {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumnVisibility(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            let isHidden = outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column))?.isHidden ?? true
            item.state = isHidden ? .off : .on
            menu.addItem(item)
        }
    }
}
