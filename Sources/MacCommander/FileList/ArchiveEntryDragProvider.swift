import AppKit
import MacCommanderCore
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Entries dragged out of an archive, for MacCommander's own drop targets (see `ArchiveDragPayload`).
    static let archiveEntries = NSPasteboard.PasteboardType("dev.noix.MacCommander.archive-entries")
}

extension UTType {
    /// `NSPasteboard.PasteboardType.archiveEntries` as a UTType, for SwiftUI `onDrop`.
    /// Declared in Info.plist (`UTExportedTypeDeclarations`).
    static let archiveEntries = UTType(exportedAs: "dev.noix.MacCommander.archive-entries")
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
        // Not `super.init(fileType:delegate:)`: that convenience initializer calls `init()` on self,
        // which this subclass doesn't provide, and Swift traps. Set the two properties instead.
        super.init()
        fileType = type.identifier
        delegate = ArchiveDragDelegate.shared
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
/// existing item fails the promise) off the main thread, at most two at a time. The password is the
/// session's remembered one; an encrypted archive without one (or with a wrong one) asks for it app-modally
/// and tries again. Cancel fails the promise with `userCancelled`; other errors are shown by the receiver, inside
/// a sentence naming the entry (`ArchiveExtractor.promiseError`).
final class ArchiveDragDelegate: NSObject, NSFilePromiseProviderDelegate, Sendable {
    static let shared = ArchiveDragDelegate()

    /// Promises are written here, never on the main queue. Each operation blocks until its extraction
    /// finished, so the limit bounds the bsdtar runs of a many-row drag.
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MacCommander archive drag"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider as? ArchiveEntryDragProvider)?.entryName ?? L10n.string("name.untitled", "Untitled")
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }

    /// Called on `queue`. Blocks this operation (never the main thread) until the extraction finished.
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
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            completion.call(await Self.write(entry, of: archive, to: url))
            done.signal()
        }
        if Thread.isMainThread { return }
        done.wait()
    }

    /// Extracts `entry` to `url`; on a password error asks for the password and tries again.
    /// Returns the error to complete the promise with, or nil on success.
    @concurrent private static func write(_ entry: String, of archive: URL, to url: URL) async -> Error? {
        while true {
            let password = await ArchiveCatalog.shared.password(for: archive)
            do {
                try await ArchiveExtractor.extract(entry, from: archive, to: url, password: password)
                return nil
            } catch let error as ArchiveError where error == .passwordRequired || error == .incorrectPassword {
                guard
                    await PromisePassword.ask(
                        for: archive, tried: password, incorrect: error == .incorrectPassword)
                else { return CocoaError(.userCancelled) }
            } catch {
                return ArchiveExtractor.promiseError(name: (entry as NSString).lastPathComponent, error)
            }
        }
    }
}

/// The password prompt for promises: one at a time per archive, so the rows of one drag share a single
/// prompt. A promise that failed with a password another promise has replaced meanwhile just tries again.
@MainActor
private enum PromisePassword {
    private static var prompts: [String: Task<Bool, Never>] = [:]

    /// Whether a (new) password is set for `archive`; false when the user cancelled.
    static func ask(for archive: URL, tried: String?, incorrect: Bool) async -> Bool {
        let key = archive.standardizedFileURL.path
        if let running = prompts[key] { return await running.value }
        if await ArchiveCatalog.shared.password(for: archive) != tried { return true }
        if let running = prompts[key] { return await running.value }
        let prompt = Task { @MainActor () -> Bool in
            defer { prompts[key] = nil }
            // No window: app-modal, since the drop went to another app.
            NSApp.activate()
            guard let password = await ArchivePasswordSheet.ask(for: archive, incorrect: incorrect, window: nil)
            else { return false }
            await ArchiveCatalog.shared.setPassword(password, for: archive)
            return true
        }
        prompts[key] = prompt
        return await prompt.value
    }
}

/// Carries a promise's completion handler into the extraction task. AppKit accepts the call from any thread.
private final class PromiseCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void

    init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }

    func call(_ error: Error?) { handler(error) }
}
