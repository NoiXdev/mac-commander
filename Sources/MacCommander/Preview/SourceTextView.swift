import AppKit
import SwiftUI

/// Read-only, selectable, monospaced text in a scroll view. An `NSTextView` because SwiftUI `Text` is
/// slow for the large files the preview panel shows (up to 5 MB).
struct SourceTextView: NSViewRepresentable {
    let text: String

    final class Coordinator {
        /// The text last put into the view, so an unrelated SwiftUI update doesn't reset it.
        var text: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.importsGraphics = false
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
            textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            textView.textColor = .textColor
            textView.textContainerInset = NSSize(width: 8, height: 8)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.text != text, let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.text = text
        textView.string = text
        textView.scrollToBeginningOfDocument(nil)
    }
}
