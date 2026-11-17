import Darwin
import Foundation
import Synchronization

public enum TransferMode: Sendable { case copy, move }

public enum ConflictChoice: Sendable { case replace, keepBoth, skip, stop }

public struct ConflictDecision: Sendable {
    public var choice: ConflictChoice
    public var applyToAll: Bool

    public init(choice: ConflictChoice, applyToAll: Bool) {
        self.choice = choice
        self.applyToAll = applyToAll
    }
}

public struct TransferConflict: Sendable {
    public let source: URL
    public let existing: URL
    public let mode: TransferMode
    /// True when more top-level items remain after this one (the UI offers "Apply to All").
    public let moreItemsFollow: Bool
}

public typealias ConflictResolver = @Sendable (TransferConflict) async -> ConflictDecision

public struct TransferProgress: Sendable, Equatable {
    public var totalBytes: Int64
    public var completedBytes: Int64
    public var totalItems: Int
    public var completedItems: Int
    public var currentName: String?
}

public struct TransferredItem: Sendable, Equatable {
    public let source: URL
    /// The URL actually written — the copy or keep-both name when one was used.
    public let destination: URL
}

public struct TrashedItem: Sendable, Equatable {
    public let original: URL
    public let trashed: URL
}

public enum TransferError: Error, Equatable {
    case intoItself(name: String)
    case failed(name: String, message: String)
}

public enum TransferOutcome: Sendable, Equatable { case finished, stopped, cancelled, failed(TransferError) }

public struct TransferResult: Sendable, Equatable {
    public var completed: [TransferredItem]
    public var replaced: [TrashedItem]
    public var skipped: [URL]
    public var outcome: TransferOutcome
}

/// Copies or moves top-level items into a folder. Data-safety rules:
/// - conflicts are never overwritten silently: Replace moves the existing item to the Trash first;
/// - the only permanent deletes are the partial output of a failed or cancelled copy, and the source
///   of a cross-volume move after its copy succeeded.
public enum FileTransfer {
    @concurrent public static func run(
        _ sources: [URL], into destination: URL, mode: TransferMode,
        resolver: ConflictResolver,
        trash: @Sendable (URL) throws -> URL = Trasher.systemTrash,
        sameVolume: @Sendable (URL, URL) -> Bool = FileTransfer.isSameVolume,
        progress: @Sendable (TransferProgress) -> Void = { _ in }
    ) async -> TransferResult {
        await run(
            sources, into: destination, mode: mode, resolver: resolver, trash: trash, sameVolume: sameVolume,
            allowClone: true, progress: progress)
    }

