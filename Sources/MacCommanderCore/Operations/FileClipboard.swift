import AppKit
import Observation

/// Copy/cut intent on top of the system pasteboard. Cut is only a marker: nothing moves until paste.
@MainActor @Observable public final class FileClipboard {
    @ObservationIgnored private let pasteboard: NSPasteboard
    /// `changeCount` right after this app's cut; any later pasteboard write invalidates it.
    @ObservationIgnored private var cutChangeCount: Int?

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func copy(_ urls: [URL]) {
        write(urls)
        cutChangeCount = nil
    }

    public func cut(_ urls: [URL]) {
        write(urls)
        cutChangeCount = pasteboard.changeCount
    }

    /// File URLs on the pasteboard, also those put there by Finder.
    public var fileURLs: [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    /// `.move` if `forceMove` or the pasteboard still holds this app's cut; otherwise `.copy`.
    public func pasteMode(forceMove: Bool) -> TransferMode {
        if forceMove { return .move }
        if let cutChangeCount, cutChangeCount == pasteboard.changeCount { return .move }
        return .copy
    }

    /// After a move-paste the cut is spent (Finder: cut is one-shot).
    public func didPaste(mode: TransferMode) {
        if mode == .move { cutChangeCount = nil }
    }

    private func write(_ urls: [URL]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }
}
