import Foundation
import Observation
import Synchronization

/// A running file operation as the UI shows it.
public struct FileOperationStatus: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    /// nil = indeterminate.
    public var progress: TransferProgress?
}

/// Runs file operations app-wide: publishes their progress, records undo and announces changed folders.
///
/// Every operation runs in its own `Task` on its own thread (`SerialQueueExecutor`), listed in
/// `operations` while it runs. When it ends, completed work is pushed as one undo record — including the
/// completed part of a stopped, cancelled or failed transfer — and `foldersDidChange` is posted.
@MainActor @Observable
public final class FileOperationCenter {
    /// Posted (object: the center) after every operation and undo. `userInfo["folders"]` holds the
    /// affected parent folders as `[URL]`, standardized and de-duplicated.
    public static let foldersDidChange = Notification.Name("FileOperationCenter.foldersDidChange")

    public let undo: FileUndoStack
    public private(set) var operations: [FileOperationStatus] = []

    @ObservationIgnored private let trashItem: @Sendable (URL) throws -> URL
    @ObservationIgnored private let sameVolume: @Sendable (URL, URL) -> Bool
    /// False forces real data copies (tests).
    @ObservationIgnored private let allowClone: Bool
    /// Session passwords for extraction.
    @ObservationIgnored let catalog: ArchiveCatalog
    /// Cancels the running operation with that id.
    @ObservationIgnored private var cancellers: [UUID: @Sendable () -> Void] = [:]

    public convenience init(
        undo: FileUndoStack = FileUndoStack(), trash: @escaping @Sendable (URL) throws -> URL = Trasher.systemTrash,
        sameVolume: @escaping @Sendable (URL, URL) -> Bool = FileTransfer.isSameVolume,
        catalog: ArchiveCatalog = .shared
    ) {
        self.init(undo: undo, trash: trash, sameVolume: sameVolume, allowClone: true, catalog: catalog)
    }

    init(
        undo: FileUndoStack, trash: @escaping @Sendable (URL) throws -> URL,
        sameVolume: @escaping @Sendable (URL, URL) -> Bool = FileTransfer.isSameVolume, allowClone: Bool,
        catalog: ArchiveCatalog = .shared
    ) {
        self.undo = undo
        self.trashItem = trash
        self.sameVolume = sameVolume
        self.allowClone = allowClone
        self.catalog = catalog
    }

    // MARK: - Operations

    public func transfer(
        _ sources: [URL], into destination: URL, mode: TransferMode, resolver: @escaping ConflictResolver
    ) async -> TransferResult {
        let trash = trashItem
        let sameVolume = sameVolume
        let allowClone = allowClone
        let title = Self.transferTitle(sources, into: destination, mode: mode)
        let result = await run(kind: "transfer", title: title) { progress in
            await FileTransfer.run(
                sources, into: destination, mode: mode, resolver: resolver, trash: trash, sameVolume: sameVolume,
                allowClone: allowClone, progress: progress)
        }
        // A move into the item's own folder changed nothing: it is neither undone nor counted in the title.
        let changed = result.completed.filter { $0.destination != $0.source }
        if !changed.isEmpty || !result.replaced.isEmpty {
            undo.push(
                FileUndoRecord(
                    action: .transferred(mode, changed, replaced: result.replaced),
                    title: Self.undoTitle(mode: mode, completed: changed)))
        }
        postFoldersDidChange([destination] + sources.map { $0.deletingLastPathComponent() })
        return result
    }

    /// Copies each item into its own parent folder (`name copy.ext`), one transfer per parent.
    /// Progress restarts for each parent folder.
    public func duplicate(_ items: [URL]) async -> TransferResult {
        var groups: [(parent: URL, items: [URL])] = []
        for item in items {
            let parent = item.deletingLastPathComponent()
            if let index = groups.firstIndex(where: { Self.key($0.parent) == Self.key(parent) }) {
                groups[index].items.append(item)
            } else {
                groups.append((parent, [item]))
            }
        }
        let trash = trashItem
        let sameVolume = sameVolume
        let allowClone = allowClone
        let plan = groups
        let result = await run(kind: "duplicate", title: Self.duplicateTitle(items)) { progress in
            var merged = TransferResult(completed: [], replaced: [], skipped: [], outcome: .finished)
            for group in plan {
                // Copying into the item's own folder always picks a free copy name; there are no conflicts.
                let part = await FileTransfer.run(
                    group.items, into: group.parent, mode: .copy,
                    resolver: { _ in ConflictDecision(choice: .keepBoth, applyToAll: true) },
                    trash: trash, sameVolume: sameVolume, allowClone: allowClone, progress: progress)
                merged.completed += part.completed
                merged.replaced += part.replaced
                merged.skipped += part.skipped
                merged.outcome = part.outcome
                if part.outcome != .finished { break }
            }
            return merged
        }
        if !result.completed.isEmpty {
            undo.push(
                FileUndoRecord(
                    action: .transferred(.copy, result.completed, replaced: result.replaced),
                    title: String(localized: "Duplicate")))
        }
        postFoldersDidChange(groups.map(\.parent))
        return result
    }

