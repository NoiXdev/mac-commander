import AppKit
import MacCommanderCore
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Entries dragged out of an archive, for MacCommander's own drop targets (see `ArchiveDragPayload`).
    static let archiveEntries = NSPasteboard.PasteboardType("dev.noix.MacCommander.archive-entries")
}

extension UTType {
    /// `NSPasteboard.PasteboardType.archiveEntries` as a UTType, for SwiftUI `onDrop`.
    static let archiveEntries = UTType(importedAs: "dev.noix.MacCommander.archive-entries")
}

/// What an archive drag carries for MacCommander's own drop targets: the archive and all dragged entries
/// (inner paths, top-level only). Every provider of one drag writes the same payload; receivers read the
/// first item's.
struct ArchiveDragPayload: Equatable {
    let archive: URL
    let entries: [String]

    var propertyList: [String: Any] { ["archive": archive.path, "entries": entries] }

    init(archive: URL, entries: [String]) {
        self.archive = archive
        self.entries = entries
    }

    /// The payload on `pasteboard` (its first item), or nil when it carries none.
    init?(pasteboard: NSPasteboard) {
        guard
            let list = pasteboard.propertyList(forType: .archiveEntries) as? [String: Any],
            let path = list["archive"] as? String, let entries = list["entries"] as? [String], !entries.isEmpty
        else { return nil }
        self.init(archive: URL(fileURLWithPath: path, isDirectory: false), entries: entries)
    }

    /// True when `pasteboard` carries an archive drag (a cheap type check, for hover validation).
    static func isOn(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.types?.contains(.archiveEntries) == true
    }
}

/// One dragged archive entry. Finder, the Desktop and other apps get a file promise, written by
/// `ArchiveDragDelegate` (the entry is extracted when dropped). MacCommander's list and sidebar read the
/// `archiveEntries` type instead and extract with the conflict dialog, progress and undo.
/// Virtual URLs are never written as file URLs.
final class ArchiveEntryDragProvider: NSFilePromiseProvider {
    let archive: URL
    /// The entry's path inside `archive`.
    let entry: String
    /// The whole drag's payload (all dragged entries), the same for every provider of the drag.
    let payload: ArchiveDragPayload

    init(archive: URL, entry: String, isDirectory: Bool, payload: ArchiveDragPayload) {
        self.archive = archive
        self.entry = entry
        self.payload = payload
        let type: UTType =
            isDirectory
            ? .folder
            : UTType(filenameExtension: (entry as NSString).pathExtension) ?? .data
        super.init(fileType: type.identifier, delegate: ArchiveDragDelegate.shared)
    }

    /// The name of the promised item: the entry's last path component.
    var entryName: String { entry.split(separator: "/").last.map(String.init) ?? entry }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.archiveEntries]
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard)
        -> NSPasteboard.WritingOptions
    {
        type == .archiveEntries ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .archiveEntries ? payload.propertyList : super.pasteboardPropertyList(forType: type)
    }
}

/// Writes archive entry promises: extracts the entry to exactly the promised URL (never overwriting; an
/// existing item fails the promise) off the main thread. The password is the session's remembered one; an
/// encrypted archive without one fails with "password required" (the receiver shows the error).
final class ArchiveDragDelegate: NSObject, NSFilePromiseProviderDelegate, Sendable {
    static let shared = ArchiveDragDelegate()

    /// Promises are written here, never on the main queue.
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MacCommander archive drag"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider as? ArchiveEntryDragProvider)?.entryName ?? String(localized: "Untitled")
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let provider = filePromiseProvider as? ArchiveEntryDragProvider else {
            completionHandler(CocoaError(.fileWriteUnknown))
            return
        }
        let archive = provider.archive
        let entry = provider.entry
        let completion = PromiseCompletion(completionHandler)
        Task.detached {
            do {
                let password = await ArchiveCatalog.shared.password(for: archive)
                try await ArchiveExtractor.extract(entry, from: archive, to: url, password: password)
                completion.call(nil)
            } catch {
                completion.call(error)
            }
        }
    }
}

/// Carries a promise's completion handler into the extraction task. AppKit accepts the call from any thread.
private final class PromiseCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void

    init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }

    func call(_ error: Error?) { handler(error) }
}
