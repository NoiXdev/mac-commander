import Foundation
import Observation
import Synchronization
import Testing
@testable import MacCommanderCore

/// A fixture with `src/`, `dst/` and a fake `Trash/`; the center never touches the real Trash.
@MainActor
private struct Fixture {
    let tmp: TemporaryDirectory
    let src: URL
    let dst: URL
    let trashFolder: URL
    let center: FileOperationCenter

    init(allowClone: Bool = true) throws {
        tmp = try TemporaryDirectory()
        src = try tmp.folder("src")
        dst = try tmp.folder("dst")
        trashFolder = try tmp.folder("Trash")
        let trash = fakeTrash(into: trashFolder)
        center = FileOperationCenter(undo: FileUndoStack(trash: trash), trash: trash, allowClone: allowClone)
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

/// Collects the `folders` of every `foldersDidChange` posted by one center (posted on the main actor).
@MainActor
private final class FolderNotices {
    private(set) var notices: [[URL]] = []
    nonisolated(unsafe) private var token: (any NSObjectProtocol)?

    init(_ center: FileOperationCenter) {
        token = NotificationCenter.default.addObserver(
            forName: FileOperationCenter.foldersDidChange, object: center, queue: nil
        ) { [weak self] note in
            let folders = note.userInfo?["folders"] as? [URL] ?? []
            MainActor.assumeIsolated { self?.notices.append(folders) }
        }
    }

    var paths: [[String]] { notices.map { $0.map(\.standardizedFileURL.path) } }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

/// Counts the changes of the first operation's progress with `withObservationTracking`, re-armed after
/// every change of `operations`.
@MainActor
private final class ProgressChangeCounter {
    let center: FileOperationCenter
    var changes = 0
    var running = true
    private var last: TransferProgress?

    init(_ center: FileOperationCenter) {
        self.center = center
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = center.operations
        } onChange: {
            // onChange runs before the change is stored; read the new value afterwards.
            Task { @MainActor in self.changed() }
        }
    }

    private func changed() {
        if let progress = center.operations.first?.progress, progress != last {
            last = progress
            changes += 1
        }
        if running { observe() }
    }
}

private func path(_ url: URL) -> String { url.standardizedFileURL.path }

private let keepBoth: ConflictResolver = { _ in ConflictDecision(choice: .keepBoth, applyToAll: false) }

@MainActor
struct FileOperationCenterTests {
    @Test func transferPushesUndoAndPostsFolders() async throws {
        let f = try Fixture()
        let a = try f.tmp.file("src/a.txt", contents: "A")
        let notices = FolderNotices(f.center)

        let result = await f.center.transfer([a], into: f.dst, mode: .move, resolver: keepBoth)

        #expect(result.outcome == .finished)
        #expect(f.exists(f.dst.appendingPathComponent("a.txt")))
        #expect(f.center.undo.undoTitle == "Move of “a.txt”")
        #expect(f.center.operations.isEmpty)
        let posted = try #require(notices.paths.first)
        #expect(posted.contains(path(f.dst)))
        #expect(posted.contains(path(f.src)))
        #expect(Set(posted).count == posted.count)

        // Undo moves it back and announces the same folders.
        let restored = try await f.center.performUndo()
        #expect(restored.map(path) == [path(a)])
        #expect(f.exists(a))
        #expect(notices.paths.count == 2)
        #expect(Set(notices.paths[1]) == Set([path(f.src), path(f.dst)]))
    }

    @Test func copyTitlesCountItems() async throws {
        let f = try Fixture()
        let a = try f.tmp.file("src/a.txt", contents: "A")
        let b = try f.tmp.file("src/b.txt", contents: "B")
        let c = try f.tmp.file("src/c.txt", contents: "C")

        _ = await f.center.transfer([a, b, c], into: f.dst, mode: .copy, resolver: keepBoth)

        #expect(f.center.undo.undoTitle == "Copy of 3 Items")
    }

    @Test func cancelledTransferStillUndoable() async throws {
        let f = try Fixture()
        let a = try f.tmp.file("src/a.txt", contents: "A")
        let b = try f.tmp.file("src/b.txt", contents: "B")
        try f.tmp.file("dst/a.txt", contents: "old A")
        try f.tmp.file("dst/b.txt", contents: "old B")

        let waiting = Mutex(false)
        // First conflict: Keep Both. Second conflict: suspend until the operation is cancelled.
        let resolver: ConflictResolver = { conflict in
            if conflict.source.lastPathComponent == "a.txt" {
                return ConflictDecision(choice: .keepBoth, applyToAll: false)
            }
            waiting.withLock { $0 = true }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return ConflictDecision(choice: .skip, applyToAll: false)
        }

        let center = f.center
        let dst = f.dst
        let transfer = Task { await center.transfer([a, b], into: dst, mode: .copy, resolver: resolver) }
        while !waiting.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        let id = try #require(center.operations.first?.id)
        center.cancel(id)
        let result = await transfer.value

        #expect(result.outcome == .cancelled)
        #expect(result.completed.map(\.destination.lastPathComponent) == ["a 2.txt"])
        #expect(center.operations.isEmpty)
        let record = try #require(center.undo.records.last)
        #expect(record.title == "Copy of “a.txt”")
        guard case .transferred(.copy, let items, let replaced) = record.action else {
            Issue.record("unexpected action \(record.action)")
            return
        }
        #expect(items == result.completed)
        #expect(replaced.isEmpty)
        #expect(!f.exists(dst.appendingPathComponent("b 2.txt")))
    }

    @Test func nothingDoneNothingRecorded() async throws {
        let f = try Fixture()
        let a = try f.tmp.file("src/a.txt", contents: "A")
        try f.tmp.file("dst/a.txt", contents: "old A")
        let stop: ConflictResolver = { _ in ConflictDecision(choice: .stop, applyToAll: false) }

        let result = await f.center.transfer([a], into: f.dst, mode: .copy, resolver: stop)

        #expect(result.outcome == .stopped)
        #expect(f.center.undo.records.isEmpty)
    }

    /// Moving items into their own folder changes nothing and records no undo; a real move alongside them
    /// is titled for itself alone.
    @Test func noOpMoveRecordsNoUndo() async throws {
        let f = try Fixture()
        let a = try f.tmp.file("src/a.txt", contents: "A")
        let b = try f.tmp.file("dst/b.txt", contents: "B")

        let noOp = await f.center.transfer([a], into: f.src, mode: .move, resolver: keepBoth)
        #expect(noOp.outcome == .finished)
        #expect(f.center.undo.records.isEmpty)

        let mixed = await f.center.transfer([a, b], into: f.dst, mode: .move, resolver: keepBoth)
        #expect(mixed.outcome == .finished)
        #expect(f.center.undo.records.count == 1)
        #expect(f.center.undo.undoTitle == "Move of “a.txt”")
    }

    /// A quick double ⌘Z: each performUndo posts the folders of the record it actually reversed.
    @Test func queuedUndosPostTheirOwnRecordsFolders() async throws {
        let f = try Fixture()
        let a = f.src.appendingPathComponent("a.txt")
        let a2 = try f.tmp.file("src/a2.txt", contents: "A")
        let b = f.dst.appendingPathComponent("b.txt")
        let b2 = try f.tmp.file("dst/b2.txt", contents: "B")
        f.center.recordRename(from: a, to: a2)
        f.center.recordRename(from: b, to: b2)
        let notices = FolderNotices(f.center)

        async let first = f.center.performUndo()
        async let second = f.center.performUndo()
        let results = try await [first, second]

        #expect(Set(results.map { $0.map(path) }) == [[path(a)], [path(b)]])
        // Before the fix both calls posted the newest record's folder (dst) twice.
        #expect(notices.paths.count == 2)
        #expect(Set(notices.paths) == [[path(f.src)], [path(f.dst)]])
    }

    /// A failing undo still posts the folders of the record it popped.
    @Test func failedUndoPostsItsRecordsFolders() async throws {
        let f = try Fixture()
        let gone = f.dst.appendingPathComponent("gone.txt")
        f.center.recordRename(from: f.dst.appendingPathComponent("was.txt"), to: gone)
        let notices = FolderNotices(f.center)

        await #expect(throws: UndoError.itemChanged(name: "was.txt")) { try await f.center.performUndo() }
        #expect(notices.paths == [[path(f.dst)]])
        await #expect(throws: UndoError.nothingToUndo) { try await f.center.performUndo() }
        #expect(notices.paths == [[path(f.dst)]])
    }

    @Test func duplicateTitlesAndNames() async throws {
        let f = try Fixture()
        let a = try f.tmp.file("src/a.txt", contents: "A")
        let notices = FolderNotices(f.center)

        let first = await f.center.duplicate([a])
        #expect(first.completed.map(\.destination.lastPathComponent) == ["a copy.txt"])
        #expect(f.exists(f.src.appendingPathComponent("a copy.txt")))
        #expect(f.center.undo.undoTitle == "Duplicate")
        guard case .transferred(.copy, _, _) = f.center.undo.records.last?.action else {
            Issue.record("expected a copy record")
            return
        }

        let second = await f.center.duplicate([a])
        #expect(second.completed.map(\.destination.lastPathComponent) == ["a copy 2.txt"])
        #expect(f.exists(f.src.appendingPathComponent("a copy 2.txt")))
        #expect(notices.paths == [[path(f.src)], [path(f.src)]])
    }

    @Test func duplicateAcrossFolders() async throws {
        let f = try Fixture()
        let a = try f.tmp.file("src/a.txt", contents: "A")
        let b = try f.tmp.file("dst/b.txt", contents: "B")

        let result = await f.center.duplicate([a, b])

        #expect(result.outcome == .finished)
        #expect(f.exists(f.src.appendingPathComponent("a copy.txt")))
        #expect(f.exists(f.dst.appendingPathComponent("b copy.txt")))
        #expect(f.center.undo.records.count == 1)
    }

    @Test func trashRecordsOnlySuccesses() async throws {
        let f = try Fixture()
        let a = try f.tmp.file("src/a.txt", contents: "A")
        let missing = f.src.appendingPathComponent("missing.txt")
        let notices = FolderNotices(f.center)

        let result = await f.center.trash([a, missing])

        #expect(result.trashed.count == 1)
        #expect(result.failures.map(\.url) == [missing])
        #expect(!f.exists(a))
        #expect(f.center.undo.undoTitle == "Move to Trash")
        guard case .trashed(let items) = f.center.undo.records.last?.action else {
            Issue.record("expected a trash record")
            return
        }
        #expect(items.count == 1)
        #expect(items.first?.original == a)
        #expect(notices.paths == [[path(f.src)]])
    }

    @Test func compressRecordsCreatedArchive() async throws {
        let f = try Fixture()
        let a = try f.tmp.file("src/a.txt", contents: "A")

        let zip = try await f.center.compress([a])

        #expect(zip.lastPathComponent == "a.txt.zip")
        #expect(f.center.undo.undoTitle == "Compress")
        #expect(f.center.undo.records.last?.action == .created([zip]))
        #expect(f.center.operations.isEmpty)
    }

    @Test func recordRenameAndCreated() async throws {
        let f = try Fixture()
        let a = f.src.appendingPathComponent("a.txt")
        let b = try f.tmp.file("src/b.txt", contents: "A")
        f.center.recordRename(from: a, to: b)
        #expect(f.center.undo.undoTitle == "Rename")
        f.center.recordCreated(f.dst, isFolder: true)
        #expect(f.center.undo.undoTitle == "New Folder")
        f.center.recordCreated(b, isFolder: false)
        #expect(f.center.undo.undoTitle == "New File")
    }

    @Test func progressIsThrottled() async throws {
        let f = try Fixture(allowClone: false)
        var sources: [URL] = []
        for i in 0..<50 { sources.append(try f.tmp.file("src/f\(i).txt", contents: String(repeating: "x", count: 4096))) }

        let center = f.center
        let counter = ProgressChangeCounter(center)

        let start = ContinuousClock.now
        let result = await center.transfer(sources, into: f.dst, mode: .copy, resolver: keepBoth)
        let elapsed = (ContinuousClock.now - start) / .seconds(1)
        counter.running = false

        #expect(result.completed.count == 50)
        let count = counter.changes
        #expect(count >= 1)
        #expect(Double(count) <= elapsed / 0.1 + 2, "\(count) changes in \(elapsed) s")
    }
}
