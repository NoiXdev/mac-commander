import Foundation
import Synchronization
import Testing
@testable import MacCommanderCore

/// Records conflicts and answers with scripted decisions (the last one repeats).
private final class ScriptedResolver: Sendable {
    private let state: Mutex<(conflicts: [TransferConflict], decisions: [ConflictDecision])>

    init(_ decisions: [ConflictDecision] = []) {
        state = Mutex((conflicts: [], decisions: decisions))
    }

    var conflicts: [TransferConflict] { state.withLock { $0.conflicts } }

    var resolver: ConflictResolver {
        { conflict in
            self.state.withLock { s in
                s.conflicts.append(conflict)
                return s.decisions.count > 1 ? s.decisions.removeFirst() : (s.decisions.first ?? .init(choice: .stop, applyToAll: false))
            }
        }
    }
}

private final class ProgressLog: Sendable {
    private let values = Mutex<[TransferProgress]>([])
    var all: [TransferProgress] { values.withLock { $0 } }
    func append(_ p: TransferProgress) { values.withLock { $0.append(p) } }
}

/// A fixture with `src/`, `dst/` and a fake `Trash/` that tests use instead of the real Trash.
private struct Fixture {
    let tmp: TemporaryDirectory
    let src: URL
    let dst: URL
    let trashFolder: URL

    init() throws {
        tmp = try TemporaryDirectory()
        src = try tmp.folder("src")
        dst = try tmp.folder("dst")
        trashFolder = try tmp.folder("Trash")
    }

    var trash: @Sendable (URL) throws -> URL {
        let folder = trashFolder
        return { url in
            let target = folder.appendingPathComponent(
                NameGenerator.keepBothName(for: url.lastPathComponent, isDirectory: false, in: folder))
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }

    func run(
        _ sources: [URL], into destination: URL, mode: TransferMode,
        resolver: ScriptedResolver = ScriptedResolver(),
        sameVolume: @escaping @Sendable (URL, URL) -> Bool = FileTransfer.isSameVolume,
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) async -> TransferResult {
        await FileTransfer.run(
            sources, into: destination, mode: mode, resolver: resolver.resolver, trash: trash,
            sameVolume: sameVolume, progress: progress)
    }
}

private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
private func exists(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil }

@Suite struct FileTransferTests {
    @Test func copyIntoOtherFolder() async throws {
        let f = try Fixture()
        let a = try f.tmp.file("src/a.txt", contents: "A")
        try f.tmp.file("src/dir/b.txt", contents: "B")
        let dir = f.src.appendingPathComponent("dir")

        let result = await f.run([a, dir], into: f.dst, mode: .copy)

        #expect(result.outcome == .finished)
        #expect(result.completed.count == 2)
        #expect(result.completed.map(\.destination.lastPathComponent) == ["a.txt", "dir"])
        #expect(read(f.dst.appendingPathComponent("a.txt")) == "A")
        #expect(read(f.dst.appendingPathComponent("dir/b.txt")) == "B")
        #expect(read(a) == "A")
        #expect(exists(f.src.appendingPathComponent("dir/b.txt")))
    }

    @Test func copyIntoSameFolderMakesCopyName() async throws {
        let f = try Fixture()
        let a = try f.tmp.file("src/a.txt", contents: "A")
        let resolver = ScriptedResolver()

        let result = await f.run([a], into: f.src, mode: .copy, resolver: resolver)

        #expect(result.outcome == .finished)
        #expect(read(f.src.appendingPathComponent("a copy.txt")) == "A")
        #expect(result.completed == [TransferredItem(source: a, destination: f.src.appendingPathComponent("a copy.txt"))])
        #expect(resolver.conflicts.isEmpty)
    }

    @Test func moveIntoSameFolderIsNoOp() async throws {
        let f = try Fixture()
        let a = try f.tmp.file("src/a.txt", contents: "A")

        let result = await f.run([a], into: f.src, mode: .move)

        #expect(result.outcome == .finished)
        #expect(result.completed == [TransferredItem(source: a, destination: a)])
        #expect(read(a) == "A")
    }

    @Test func moveSameVolumeRenames() async throws {
        let f = try Fixture()
        let a = try f.tmp.file("src/a.txt", contents: "A")

        let result = await f.run([a], into: f.dst, mode: .move)

        #expect(result.outcome == .finished)
        #expect(!exists(a))
        #expect(read(f.dst.appendingPathComponent("a.txt")) == "A")
    }

