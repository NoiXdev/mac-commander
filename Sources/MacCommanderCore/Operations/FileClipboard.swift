import AppKit
import Observation

/// Copy/cut intent on top of the system pasteboard. Cut is only a marker: nothing moves until paste.
@MainActor @Observable public final class FileClipboard {
    @ObservationIgnored private let pasteboard: NSPasteboard
    /// `changeCount` right after this app's cut; any later pasteboard write invalidates it.
    @ObservationIgnored private var cutChangeCount: Int?
    /// `changeCount` when the items now being moved were put on the pasteboard (cut) or pasted
    /// (move-paste); `didMove(to:)` rewrites the pasteboard only while it still matches.
    @ObservationIgnored private var moveChangeCount: Int?

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func copy(_ urls: [URL]) {
        write(urls)
        cutChangeCount = nil
        moveChangeCount = nil
    }

    public func cut(_ urls: [URL]) {
        write(urls)
        cutChangeCount = pasteboard.changeCount
        moveChangeCount = cutChangeCount
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
        guard mode == .move else { return }
        cutChangeCount = nil
        moveChangeCount = pasteboard.changeCount
    }

    /// After a move-paste: the moved items' old URLs are gone, so the pasteboard now holds their new
    /// places as a copy (a further paste copies them). Does nothing if anything was written to the
    /// pasteboard since the cut or paste (e.g. a newer copy by the user).
    public func didMove(to destinations: [URL]) {
        guard let moveChangeCount, moveChangeCount == pasteboard.changeCount else { return }
        self.moveChangeCount = nil
        guard !destinations.isEmpty else { return }
        write(destinations)
        cutChangeCount = nil
    }

    private func write(_ urls: [URL]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }
}
