import AppKit

/// The file list's outline view. Keyboard shortcuts that act on the selection are forwarded to
/// the controller through closures; ← and → (collapse / expand) stay the `NSOutlineView` default.
final class FileOutlineView: NSOutlineView {
    /// ⌘↓: open the selected items.
    var onOpenSelection: (() -> Void)?
    /// ⌘↑: go to the enclosing folder (also reachable through the Go menu).
    var onGoUp: (() -> Void)?

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