    @Test func moveAcrossVolumesCopiesThenDeletes() async throws {
        let f = try Fixture()
        let a = try f.tmp.file("src/a.txt", contents: "A")
        try f.tmp.file("src/dir/b.txt", contents: "B")
        let dir = f.src.appendingPathComponent("dir")

        let result = await f.run([a, dir], into: f.dst, mode: .move, sameVolume: { _, _ in false })

        #expect(result.outcome == .finished)
        #expect(!exists(a))
        #expect(!exists(dir))
        #expect(read(f.dst.appendingPathComponent("a.txt")) == "A")
        #expect(read(f.dst.appendingPathComponent("dir/b.txt")) == "B")
    }

    @Test func crossVolumeMoveFailureKeepsSource() async throws {
        let f = try Fixture()
        let ok = try f.tmp.file("src/dir/ok.txt", contents: "ok")
        let locked = try f.tmp.file("src/dir/locked.txt", contents: "locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

        let result = await f.run(
            [f.src.appendingPathComponent("dir")], into: f.dst, mode: .move, sameVolume: { _, _ in false })

        guard case .failed(.failed(let name, let message)) = result.outcome else {
            Issue.record("expected .failed, got \(result.outcome)")
            return
        }
        #expect(name == "dir")
        #expect(!message.isEmpty)
        #expect(result.completed.isEmpty)
        #expect(exists(ok))
        #expect(exists(locked))
        #expect(!exists(f.dst.appendingPathComponent("dir")))
    }

    @Test func cancelKeepsSourceAndRemovesPartial() async throws {
        let f = try Fixture()
        let big = f.src.appendingPathComponent("big.bin")
        // Real, non-zero data: copyfile may skip the holes of a sparse file.
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        let chunk = Data(repeating: 0xA5, count: 1 << 20)
        for _ in 0..<200 { try handle.write(contentsOf: chunk) }
        try handle.close()
        let size = try FileManager.default.attributesOfItem(atPath: big.path)[.size] as? Int64

        let taskBox = Mutex<Task<TransferResult, Never>?>(nil)
        let started = Mutex(false)
        let trash = f.trash
        let dst = f.dst
        let task = Task {
            await FileTransfer.run(
                [big], into: dst, mode: .copy, resolver: ScriptedResolver().resolver, trash: trash,
                allowClone: false,
                progress: { p in
                    guard p.completedBytes > 0, p.completedItems == 0 else { return }
                    started.withLock { $0 = true }
                    // Cancelling synchronously from the callback makes the next copyfile callback quit.
                    taskBox.withLock { $0?.cancel() }
                })
        }
        taskBox.withLock { $0 = task }
        let result = await task.value

        #expect(started.withLock { $0 })
        #expect(result.outcome == .cancelled)
        #expect(result.completed.isEmpty)
        #expect((try FileManager.default.attributesOfItem(atPath: big.path)[.size] as? Int64) == size)
        #expect(!exists(dst.appendingPathComponent("big.bin")))
    }

    @Test func cancelBeforeStartDoesNothing() async throws {
        let f = try Fixture()
        let a = try f.tmp.file("src/a.txt", contents: "A")
        let trash = f.trash
        let dst = f.dst
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await FileTransfer.run(
                [a], into: dst, mode: .move, resolver: ScriptedResolver().resolver, trash: trash)
        }
        let result = await task.value
        #expect(result.outcome == .cancelled)
        #expect(exists(a))
        #expect(!exists(f.dst.appendingPathComponent("a.txt")))
    }

    @Test func moveIntoItselfIsRefused() async throws {
        let f = try Fixture()
        try f.tmp.file("src/dir/sub/x.txt", contents: "x")
        let dir = f.src.appendingPathComponent("dir")
        let sub = dir.appendingPathComponent("sub")
        let a = try f.tmp.file("src/a.txt", contents: "A")

        let result = await f.run([a, dir], into: sub, mode: .move)
        #expect(result.outcome == .failed(.intoItself(name: "dir")))
        #expect(result.completed.isEmpty)
        #expect(exists(a))
        #expect(read(sub.appendingPathComponent("x.txt")) == "x")
        #expect(!exists(sub.appendingPathComponent("a.txt")))

        let same = await f.run([dir], into: dir, mode: .move)
        #expect(same.outcome == .failed(.intoItself(name: "dir")))
        let copyInto = await f.run([dir], into: sub, mode: .copy)
        #expect(copyInto.outcome == .failed(.intoItself(name: "dir")))
        #expect(!exists(sub.appendingPathComponent("dir")))
    }

    @Test func conflictReplaceTrashesExisting() async throws {
        let f = try Fixture()
        let a = try f.tmp.file("src/a.txt", contents: "new")
        try f.tmp.file("dst/a.txt", contents: "old")
        let resolver = ScriptedResolver([.init(choice: .replace, applyToAll: false)])

        let result = await f.run([a], into: f.dst, mode: .copy, resolver: resolver)

        #expect(result.outcome == .finished)
        #expect(read(f.dst.appendingPathComponent("a.txt")) == "new")
        #expect(result.replaced.count == 1)
        #expect(result.replaced.first?.original == f.dst.appendingPathComponent("a.txt"))
        #expect(result.replaced.first.flatMap { read($0.trashed) } == "old")
        #expect(resolver.conflicts.count == 1)
        #expect(resolver.conflicts.first?.moreItemsFollow == false)
        #expect(resolver.conflicts.first?.existing == f.dst.appendingPathComponent("a.txt"))
    }