    public func trash(_ items: [URL]) async -> TrashResult {
        let trash = trashItem
        let result = await run(kind: "trash", title: Self.trashTitle(items)) { _ in
            await Trasher.trash(items, using: trash)
        }
        if !result.trashed.isEmpty {
            undo.push(FileUndoRecord(action: .trashed(result.trashed), title: String(localized: "Move to Trash")))
        }
        postFoldersDidChange(result.trashed.map { $0.original.deletingLastPathComponent() })
        return result
    }

    /// Zips `items` (all in one folder) next to them; see `Compressor.compress`.
    public func compress(_ items: [URL]) async throws -> URL {
        let result = await run(kind: "compress", title: Self.compressTitle(items)) { _ -> Result<URL, any Error> in
            do {
                return .success(try await Compressor.compress(items))
            } catch {
                return .failure(error)
            }
        }
        if case .success(let zip) = result {
            undo.push(FileUndoRecord(action: .created([zip]), title: String(localized: "Compress")))
        }
        postFoldersDidChange(items.map { $0.deletingLastPathComponent() })
        return try result.get()
    }

    /// Extracts `entries` (paths inside `archive`, "" = everything) into `destination`. bsdtar unpacks them
    /// into a hidden staging folder in `destination` (see `ArchiveExtractor.stage`), the transfer engine
    /// moves them in (conflicts go to `resolver`), and the staging folder is removed. Uses the catalog's
    /// session password for `archive`.
    ///
    /// Throws `ArchiveError` when bsdtar fails, `CancellationError` when cancelled (while unpacking or
    /// moving), and `CocoaError(.fileWriteNoPermission)` when `destination` is inside an archive. Otherwise
    /// the move's outcome (finished, stopped, failed) is reported in the result like `transfer`. Completed
    /// items are undoable as "Extract", which moves them to the Trash and restores replaced items.
    public func extract(
        _ entries: [String], from archive: URL, into destination: URL, resolver: @escaping ConflictResolver
    ) async throws -> TransferResult {
        try await Self.requireWritableFolder(destination)
        let password = await catalog.password(for: archive)
        let names = entries.map { $0.split(separator: "/").last.map(String.init) ?? archive.lastPathComponent }
        return try await runExtraction(title: Self.extractTitle(names), into: destination, resolver: resolver) {
            let staged = try await ArchiveExtractor.stage(entries, from: archive, near: destination, password: password)
            return (staged.staging, staged.items)
        }
    }

    /// Extracts the whole archive into `destination`. A single top-level item arrives as is; several arrive
    /// in a new folder named after the archive without its archive extension (`assets.tar.gz` → `assets`,
    /// `assets 2` if that's taken), moved in as one item. Errors as for `extract`.
    public func extractAll(
        _ archive: URL, into destination: URL, resolver: @escaping ConflictResolver
    ) async throws -> TransferResult {
        try await Self.requireWritableFolder(destination)
        let password = await catalog.password(for: archive)
        let folderName = ArchiveFormats.baseName(of: archive)
        return try await runExtraction(
            title: Self.extractTitle([archive.lastPathComponent]), into: destination, resolver: resolver
        ) {
            let staged = try await ArchiveExtractor.stage([""], from: archive, near: destination, password: password)
            if staged.items.count == 1 { return (staged.staging, staged.items) }
            do {
                let folder = try await ArchiveExtractor.wrap(
                    staged.items, in: staged.staging, named: folderName, for: destination)
                return (staged.staging, [folder])
            } catch {
                ArchiveExtractor.removeStaging(staged.staging)
                throw error
            }
        }
    }

    /// Cancels the running operation `id`; it ends as soon as its work notices.
    public func cancel(_ id: UUID) {
        cancellers[id]?()
    }

