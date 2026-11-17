import AppKit
import MacCommanderCore

/// The file commands behind the keyboard, the menus and (later) drag and drop. Each entry point
/// reports its errors in one alert, as a sheet on `window` when one is given.
@MainActor
enum FileActions {
    static func copy(_ items: [FileItem], clipboard: FileClipboard) {
        guard !items.isEmpty else { return }
        clipboard.copy(items.map(\.url))
    }

    /// Only marks the items; they move when pasted.
    static func cut(_ items: [FileItem], clipboard: FileClipboard) {
        guard !items.isEmpty else { return }
        clipboard.cut(items.map(\.url))
    }

    /// The POSIX paths of `items`, one per line, as plain text on the general pasteboard.
    static func copyPath(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(items.map(\.url.path).joined(separator: "\n"), forType: .string)
    }

    /// Placeholder until the info panel arrives (Task 11).
    static func getInfo(_ urls: [URL]) {
        NSSound.beep()
    }

    /// Selects `urls` in a Finder window.
    static func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Zips `items` (one shared parent) and selects the archive.
    static func compress(_ items: [FileItem], model: BrowserModel, window: NSWindow?) async {
        guard !items.isEmpty else { return }
        do {
            let zip = try await model.operations.compress(items.map(\.url))
            await model.selectAfterOperation([zip])
        } catch {
            showAlert([String(localized: "The items couldn’t be compressed: \(error.localizedDescription)")], window: window)
        }
    }

    /// Copies (or, after a cut or with `forceMove`, moves) the pasteboard's files into `destination`.
    static func paste(
        into destination: URL, forceMove: Bool, model: BrowserModel, clipboard: FileClipboard, window: NSWindow?
    ) async {
        let urls = clipboard.fileURLs
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        let mode = clipboard.pasteMode(forceMove: forceMove)
        // Spend the cut before the transfer runs, so a second ⌘V meanwhile copies instead of moving again.
        clipboard.didPaste(mode: mode)
        let result = await transfer(urls, into: destination, mode: mode, model: model, window: window)
        // The moved items' old URLs are gone: a further ⌘V copies them from their new place.
        if mode == .move { clipboard.didMove(to: result.completed.map(\.destination)) }
    }

    /// Copies or moves `urls` into `destination`, asking about conflicts on `window`, then selects the results.
    @discardableResult
    static func transfer(_ urls: [URL], into destination: URL, mode: TransferMode, model: BrowserModel, window: NSWindow?)
        async -> TransferResult
    {
        let resolver = ConflictPrompter.shared.resolver(for: window)
        let result = await model.operations.transfer(urls, into: destination, mode: mode, resolver: resolver)
        await finish(result, mode: mode, model: model, window: window)
        return result
    }

    static func duplicate(_ items: [FileItem], model: BrowserModel, window: NSWindow? = nil) async {
        guard !items.isEmpty else { return }
        let result = await model.operations.duplicate(items.map(\.url))
        await finish(result, mode: .copy, model: model, window: window)
    }

    static func moveToTrash(_ items: [FileItem], model: BrowserModel, window: NSWindow? = nil) async {
        guard !items.isEmpty else { return }
        let result = await model.operations.trash(items.map(\.url))
        let messages = result.failures.map { failure in
            String(localized: "“\(failure.url.lastPathComponent)” couldn’t be moved to the Trash: \(failure.message)")
        }
        showAlert(messages, window: window)
    }

    /// Reverses the newest file operation and selects what it restored.
    static func undo(model: BrowserModel, window: NSWindow? = nil) async {
        do {
            let restored = try await model.operations.performUndo()
            if !restored.isEmpty { await model.selectAfterOperation(restored) }
        } catch {
            switch error {
            case .nothingToUndo:
                NSSound.beep()
            case .itemChanged(let name):
                showAlert(
                    [String(localized: "“\(name)” can’t be restored because it was changed or another item is in its place.")],
                    window: window)
            case .failed(let name, let message):
                showAlert([String(localized: "“\(name)” couldn’t be restored: \(message)")], window: window)
            }
        }
    }

    // MARK: - Results

    /// Selects what was transferred and reports a failure. Stopped, cancelled and skipped items need no alert.
    private static func finish(_ result: TransferResult, mode: TransferMode, model: BrowserModel, window: NSWindow?)
        async
    {
        let destinations = result.completed.map(\.destination)
        if !destinations.isEmpty { await model.selectAfterOperation(destinations) }
        guard case .failed(let error) = result.outcome else { return }
        showAlert([message(for: error, mode: mode)], window: window)
    }

    private static func message(for error: TransferError, mode: TransferMode) -> String {
        switch (error, mode) {
        case (.intoItself(let name), .copy):
            String(localized: "“\(name)” can’t be copied into itself.")
        case (.intoItself(let name), .move):
            String(localized: "“\(name)” can’t be moved into itself.")
        case (.failed(let name, let message), .copy):
            String(localized: "“\(name)” couldn’t be copied: \(message)")
        case (.failed(let name, let message), .move):
            String(localized: "“\(name)” couldn’t be moved: \(message)")
        }
    }

    /// One alert for all `messages` (none: no alert). A single message is the alert's text; several are
    /// listed below a summary.
    static func showAlert(_ messages: [String], window: NSWindow?) {
        guard let first = messages.first else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if messages.count == 1 {
            alert.messageText = first
        } else {
            alert.messageText = String(localized: "\(messages.count) items couldn’t be processed.")
            alert.informativeText = messages.joined(separator: "\n")
        }
        if let window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