    @Test func replaceRefusesToTrashAncestorOfSource() async throws {
        let f = try Fixture()
        // Moving dst/x/x up into dst: the conflicting dst/x contains the source itself.
        let inner = try f.tmp.file("dst/x/x", contents: "inner")
        let resolver = ScriptedResolver([.init(choice: .replace, applyToAll: false)])

        let result = await f.run([inner], into: f.dst, mode: .move, resolver: resolver)

        guard case .failed(.failed(name: "x", _)) = result.outcome else {
            Issue.record("expected failure, got \(result.outcome)")
            return
        }
        #expect(result.replaced.isEmpty)
        #expect(read(inner) == "inner")
    }

    @Test func conflictKeepBothSkipStopAndApplyToAll() async throws {
        let f = try Fixture()
        var sources: [URL] = []
        for name in ["a", "b", "c"] {
            sources.append(try f.tmp.file("src/\(name).txt", contents: "new \(name)"))
            try f.tmp.file("dst/\(name).txt", contents: "old \(name)")
        }

        let keepBoth = ScriptedResolver([.init(choice: .keepBoth, applyToAll: true)])
        let result = await f.run(sources, into: f.dst, mode: .copy, resolver: keepBoth)
        #expect(result.outcome == .finished)
        #expect(keepBoth.conflicts.count == 1)
        #expect(keepBoth.conflicts.first?.moreItemsFollow == true)
        for name in ["a", "b", "c"] {
            #expect(read(f.dst.appendingPathComponent("\(name) 2.txt")) == "new \(name)")
            #expect(read(f.dst.appendingPathComponent("\(name).txt")) == "old \(name)")
        }
        #expect(result.completed.map(\.destination.lastPathComponent) == ["a 2.txt", "b 2.txt", "c 2.txt"])

        let skip = ScriptedResolver([.init(choice: .skip, applyToAll: false)])
        let skipped = await f.run([sources[0]], into: f.dst, mode: .copy, resolver: skip)
        #expect(skipped.outcome == .finished)
        #expect(skipped.skipped == [sources[0]])
        #expect(skipped.completed.isEmpty)
        #expect(read(f.dst.appendingPathComponent("a.txt")) == "old a")

        let stop = ScriptedResolver([.init(choice: .stop, applyToAll: false)])
        let stopped = await f.run(sources, into: f.dst, mode: .move, resolver: stop)
        #expect(stopped.outcome == .stopped)
        #expect(stopped.completed.isEmpty)
        #expect(stop.conflicts.count == 1)
        #expect(sources.allSatisfy(exists))
    }

    @Test func symlinksAndPackagesCopiedAsIs() async throws {
        let f = try Fixture()
        let dir = try f.tmp.folder("src/dir")
        try FileManager.default.createSymbolicLink(
            atPath: dir.appendingPathComponent("link").path, withDestinationPath: "/etc")
        try f.tmp.file("src/dir/App.app/Contents/x", contents: "x")

        let topLink = f.src.appendingPathComponent("toplink")
        try FileManager.default.createSymbolicLink(atPath: topLink.path, withDestinationPath: "/etc")

        let result = await f.run([dir, topLink], into: f.dst, mode: .copy)

        #expect(result.outcome == .finished)
        let link = f.dst.appendingPathComponent("dir/link")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "/etc")
        let copiedTop = f.dst.appendingPathComponent("toplink").path
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copiedTop) == "/etc")
        #expect(read(f.dst.appendingPathComponent("dir/App.app/Contents/x")) == "x")
    }

    @Test func progressReportsTotals() async throws {
        let f = try Fixture()
        let a = try f.tmp.file("src/a.txt", contents: "AAAA")
        try f.tmp.file("src/dir/b.txt", contents: "BBBBBB")
        let log = ProgressLog()

        let result = await f.run(
            [a, f.src.appendingPathComponent("dir")], into: f.dst, mode: .copy, progress: { log.append($0) })

        #expect(result.outcome == .finished)
        let last = try #require(log.all.last)
        #expect(last.totalItems == 2)
        #expect(last.completedItems == 2)
        #expect(last.totalBytes == 10)
        #expect(last.completedBytes == last.totalBytes)
        let bytes = log.all.map(\.completedBytes)
        #expect(bytes == bytes.sorted())
    }
}