    /// Runs `stage` and moves its items into `destination` as one listed operation, always removing the
    /// staging folder; records undo and posts `foldersDidChange` for `destination`.
    private func runExtraction(
        title: String, into destination: URL, resolver: @escaping ConflictResolver,
        stage: @escaping @Sendable () async throws -> (staging: URL, items: [URL])
    ) async throws -> TransferResult {
        let trash = trashItem
        let sameVolume = sameVolume
        let allowClone = allowClone
        let outcome = await run(kind: "extract", title: title) { progress -> Result<TransferResult, any Error> in
            let staged: (staging: URL, items: [URL])
            do {
                staged = try await stage()
            } catch {
                return .failure(error)
            }
            let result = await FileTransfer.run(
                staged.items, into: destination, mode: .move, resolver: resolver, trash: trash,
                sameVolume: sameVolume, allowClone: allowClone, progress: progress)
            await Self.removeStaging(staged.staging)
            return .success(result)
        }
        // Recorded like a copy: undo trashes the extracted items and puts replaced originals back.
        if case .success(let result) = outcome, !result.completed.isEmpty || !result.replaced.isEmpty {
            undo.push(
                FileUndoRecord(
                    action: .transferred(.copy, result.completed, replaced: result.replaced),
                    title: String(localized: "Extract")))
        }
        postFoldersDidChange([destination])
        let result = try outcome.get()
        // Like a cancel while unpacking: the completed part stays recorded for undo.
        if result.outcome == .cancelled { throw CancellationError() }
        return result
    }

    /// Staging removal is file-system work: off the main actor.
    @concurrent private nonisolated static func removeStaging(_ staging: URL) async {
        ArchiveExtractor.removeStaging(staging)
    }

    /// Extraction writes only into real folders, never into a folder inside an archive. The split runs off the
    /// main actor (`PathQueries`): the destination may be on a network volume.
    private static func requireWritableFolder(_ destination: URL) async throws {
        if await PathQueries.archiveLocation(destination) != nil { throw CocoaError(.fileWriteNoPermission) }
    }

    // MARK: - Recording

    /// Records a rename done elsewhere (BrowserModel); the caller refreshes its own folder.
    public func recordRename(from: URL, to: URL) {
        undo.push(FileUndoRecord(action: .rename(from: from, to: to), title: String(localized: "Rename")))
    }

    /// Records a new folder or file made elsewhere (BrowserModel).
    public func recordCreated(_ url: URL, isFolder: Bool) {
        undo.push(
            FileUndoRecord(
                action: .created([url]),
                title: isFolder ? String(localized: "New Folder") : String(localized: "New File")))
    }

    /// Undoes the newest record and posts `foldersDidChange` for the folders it touched, whether the undo
    /// succeeded or not. Returns the restored URLs (see `FileUndoStack.undo()`).
    ///
    /// The folders are those of the record this call actually reversed: with a queued second undo
    /// (a quick double ⌘Z), that is the record below the one the first call reverses.
    public func performUndo() async throws(UndoError) -> [URL] {
        let outcome = await undo.undoReportingRecord()
        if let record = outcome.record { postFoldersDidChange(Self.folders(touchedBy: record.action)) }
        return try outcome.result.get()
    }

    // MARK: - Running

    /// Coalesces progress reports from any thread; the main actor applies at most one per `interval`.
    private final class ProgressThrottle: Sendable {
        struct State {
            var latest: TransferProgress?
            var flushScheduled = false
            var lastApplied: ContinuousClock.Instant?
        }

        static let interval = Duration.milliseconds(100)
        let state = Mutex(State())
    }

    /// Lists a status, runs `work` in its own task (cancellable by id, and by cancelling the caller), applies
    /// the final progress and removes the status. `work` runs on its own thread
    /// (`SerialQueueExecutor`, labelled "MacCommander op <kind>"), never on the cooperative pool: on a dead
    /// share its file-system calls can block for minutes.
    private func run<T: Sendable>(
        kind: String, title: String,
        _ work: @escaping @Sendable (@escaping @Sendable (TransferProgress) -> Void) async -> T
    ) async -> T {
        let id = UUID()
        let throttle = ProgressThrottle()
        operations.append(FileOperationStatus(id: id, title: title, progress: nil))

        let report: @Sendable (TransferProgress) -> Void = { [weak self] progress in
            let schedule = throttle.state.withLock { state in
                state.latest = progress
                if state.flushScheduled { return false }
                state.flushScheduled = true
                return true
            }
            if schedule {
                Task { @MainActor in await self?.flush(id, throttle) }
            }
        }
        let label = "MacCommander op \(kind)"
        let task = Task { await SerialQueueExecutor.withOwnThread(label: label) { await work(report) } }
        cancellers[id] = { task.cancel() }

        let value = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        cancellers[id] = nil
        // The last update always lands, even if a flush is still waiting out the interval.
        if let latest = throttle.state.withLock({ $0.latest }) { setProgress(latest, of: id) }
        operations.removeAll { $0.id == id }
        return value
    }

