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

    @ObservationIgnored private let trash: @Sendable (URL) throws -> URL
    @ObservationIgnored private let limit: Int

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
    public func undo() async throws(UndoError) -> [URL] {
        guard let record = records.popLast() else { throw .nothingToUndo }
        try await Self.reverse(record.action, trash: trash).get()
        switch record.action {
        case .rename(let from, _): return [from]
        case .created, .transferred(.copy, _, _): return []
        case .transferred(.move, let items, _): return items.map(\.source)
        case .trashed(let items): return items.map(\.original)
        }
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
                if let message = moveBack(item, to: target) {
                    return .failure(.failed(name: step.name, message: message))
                }
            }
        }
        return .success(())
    }

    /// Returns the name of the first step that can't run: its item is gone, or its target is taken (by
    /// something no earlier step moves away) or has no parent folder. Nil if every step can run.
    private nonisolated static func precheck(_ steps: [Step]) -> String? {
        let fileManager = FileManager()
        var vacated = Set<String>()
        for step in steps {
            guard FileTransfer.entryExists(step.item, fileManager: fileManager) else { return step.name }
            if case .moveBack(let item, let target) = step {
                var isDirectory: ObjCBool = false
                guard
                    fileManager.fileExists(
                        atPath: target.deletingLastPathComponent().path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else { return step.name }
                if FileTransfer.entryExists(target, fileManager: fileManager)
                    && !vacated.contains(key(target)) && !isCaseOnlyRename(item, to: target)
                {
                    return step.name
                }
            }
            vacated.insert(key(step.item))
        }
        return nil
    }

    /// Moves `item` to the free path `target` without ever replacing anything there: an exclusive rename,
    /// or, across volumes (`EXDEV`), copy via staging then delete the moved item. `allowRename: false`
    /// forces the cross-volume path (tests). Returns an error message, or nil on success.
    nonisolated static func moveBack(_ item: URL, to target: URL, allowRename: Bool = true) -> String? {
        if allowRename {
            if isCaseOnlyRename(item, to: target) {
                // `target` is the item itself under another case; an exclusive rename would refuse it.
                return rename(item.path, target.path) == 0 ? nil : String(cString: strerror(errno))
            }
            let code = FileTransfer.exclusiveRename(item, to: target)
            if code == 0 { return nil }
            if code == EEXIST {
                return String(
                    localized: "An item named “\(target.lastPathComponent)” appeared in its original location. Both items were left unchanged.")
            }
            if code != EXDEV { return String(cString: strerror(code)) }
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
