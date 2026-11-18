import Darwin
import Foundation
import Observation

public enum FileUndoAction: Sendable, Equatable {
    case rename(from: URL, to: URL)
    /// A new folder or file; undo trashes it.
    case created([URL])
    /// Copy, duplicate or move, with the items a Replace sent to the Trash.
    case transferred(TransferMode, [TransferredItem], replaced: [TrashedItem])
    /// Undo puts the items back.
    case trashed([TrashedItem])
}

public struct FileUndoRecord: Sendable, Equatable {
    public let action: FileUndoAction
    /// Menu title, built by the caller, e.g. "Move of 3 Items".
    public let title: String

    public init(action: FileUndoAction, title: String) {
        self.action = action
        self.title = title
    }
}

public enum UndoError: Error, Equatable {
    case nothingToUndo
    /// An item to restore is gone, or something now occupies a place to restore into. Nothing was changed.
    case itemChanged(name: String)
    /// A step failed after the pre-check passed. Steps before it stay reversed.
    case failed(name: String, message: String)
}

/// Undo for file operations. Data-safety rules:
/// - undo never overwrites: a pre-check verifies, before anything changes, that every item to restore
///   exists and every place to restore into is free, otherwise it throws `.itemChanged` and drops the record;
/// - items are moved back with an exclusive rename, so an item that appears at an original location after
///   the pre-check is never replaced; across volumes they are copied back via a staging item, and the moved
///   copy is deleted only after that succeeded (the same rules as `FileTransfer`);
/// - "removing" a created or copied item sends it to the Trash.
///
/// If a step fails after the pre-check (I/O error, or a race), undo stops there and throws `.failed`.
/// The record is dropped and the steps already done stay done, so the remaining items stay where the
/// operation put them.
@MainActor @Observable
public final class FileUndoStack {
    public private(set) var records: [FileUndoRecord] = []
    public var undoTitle: String? { records.last?.title }
    /// True while an undo runs; further `undo()` calls wait for it (the UI may disable the menu item).
    public private(set) var isUndoing = false

    @ObservationIgnored private let trash: @Sendable (URL) throws -> URL
    @ObservationIgnored private let limit: Int
    /// The newest undo; each undo waits for the one before it, so undos run one at a time, newest record first.
    @ObservationIgnored private var tail: Task<UndoOutcome, Never>?
    @ObservationIgnored private var pendingUndos = 0

    public init(trash: @escaping @Sendable (URL) throws -> URL = Trasher.systemTrash, limit: Int = 50) {
        self.trash = trash
        self.limit = max(1, limit)
    }

    /// Adds a record; the oldest records are dropped beyond `limit`.
    public func push(_ record: FileUndoRecord) {
        records.append(record)
        if records.count > limit { records.removeFirst(records.count - limit) }
    }

    /// Pops the last record and reverses it off the main actor.
    /// Returns the URLs restored to view, for selection: the `from` URL of a rename, the originals of a move
    /// or trash, and nothing for created items or copies (their parents' contents changed).
    ///
    /// Calls are serialized: a second `undo()` while one runs (a quick double ⌘Z) waits for the first to
    /// finish and only then pops its record, so records are always reversed last-first.
    public func undo() async throws(UndoError) -> [URL] {
        try await undoReportingRecord().result.get()
    }

    /// What one `undo()` call did: the record it popped (nil if there was none) and its result.
    struct UndoOutcome: Sendable {
        let record: FileUndoRecord?
        let result: Result<[URL], UndoError>
    }

    /// `undo()`, also reporting the record this call actually reversed — with queued calls, not necessarily
    /// the newest record when the call started.
    func undoReportingRecord() async -> UndoOutcome {
        let previous = tail
        let task = Task { @MainActor () -> UndoOutcome in
            _ = await previous?.value
            return await self.undoNext()
        }
        tail = task
        pendingUndos += 1
        isUndoing = true
        let outcome = await task.value
        pendingUndos -= 1
        isUndoing = pendingUndos > 0
        if pendingUndos == 0 { tail = nil }
        return outcome
    }

    private func undoNext() async -> UndoOutcome {
        guard let record = records.popLast() else { return UndoOutcome(record: nil, result: .failure(.nothingToUndo)) }
        let action = record.action
        let trash = trash
        // On its own thread: reversing moves and trashes items, possibly on a dead share.
        let reversed = await SerialQueueExecutor.withOwnThread(label: "MacCommander op undo") {
            await Self.reverse(action, trash: trash)
        }
        if case .failure(let error) = reversed {
            return UndoOutcome(record: record, result: .failure(error))
        }
        let restored: [URL]
        switch record.action {
        case .rename(let from, _): restored = [from]
        case .created, .transferred(.copy, _, _): restored = []
        case .transferred(.move, let items, _): restored = items.map(\.source)
        case .trashed(let items): restored = items.map(\.original)
        }
        return UndoOutcome(record: record, result: .success(restored))
    }

