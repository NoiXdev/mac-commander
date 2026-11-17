import AppKit
import Quartz

/// The file list's outline view. Keyboard shortcuts that act on the selection are forwarded to
/// the controller through closures; ← and → (collapse / expand) stay the `NSOutlineView` default.
final class FileOutlineView: NSOutlineView {
    /// ⌘↓: open the selected items.
    var onOpenSelection: (() -> Void)?
    /// ⌘↑: go to the enclosing folder (also reachable through the Go menu).
    var onGoUp: (() -> Void)?
    /// Return: rename the single selected row.
    var onRename: (() -> Void)?
    /// Space: show or hide Quick Look.
    var onToggleQuickLook: (() -> Void)?
    /// Builds the context menu after the selection was adjusted; `row` is -1 for empty space.
    /// Returning nil shows no menu (e.g. while the rows belong to a folder that is being left).
    var contextMenu: ((_ row: Int) -> NSMenu?)?
    /// False while rows must not be acted on; checked before a right-click changes the selection.
    var allowsInteraction: () -> Bool = { true }
    /// Gets the Quick Look panel while this view is in the responder chain.
    var quickLook: QuickLookController?

    /// A click in the checkbox column toggles only that row, like ⌘-click. Handled here rather
    /// than by the checkbox button, because the table would change the selection first.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let column = column(at: point)
        // Ctrl-click opens the context menu (through `menu(for:)`), also in the checkbox column.
        guard row >= 0, column >= 0, tableColumns[column].identifier == .checkboxColumn,
            !event.modifierFlags.contains(.control)
        else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        if isRowSelected(row) {
            deselectRow(row)
        } else {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: true)
        }
    }

    /// Right-click: on empty space, deselect all; on an unselected row, select only that row; on a
    /// selected row, keep the whole selection.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard allowsInteraction() else { return nil }
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row < 0 {
            deselectAll(nil)
        } else if !isRowSelected(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        guard let menu = contextMenu?(row) else { return nil }
        // Like Finder, a right-click focuses the list, so e.g. Quick Look finds it as controller.
        window?.makeFirstResponder(self)
        return menu
    }

    /// File ▸ Open (⌘O), sent through the responder chain.
    @objc func openSelectedItems(_ sender: Any?) {
        onOpenSelection?()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.isDisjoint(with: [.command, .option, .control, .shift]) {
            switch event.keyCode {
            case 36, 76:  // Return, keypad Enter
                onRename?()
                return
            case 49:  // Space
                onToggleQuickLook?()
                return
            default:
                break
            }
        }
        if flags.contains(.command), !flags.contains(.option), !flags.contains(.control) {
            switch event.specialKey {
            case .downArrow?:
                onOpenSelection?()
                return
            case .upArrow?:
                onGoUp?()
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    // MARK: - Quick Look panel control

    // Declared on NSObject without actor isolation; the panel calls them on the main thread.

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { quickLook != nil && allowsInteraction() }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLook?.beginControl(panel) }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLook?.endControl(panel) }
    }
}
