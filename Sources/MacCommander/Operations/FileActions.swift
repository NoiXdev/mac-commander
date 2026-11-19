import AppKit
import MacCommanderCore

/// The file commands behind the keyboard, the menus and drag and drop. Each entry point
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

    /// Opens one info window per URL through `open` (SwiftUI's `openWindow`, supplied by the caller).
    static func getInfo(_ urls: [URL], open: (URL) -> Void) {
        for url in urls { open(url) }
    }

    /// Opens a shell in each of `folders` with the chosen terminal app (`TerminalApp.effective`): the folder is
    /// handed to the app like a document, so no Automation permission is needed.
    static func openInTerminal(_ folders: [URL], chosen: TerminalApp?, window: NSWindow?) {
        guard !folders.isEmpty else { return }
        let workspace = NSWorkspace.shared
        let app = TerminalApp.effective(chosen: chosen) {
            workspace.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil
        }
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: app.bundleIdentifier) else {
            showAlert([String(localized: "Couldn’t open \(app.displayName): the app isn’t installed.")], window: window)
            return
        }
        workspace.open(folders, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor in
                showAlert([String(localized: "Couldn’t open \(app.displayName): \(message)")], window: window)
            }
        }
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
        } catch is CancellationError {
            // Cancelled from the operations strip: nothing to report.
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

    // MARK: - Archives

    /// Extracts `entries` (paths inside `archive`) into `destination`, asking about conflicts on `window`,
    /// then selects the results. A password error asks for the password and tries again.
    static func extract(_ entries: [String], from archive: URL, into destination: URL, model: BrowserModel, window: NSWindow?)
        async
    {
        guard !entries.isEmpty else { return }
        await runExtraction(of: archive, model: model, window: window) { resolver in
            try await model.operations.extract(entries, from: archive, into: destination, resolver: resolver)
        }
    }

    /// Extracts the whole `archive` into `destination` (several top-level items arrive in a new folder).
    static func extractAll(_ archive: URL, into destination: URL, model: BrowserModel, window: NSWindow?) async {
        await runExtraction(of: archive, model: model, window: window) { resolver in
            try await model.operations.extractAll(archive, into: destination, resolver: resolver)
        }
    }

    /// Runs `extraction` until it doesn't fail for want of a password. On a password error the user is asked
    /// (Cancel stops silently), the password is remembered for the session and the extraction runs again.
    private static func runExtraction(
        of archive: URL, model: BrowserModel, window: NSWindow?,
        _ extraction: (@escaping ConflictResolver) async throws -> TransferResult
    ) async {
        let resolver = ConflictPrompter.shared.resolver(for: window)
        let name = archive.lastPathComponent
        while true {
            do {
                let result = try await extraction(resolver)
                let destinations = result.completed.map(\.destination)
                if !destinations.isEmpty { await model.selectAfterOperation(destinations) }
                if case .failed(let error) = result.outcome {
                    let detail =
                        switch error {
                        case .failed(_, let message): message
                        case .intoItself(let item): String(localized: "“\(item)” can’t be moved into itself.")
                        }
                    showAlert([String(localized: "“\(name)” couldn’t be extracted: \(detail)")], window: window)
                }
                return
            } catch is CancellationError {
                return
            } catch let error as ArchiveError {
                switch error {
                case .passwordRequired, .incorrectPassword:
                    guard
                        let password = await ArchivePasswordSheet.ask(
                            for: archive, incorrect: error == .incorrectPassword, window: window)
                    else { return }
                    await ArchiveCatalog.shared.setPassword(password, for: archive)
                case .cancelled:
                    return
                case .unsupported(let message), .unreadable(let message):
                    showAlert([String(localized: "“\(name)” couldn’t be extracted: \(message)")], window: window)
                    return
                }
            } catch {
                showAlert(
                    [String(localized: "“\(name)” couldn’t be extracted: \(error.localizedDescription)")], window: window)
                return
            }
        }
    }

    /// Opens `items` like ⌘↓ (the caller picks them: one item, or only the files of several). Outside an
    /// archive `model.open`. Inside one, folders navigate and files are extracted through the preview cache
    /// and opened with their default app; changes to those copies aren't written back (archives are read-only).
    /// Nested pure archives (a `.zip` inside the archive) run "Extract To…" instead: Archive Utility would
    /// unpack them into the preview cache, which is deleted permanently.
    static func open(_ items: [FileItem], model: BrowserModel, window: NSWindow?) async {
        guard let archive = model.archiveLocation?.archive else {
            for item in items { await model.open(item) }
            return
        }
        for item in items where item.isDirectory { await model.open(item) }
        // A symlink would be followed out of the cache, e.g. to `~/.zshrc`.
        let links = items.filter { !$0.isDirectory && $0.isSymlink }
        showAlert(
            links.map { String(localized: "“\($0.name)” couldn’t be opened: It’s a link.") }, window: window)
        let candidates = items.filter { !$0.isDirectory && !$0.isSymlink }
        let nested = candidates.filter { ArchiveFormats.isArchive($0.url) }
        let files = candidates.filter { !ArchiveFormats.isArchive($0.url) }
        // Pure string work, no file-system access.
        let nestedEntries = nested.compactMap { ArchivePath.inner(of: $0.url, in: archive) }
        if !nestedEntries.isEmpty {
            let parent = archive.deletingLastPathComponent()
            if let destination = await chooseExtractionFolder(startingAt: parent, window: window) {
                await extract(nestedEntries, from: archive, into: destination, model: model, window: window)
            }
        }
        let entries = files.compactMap { ArchivePath.inner(of: $0.url, in: archive) }
        guard !entries.isEmpty else { return }
        let name = files.count == 1 ? files[0].name : archive.lastPathComponent
        guard let extracted = await extractForPreview(entries, of: archive, name: name, window: window) else { return }
        for url in extracted { PathQueries.openWithDefaultApp(url) }
    }

    /// Extracts `entries` (files) of `archive` through `ArchivePreviewCache` and returns the temporary copies in
    /// the same order. A password error asks for the password and tries again. nil when the user cancelled,
    /// the task was cancelled, or it failed; a failure is reported as "“`name`” couldn’t be opened".
    static func extractForPreview(_ entries: [String], of archive: URL, name: String, window: NSWindow?) async
        -> [URL]?
    {
        while true {
            do {
                return try await ArchivePreviewCache.shared.files(entries, of: archive)
            } catch {
                guard !Task.isCancelled else { return nil }
                switch error {
                case .passwordRequired, .incorrectPassword:
                    guard
                        let password = await ArchivePasswordSheet.ask(
                            for: archive, incorrect: error == .incorrectPassword, window: window),
                        !Task.isCancelled
                    else { return nil }
                    await ArchiveCatalog.shared.setPassword(password, for: archive)
                case .cancelled:
                    return nil
                case .unsupported(let message), .unreadable(let message):
                    showAlert([String(localized: "“\(name)” couldn’t be opened: \(message)")], window: window)
                    return nil
                }
            }
        }
    }

    /// Asks for a destination folder ("Extract To…", "Extract All…"), as a sheet on `window`; nil when cancelled.
    static func chooseExtractionFolder(startingAt directory: URL?, window: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Extract")
        panel.directoryURL = directory
        let response: NSApplication.ModalResponse
        if let window, window.isVisible, window.attachedSheet == nil {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK else { return nil }
        return panel.url
    }

    /// Opens `archive` with Archive Utility, which unpacks it next to itself (or shows its own error).
    static func openWithArchiveUtility(_ archive: URL) {
        let app = URL(fileURLWithPath: "/System/Library/CoreServices/Applications/Archive Utility.app")
        Task { @MainActor in
            if let error = await PathQueries.open([archive], withApplicationAt: app) { NSAlert(error: error).runModal() }
        }
    }

    // MARK: - Drag and drop

    /// The modifier keys held right now, as `DropPolicy` reads them (⌥ forces copy, ⌘ forces move).
    static func currentDropModifiers() -> DropModifiers {
        let flags = NSEvent.modifierFlags
        var modifiers: DropModifiers = []
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    /// The file URLs on a drag pasteboard (non-file URLs and promises are ignored).
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    /// What dropping `sources` into `destination` with `modifiers` does; nil refuses the drop. `DropPolicy`
    /// resolves symlinks and asks for volumes (the paths may be on a network volume), so it runs on the
    /// blocking-I/O queue (`PathQueries.run`).
    static func dropMode(for sources: [URL], into destination: URL, modifiers: DropModifiers) async -> TransferMode? {
        await PathQueries.run { DropPolicy.operation(for: sources, into: destination, modifiers: modifiers) }
    }

    /// `dropMode` while hovering: the drag pasteboard's files with the current modifier keys, answered from
    /// `DropValidationCache` (validation runs on every mouse move). nil (refuse) until the answer is known;
    /// AppKit and SwiftUI ask again on the next mouse move or periodic update. The drop itself re-checks.
    static func hoverDropMode(on pasteboard: NSPasteboard, into destination: URL) -> TransferMode? {
        DropValidationCache.shared.mode(on: pasteboard, into: destination, modifiers: currentDropModifiers())
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

/// Drop validation results for the drag in progress. Validation runs on every mouse move, and each pass would
/// decode the pasteboard and run `DropPolicy` (symlink resolution, lstat, ancestor walk, volume lookups) again.
/// A drag is identified by its pasteboard's name and `changeCount` (a new drag writes the pasteboard anew);
/// within one drag the sources are decoded once and each destination + modifier combination is decided once,
/// off the main actor; until that answer arrives the destination refuses the drop.
@MainActor
final class DropValidationCache {
    static let shared = DropValidationCache()

    private struct Drag: Equatable {
        let pasteboard: NSPasteboard.Name
        let changeCount: Int
    }

    private struct Key: Hashable {
        let destination: String
        let modifiers: Int
    }

    private var drag: Drag?
    private var sources: [URL] = []
    private enum Answer {
        case pending
        case known(TransferMode?)
    }

    private var modes: [Key: Answer] = [:]

    func mode(on pasteboard: NSPasteboard, into destination: URL, modifiers: DropModifiers) -> TransferMode? {
        let current = Drag(pasteboard: pasteboard.name, changeCount: pasteboard.changeCount)
        if current != drag {
            drag = current
            sources = FileActions.fileURLs(on: pasteboard)
            modes = [:]
        }
        guard !sources.isEmpty else { return nil }
        let key = Key(destination: destination.path, modifiers: modifiers.rawValue)
        switch modes[key] {
        case .known(let mode)?: return mode
        case .pending?: return nil
        case nil: break
        }
        modes[key] = .pending
        let sources = sources
        Task {
            let mode = await FileActions.dropMode(for: sources, into: destination, modifiers: modifiers)
            // A new drag started meanwhile has its own answers.
            guard drag == current else { return }
            modes[key] = .known(mode)
        }
        return nil
    }
}