    /// `allowClone: false` forces a real data copy (tests use it to cancel mid-copy).
    @concurrent static func run(
        _ sources: [URL], into destination: URL, mode: TransferMode,
        resolver: ConflictResolver,
        trash: @Sendable (URL) throws -> URL = Trasher.systemTrash,
        sameVolume: @Sendable (URL, URL) -> Bool = FileTransfer.isSameVolume,
        allowClone: Bool,
        progress: @Sendable (TransferProgress) -> Void = { _ in }
    ) async -> TransferResult {
        let fileManager = FileManager()
        var result = TransferResult(completed: [], replaced: [], skipped: [], outcome: .finished)

        for source in sources where isSourceContaining(destination, source: source) {
            result.outcome = .failed(.intoItself(name: source.lastPathComponent))
            return result
        }
        if Task.isCancelled {
            result.outcome = .cancelled
            return result
        }

        let sizes = sources.map { byteCount(of: $0, fileManager: fileManager) }
        var state = TransferProgress(
            totalBytes: sizes.reduce(0, +), completedBytes: 0, totalItems: sources.count, completedItems: 0,
            currentName: nil)
        progress(state)

        let destinationPath = canonicalPath(destination)
        var standingDecision: ConflictDecision?

        for (index, source) in sources.enumerated() {
            if Task.isCancelled {
                result.outcome = .cancelled
                return result
            }
            let name = source.lastPathComponent
            let baseline = state.completedBytes
            state.currentName = name

            func finishItem() {
                state.completedBytes = baseline + sizes[index]
                state.completedItems += 1
                progress(state)
            }
            func fail(_ message: String) -> TransferResult {
                result.outcome = .failed(.failed(name: name, message: message))
                return result
            }

            var targetName = name
            let parent = source.deletingLastPathComponent()
            if canonicalPath(parent) == destinationPath || isSameFile(parent, destination) {
                if mode == .move {
                    result.completed.append(TransferredItem(source: source, destination: source))
                    finishItem()
                    continue
                }
                targetName = NameGenerator.copyName(
                    for: name, isDirectory: namesLikeDirectory(source), in: destination, fileManager: fileManager)
            } else if entryExists(destination.appendingPathComponent(name), fileManager: fileManager) {
                let existing = destination.appendingPathComponent(name)
                let decision: ConflictDecision
                if let standingDecision {
                    decision = standingDecision
                } else {
                    decision = await resolver(
                        TransferConflict(
                            source: source, existing: existing, mode: mode, moreItemsFollow: index < sources.count - 1))
                    if decision.applyToAll { standingDecision = decision }
                }
                if Task.isCancelled {
                    result.outcome = .cancelled
                    return result
                }
                switch decision.choice {
                case .stop:
                    result.outcome = .stopped
                    return result
                case .skip:
                    result.skipped.append(source)
                    finishItem()
                    continue
                case .keepBoth:
                    targetName = NameGenerator.keepBothName(
                        for: name, isDirectory: namesLikeDirectory(source), in: destination, fileManager: fileManager)
                case .replace:
                    // Trashing a folder that contains the source would take the source with it.
                    if isEntryContaining(existing, source) {
                        return fail(
                            String(localized: "“\(name)” can’t be replaced because it contains the item being transferred."))
                    }
                    do {
                        let trashed = try trash(existing)
                        result.replaced.append(TrashedItem(original: existing, trashed: trashed))
                    } catch {
                        return fail(error.localizedDescription)
                    }
                }
            }

            let target = destination.appendingPathComponent(targetName)
            if mode == .move && sameVolume(source, destination) {
                do {
                    try fileManager.moveItem(at: source, to: target)
                } catch {
                    return fail(error.localizedDescription)
                }
            } else {
                let base = state
                let cap = sizes[index]
                let cancel = CancelFlag()
                let status = await withTaskCancellationHandler {
                    copy(source, to: target, allowClone: allowClone, cancel: cancel) { itemBytes in
                        var update = base
                        update.completedBytes = base.completedBytes + min(itemBytes, cap)
                        progress(update)
                    }
                } onCancel: {
                    cancel.isSet.store(true, ordering: .relaxed)
                }
                switch status {
                case .success:
                    break
                case .cancelled:
                    // `target` was free before the copy, so anything there now is our partial output.
                    try? fileManager.removeItem(at: target)
                    result.outcome = .cancelled
                    return result
                case .failed(let message):
                    try? fileManager.removeItem(at: target)
                    return fail(message)
                }
                if mode == .move {
                    do {
                        try fileManager.removeItem(at: source)
                    } catch {
                        // The full copy exists; keep it recorded so undo can cover it.
                        result.completed.append(TransferredItem(source: source, destination: target))
                        return fail(error.localizedDescription)
                    }
                }
            }
            result.completed.append(TransferredItem(source: source, destination: target))
            finishItem()
        }
        return result
    }

