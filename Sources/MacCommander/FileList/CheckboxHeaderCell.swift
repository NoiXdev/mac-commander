import AppKit

/// Header cell of the checkbox column: a tri-state checkbox. `.on` when every row is selected,
/// `.mixed` when some are, `.off` when none. Clicks are handled by the controller.
final class CheckboxHeaderCell: NSTableHeaderCell {
    // Only a value type is stored: NSCell copies are made with NSCopyObject, which doesn't
    // retain object references held in Swift properties.
    var checkState: NSControl.StateValue = .off

    override init(textCell string: String) {
        super.init(textCell: string)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let checkbox = NSButtonCell()
        checkbox.setButtonType(.switch)
        checkbox.allowsMixedState = true
        checkbox.title = ""
        checkbox.imagePosition = .imageOnly
        checkbox.state = checkState
        let size = checkbox.cellSize
        let rect = NSRect(
            x: (cellFrame.midX - size.width / 2).rounded(),
            y: (cellFrame.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height)
        checkbox.draw(withFrame: rect, in: controlView)
    }
}