    // MARK: - Reversing

    private enum Step {
        /// Move `item` back to the free location `target`.
        case moveBack(URL, to: URL)
        case trash(URL)

        var item: URL {
            switch self {
            case .moveBack(let item, _), .trash(let item): item
            }
        }

        /// The name shown in errors: the name the item gets back.
        var name: String {
            switch self {
            case .moveBack(_, let target): target.lastPathComponent
            case .trash(let item): item.lastPathComponent
            }
        }
    }

    private nonisolated static func steps(for action: FileUndoAction) -> [Step] {
        switch action {
        case .rename(let from, let to):
            return [.moveBack(to, to: from)]
        case .created(let urls):
            return urls.map { .trash($0) }
        case .transferred(let mode, let items, let replaced):
            // A move into the item's own folder changed nothing; there is nothing to reverse.
            let changed = items.filter { $0.destination != $0.source }
            let reversed: [Step] = changed.map {
                mode == .copy ? .trash($0.destination) : .moveBack($0.destination, to: $0.source)
            }
            // After the new items are gone, the replaced ones go back to where they were.
            return reversed + replaced.map { .moveBack($0.trashed, to: $0.original) }
        case .trashed(let items):
            return items.map { .moveBack($0.trashed, to: $0.original) }
        }
    }

    @concurrent
    private static func reverse(
        _ action: FileUndoAction, trash: @Sendable (URL) throws -> URL
    ) async -> Result<Void, UndoError> {
        let steps = steps(for: action)
        if let changed = precheck(steps) { return .failure(.itemChanged(name: changed)) }
        for step in steps {
            switch step {
            case .trash(let item):
                do {
                    _ = try trash(item)
                } catch {
                    return .failure(.failed(name: step.name, message: error.localizedDescription))
                }
            case .moveBack(let item, let target):
                switch moveBack(item, to: target) {
                case nil: break
                case .occupied: return .failure(.itemChanged(name: step.name))
                case .failed(let message): return .failure(.failed(name: step.name, message: message))
                }
            }
        }
        return .success(())
    }

    /// Returns the name of the first step that can't run, nil if every step can. The check simulates the
    /// steps in order: an item must exist (and not have been moved away by an earlier step), and a target
    /// must have an existing parent folder and be free — empty on disk or vacated by an earlier step, and
    /// not filled by an earlier step (two items never go back to the same place).
    private nonisolated static func precheck(_ steps: [Step]) -> String? {
        let fileManager = FileManager()
        var vacated = Set<String>()
        var occupied = Set<String>()
        func exists(_ url: URL) -> Bool {
            let path = key(url)
            return occupied.contains(path)
                || (!vacated.contains(path) && FileTransfer.entryExists(url, fileManager: fileManager))
        }
        for step in steps {
            guard exists(step.item) else { return step.name }
            if case .moveBack(let item, let target) = step {
                var isDirectory: ObjCBool = false
                guard
                    fileManager.fileExists(
                        atPath: target.deletingLastPathComponent().path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else { return step.name }
                if occupied.contains(key(target)) { return step.name }
                if exists(target) && !isCaseOnlyRename(item, to: target) { return step.name }
            }
            vacated.insert(key(step.item))
            occupied.remove(key(step.item))
            if case .moveBack(_, let target) = step {
                occupied.insert(key(target))
                vacated.remove(key(target))
            }
        }
        return nil
    }

    /// Moves `item` to the free path `target` without ever replacing anything there: an exclusive rename,
    /// or, across volumes (`EXDEV`), copy via staging then delete the moved item. `allowRename: false`
    /// forces the cross-volume path (tests). Returns nil on success; `.occupied` if something appeared at
    /// `target` after the pre-check (both items are left unchanged).
    nonisolated static func moveBack(
        _ item: URL, to target: URL, allowRename: Bool = true
    ) -> FileTransfer.CrossVolumeMoveFailure? {
        if allowRename {
            if isCaseOnlyRename(item, to: target) {
                // `target` is the item itself under another case; an exclusive rename would refuse it.
                return rename(item.path, target.path) == 0 ? nil : .failed(String(cString: strerror(errno)))
            }
            let code = FileTransfer.exclusiveRename(item, to: target)
            if code == 0 { return nil }
            if code == EEXIST { return .occupied }
            if code != EXDEV { return .failed(String(cString: strerror(code))) }
        }
        return FileTransfer.moveAcrossVolumes(item, to: target)
    }

    /// True if `target` is `item`'s own path in another letter case (on a case-insensitive volume).
    private nonisolated static func isCaseOnlyRename(_ item: URL, to target: URL) -> Bool {
        item.path != target.path && item.path.lowercased() == target.path.lowercased()
            && FileTransfer.isSameFile(item, target)
    }

    private nonisolated static func key(_ url: URL) -> String { url.standardizedFileURL.path }
}