    /// Compares the volume of `a` with the volume of the folder `b`. Unknown counts as different,
    /// which falls back to the safe copy-then-delete path.
    public static func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let va = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
            let vb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        else { return false }
        return (va as? NSObject)?.isEqual(vb) ?? false
    }

    // MARK: - Copying

    private enum CopyStatus { case success, cancelled, failed(String) }

    private final class CancelFlag: Sendable {
        let isSet = Atomic<Bool>(false)
    }

    /// Shared with the copyfile callback, which runs synchronously on the copying thread.
    private final class CopyContext {
        let cancel: CancelFlag
        let report: (Int64) -> Void
        var itemBytes: Int64 = 0
        var lastFileCopied: Int64 = 0
        var errorCode: Int32 = 0

        init(cancel: CancelFlag, report: @escaping (Int64) -> Void) {
            self.cancel = cancel
            self.report = report
        }
    }

    private static let copyCallback: copyfile_callback_t = { what, stage, state, _, _, context in
        guard let context else { return COPYFILE_CONTINUE }
        let box = Unmanaged<CopyContext>.fromOpaque(context).takeUnretainedValue()
        if box.cancel.isSet.load(ordering: .relaxed) { return COPYFILE_QUIT }
        if what == COPYFILE_RECURSE_ERROR || stage == COPYFILE_ERR {
            box.errorCode = errno
            return COPYFILE_QUIT
        }
        if what == COPYFILE_RECURSE_FILE && stage == COPYFILE_START {
            box.lastFileCopied = 0
        } else if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS {
            var copied: off_t = 0
            if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
                // COPIED is per file; accumulate deltas so the item total only grows.
                let delta = copied >= box.lastFileCopied ? copied - box.lastFileCopied : copied
                box.lastFileCopied = copied
                box.itemBytes += delta
                box.report(box.itemBytes)
            }
        }
        return COPYFILE_CONTINUE
    }

    /// Copies `source` (file, folder, symlink or package) to the free path `target`, synchronously.
    /// Setting `cancel` makes the next copyfile callback quit.
    private static func copy(
        _ source: URL, to target: URL, allowClone: Bool, cancel: CancelFlag, report: (Int64) -> Void
    ) -> CopyStatus {
        guard let state = copyfile_state_alloc() else { return .failed(String(cString: strerror(ENOMEM))) }
        defer { copyfile_state_free(state) }

        var flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW)
        if allowClone { flags |= copyfile_flags_t(COPYFILE_CLONE) }

        return withoutActuallyEscaping(report) { report in
            let box = CopyContext(cancel: cancel, report: report)
            // The state holds an unretained pointer to `box`, kept alive until copyfile returns.
            return withExtendedLifetime(box) {
                copyfile_state_set(
                    state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyCallback, to: UnsafeRawPointer.self))
                copyfile_state_set(
                    state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(box).toOpaque())
                let rc = copyfile(source.path, target.path, state, flags)
                let savedErrno = errno
                if rc >= 0 { return .success }
                if cancel.isSet.load(ordering: .relaxed) { return .cancelled }
                let code = box.errorCode != 0 ? box.errorCode : savedErrno
                return .failed(String(cString: strerror(code)))
            }
        }
    }

    // MARK: - Paths

    /// Folder path with every symlink resolved.
    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The entry itself (not followed if it is a symlink) inside its resolved parent.
    private static func entryPath(_ url: URL) -> String {
        (canonicalPath(url.deletingLastPathComponent()) as NSString).appendingPathComponent(url.lastPathComponent)
    }

    private static func isPath(_ path: String, inside container: String) -> Bool {
        path == container || path.hasPrefix(container.hasSuffix("/") ? container : container + "/")
    }

    /// True if the destination folder is `source` or lies inside it.
    private static func isSourceContaining(_ destination: URL, source: URL) -> Bool {
        let destinationPath = canonicalPath(destination)
        if isPath(destinationPath, inside: entryPath(source)) { return true }
        return isRealDirectory(source) && hasAncestorOrSelf(URL(fileURLWithPath: destinationPath), sameAs: source)
    }

    /// True if `item` is `entry` or lies inside it.
    private static func isEntryContaining(_ entry: URL, _ item: URL) -> Bool {
        if isPath(entryPath(item), inside: entryPath(entry)) { return true }
        return isRealDirectory(entry)
            && hasAncestorOrSelf(URL(fileURLWithPath: canonicalPath(item.deletingLastPathComponent())), sameAs: entry)
    }

    /// Walks up from `start` comparing file identities, which also catches case-insensitive path aliases.
    private static func hasAncestorOrSelf(_ start: URL, sameAs target: URL) -> Bool {
        var url = start
        while true {
            if isSameFile(url, target) { return true }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return false }
            url = parent
        }
    }

    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        guard let ia = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
            let ib = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        else { return false }
        return (ia as? NSObject)?.isEqual(ib) ?? false
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// lstat-based, so a dangling symlink counts as existing.
    private static func entryExists(_ url: URL, fileManager: FileManager) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    /// Packages keep their extension in copy names (`App copy.app`), like files.
    private static func namesLikeDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    /// Sum of regular-file sizes under `url`, without following symlinks.
    private static func byteCount(of url: URL, fileManager: FileManager) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if values.isRegularFile == true { return Int64(values.fileSize ?? 0) }
        guard isRealDirectory(url),
            let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys)
        else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let v = try? item.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.fileSize ?? 0)
        }
        return total
    }
}