    /// Applies the newest progress once the interval since the previous application has passed.
    private func flush(_ id: UUID, _ throttle: ProgressThrottle) async {
        let clock = ContinuousClock()
        if let last = throttle.state.withLock({ $0.lastApplied }) {
            let due = last.advanced(by: ProgressThrottle.interval)
            if due > clock.now { try? await clock.sleep(until: due) }
        }
        let latest = throttle.state.withLock { state in
            state.flushScheduled = false
            state.lastApplied = clock.now
            return state.latest
        }
        if let latest { setProgress(latest, of: id) }
    }

    private func setProgress(_ progress: TransferProgress, of id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }),
            operations[index].progress != progress
        else { return }
        operations[index].progress = progress
    }

    // MARK: - Folders

    private func postFoldersDidChange(_ folders: [URL]) {
        var seen = Set<String>()
        var unique: [URL] = []
        for folder in folders {
            let path = Self.key(folder)
            if seen.insert(path).inserted { unique.append(URL(fileURLWithPath: path, isDirectory: true)) }
        }
        guard !unique.isEmpty else { return }
        NotificationCenter.default.post(name: Self.foldersDidChange, object: self, userInfo: ["folders": unique])
    }

    private static func folders(touchedBy action: FileUndoAction) -> [URL] {
        func parent(_ url: URL) -> URL { url.deletingLastPathComponent() }
        switch action {
        case .rename(let from, let to):
            return [parent(from), parent(to)]
        case .created(let urls):
            return urls.map(parent)
        case .transferred(_, let items, let replaced):
            return items.flatMap { [parent($0.source), parent($0.destination)] } + replaced.map { parent($0.original) }
        case .trashed(let items):
            return items.map { parent($0.original) }
        }
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    // MARK: - Titles

    private static func transferTitle(_ sources: [URL], into destination: URL, mode: TransferMode) -> String {
        let folder = destination.lastPathComponent
        if sources.count == 1, let name = sources.first?.lastPathComponent {
            return mode == .copy
                ? String(localized: "Copying “\(name)” to “\(folder)”")
                : String(localized: "Moving “\(name)” to “\(folder)”")
        }
        return mode == .copy
            ? String(localized: "Copying \(sources.count) items to “\(folder)”")
            : String(localized: "Moving \(sources.count) items to “\(folder)”")
    }

    private static func duplicateTitle(_ items: [URL]) -> String {
        if items.count == 1, let name = items.first?.lastPathComponent {
            return String(localized: "Duplicating “\(name)”")
        }
        return String(localized: "Duplicating \(items.count) items")
    }

    private static func trashTitle(_ items: [URL]) -> String {
        if items.count == 1, let name = items.first?.lastPathComponent {
            return String(localized: "Moving “\(name)” to the Trash")
        }
        return String(localized: "Moving \(items.count) items to the Trash")
    }

    private static func compressTitle(_ items: [URL]) -> String {
        if items.count == 1, let name = items.first?.lastPathComponent {
            return String(localized: "Compressing “\(name)”")
        }
        return String(localized: "Compressing \(items.count) items")
    }

    private static func extractTitle(_ names: [String]) -> String {
        if names.count == 1, let name = names.first {
            return String(localized: "Extracting “\(name)”")
        }
        return String(localized: "Extracting \(names.count) items")
    }

    private static func undoTitle(mode: TransferMode, completed: [TransferredItem]) -> String {
        if completed.count == 1, let name = completed.first?.source.lastPathComponent {
            return mode == .copy ? String(localized: "Copy of “\(name)”") : String(localized: "Move of “\(name)”")
        }
        return mode == .copy
            ? String(localized: "Copy of \(completed.count) Items")
            : String(localized: "Move of \(completed.count) Items")
    }
}
