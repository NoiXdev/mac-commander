import AppKit

/// The file list's outline view. Keyboard shortcuts that act on the selection are forwarded to
/// the controller through closures; ← and → (collapse / expand) stay the `NSOutlineView` default.
final class FileOutlineView: NSOutlineView {
    /// ⌘↓: open the selected items.
    var onOpenSelection: (() -> Void)?
    /// ⌘↑: go to the enclosing folder (also reachable through the Go menu).
    var onGoUp: (() -> Void)?

    /// A click in the checkbox column toggles only that row, like ⌘-click. Handled here rather
    /// than by the checkbox button, because the table would change the selection first.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let column = column(at: point)
        guard row >= 0, column >= 0, tableColumns[column].identifier == .checkboxColumn else {
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

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
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
}
