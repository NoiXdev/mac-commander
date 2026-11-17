import AppKit
import Quartz
import SwiftUI

/// A Quick Look preview of a real file or folder, embedded in the preview panel.
///
/// `QLPreviewView` is used as is (no subclass). It is not closed with its window but by
/// `dismantleNSView`, when SwiftUI removes it (the panel hides or shows other content).
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        // Setting the item again reloads the preview: only when it actually changed.
        if view.previewItem?.previewItemURL != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
