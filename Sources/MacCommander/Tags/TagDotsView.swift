import AppKit
import MacCommanderCore

/// Up to three overlapping tag color dots, as Finder shows after a file name. Each 8 pt dot has a 1 pt
/// ring cut out of the dots below it, so the row background (alternating, selected) shows through.
final class TagDotsView: NSView {
    private static let dotSize: CGFloat = 8
    private static let ring: CGFloat = 1
    /// Horizontal distance between the starts of neighboring dots.
    private static let step: CGFloat = 5

    var colors: [NSColor] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// The colored tags of `tags`, in order, skipping uncolored ones; at most three.
    @MainActor
    func show(_ tags: [FileTag]) {
        colors = tags.filter { $0.color != .none }.prefix(3).map { TagMenu.color($0.color) }
    }

    override var intrinsicContentSize: NSSize {
        guard !colors.isEmpty else { return NSSize(width: 0, height: Self.dotSize + 2 * Self.ring) }
        let outer = Self.dotSize + 2 * Self.ring
        return NSSize(width: outer + CGFloat(colors.count - 1) * Self.step, height: outer)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !colors.isEmpty else { return }
        let outer = Self.dotSize + 2 * Self.ring
        let colors = colors
        // Drawn into an image of its own: clearing a ring there leaves the view's background untouched.
        let image = NSImage(size: intrinsicContentSize, flipped: false) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            // Later dots are drawn over earlier ones, to their right.
            for (index, color) in colors.enumerated() {
                let ringRect = NSRect(x: CGFloat(index) * Self.step, y: 0, width: outer, height: outer)
                context.compositingOperation = .clear
                NSBezierPath(ovalIn: ringRect).fill()
                context.compositingOperation = .sourceOver
                color.setFill()
                NSBezierPath(ovalIn: ringRect.insetBy(dx: Self.ring, dy: Self.ring)).fill()
            }
            return true
        }
        image.draw(at: NSPoint(x: 0, y: ((bounds.height - outer) / 2).rounded()), from: .zero, operation: .sourceOver, fraction: 1)
    }
}
