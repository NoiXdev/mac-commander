import AppKit
import Quartz

/// File commands that arrive at the outline view through the responder chain (menu bar and keyboard).
enum FileCommand {
    case copy, cut, paste, pasteAsMove, duplicate, moveToTrash, undo, getInfo, copyPath
}

/// Performs and validates the `FileCommand`s for an outline view (the file list controller).
@MainActor
protocol FileCommandHandler: AnyObject {
    func canPerform(_ command: FileCommand) -> Bool
    func perform(_ command: FileCommand)
    /// The title of the operation ⌘Z would reverse, e.g. "Move to Trash".
    var undoTitle: String? { get }
    /// True while a name is edited inline: the commands then belong to the text (see `responds(to:)`).
    var isEditingText: Bool { get }
}

/// The file list's outline view. Keyboard shortcuts that act on the selection are forwarded to
/// the controller through closures; ← and → (collapse / expand) stay the `NSOutlineView` default.
final class FileOutlineView: NSOutlineView, NSMenuItemValidation {
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
    /// Handles the file commands below.
    weak var commandHandler: FileCommandHandler?

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

    // MARK: - File commands

    // Edit ▸ Copy, Cut, Paste and Undo send the standard selectors; the rest come from `BrowserCommands`.

    @objc func copy(_ sender: Any?) { commandHandler?.perform(.copy) }
    @objc func cut(_ sender: Any?) { commandHandler?.perform(.cut) }
    @objc func paste(_ sender: Any?) { commandHandler?.perform(.paste) }
    @objc func undo(_ sender: Any?) { commandHandler?.perform(.undo) }
    @objc func pasteAsMove(_ sender: Any?) { commandHandler?.perform(.pasteAsMove) }
    @objc func duplicate(_ sender: Any?) { commandHandler?.perform(.duplicate) }
    @objc func moveToTrash(_ sender: Any?) { commandHandler?.perform(.moveToTrash) }
    @objc func getInfo(_ sender: Any?) { commandHandler?.perform(.getInfo) }
    @objc func copyPath(_ sender: Any?) { commandHandler?.perform(.copyPath) }

    private nonisolated static let commandSelectors: [Selector: FileCommand] = [
        #selector(copy(_:)): .copy,
        #selector(cut(_:)): .cut,
        #selector(paste(_:)): .paste,
        #selector(undo(_:)): .undo,
        #selector(pasteAsMove(_:)): .pasteAsMove,
        #selector(duplicate(_:)): .duplicate,
        #selector(moveToTrash(_:)): .moveToTrash,
        #selector(getInfo(_:)): .getInfo,
        #selector(copyPath(_:)): .copyPath,
    ]

    /// While a name is edited inline, the field editor sits inside this view, so commands it doesn't
    /// handle itself (e.g. `undo:`, which the window's undo manager serves, or ⌘⌫) would land here.
    /// Declining them sends them on to the window instead of acting on files.
    /// (Declared on NSObject without actor isolation; the responder chain asks on the main thread.)
    override func responds(to aSelector: Selector!) -> Bool {
        if let aSelector, Self.commandSelectors[aSelector] != nil, Thread.isMainThread {
            let declines = MainActor.assumeIsolated { commandHandler?.isEditingText ?? true }
            if declines { return false }
        }
        return super.responds(to: aSelector)
    }

    /// Enables the AppKit menu items (Edit ▸ Copy, Cut, Paste, Undo) and names Undo after its operation.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action, let command = Self.commandSelectors[action] else { return true }
        guard let commandHandler, commandHandler.canPerform(command) else { return false }
        if command == .undo, let title = commandHandler.undoTitle {
            menuItem.title = String(localized: "Undo \(title)")
        }
        return true
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
