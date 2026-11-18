import Dispatch
import Foundation
import Synchronization
import Testing

@testable import MacCommanderCore

struct SerialQueueExecutorTests {
    @Test func runsBodyAndReturnsValue() async {
        #expect(await SerialQueueExecutor.withOwnThread(label: "t") { 7 } == 7)
    }

    @Test func rethrowsBodyError() async {
        await #expect(throws: CancellationError.self) {
            try await SerialQueueExecutor.withOwnThread(label: "t") { () async throws -> Int in
                throw CancellationError()
            }
        }
    }

    /// More bodies than cores block synchronously; the cooperative pool must still run other tasks.
    ///
    /// Everything that waits runs on GCD, never on the pool: if the pool were starved, the test task itself
    /// couldn't resume. The watchdog releases every blocked body after the probe's deadline, so a starved
    /// pool fails the test instead of hanging it.
    @Test func blockedJobsDontStarvePool() async {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let count = cores + 4
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let blocked = (0..<count).map { index in
            Task {
                await SerialQueueExecutor.withOwnThread(label: "blocked \(index)") {
                    started.signal()
                    blockSynchronously(on: gate)
                }
            }
        }
        let inTime = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                // At least a pool's worth of bodies is blocking before the probe starts.
                for _ in 0..<cores { _ = started.wait(timeout: .now() + 2) }
                let finished = DispatchSemaphore(value: 0)
                Task {
                    let value = await Task { 42 }.value
                    if value == 42 { finished.signal() }
                }
                let result = finished.wait(timeout: .now() + 2) == .success
                for _ in 0..<count { gate.signal() }
                continuation.resume(returning: result)
            }
        }
        #expect(inTime)
        for task in blocked { await task.value }
    }

    /// Each long operation's disk work runs on its own labelled queue, seen through the hooks it calls.
    @MainActor @Test func operationsRunOnTheirOwnThreads() async throws {
        let tmp = try TemporaryDirectory()
        _ = try tmp.folder("src")
        let dst = try tmp.folder("dst")
        let trashFolder = try tmp.folder("Trash")
        let labels = Mutex<[String]>([])
        let fake = fakeTrash(into: trashFolder)
        let trash: @Sendable (URL) throws -> URL = { url in
            labels.withLock { $0.append(currentQueueLabel()) }
            return try fake(url)
        }
        let sameVolume: @Sendable (URL, URL) -> Bool = { _, _ in
            labels.withLock { $0.append(currentQueueLabel()) }
            return true
        }
        let center = FileOperationCenter(
            undo: FileUndoStack(trash: trash), trash: trash, sameVolume: sameVolume, allowClone: true)
        let a = try tmp.file("src/a.txt", contents: "A")
        let b = try tmp.file("src/b.txt", contents: "B")

        _ = await center.transfer([a], into: dst, mode: .move) { _ in
            ConflictDecision(choice: .skip, applyToAll: true)
        }
        #expect(labels.withLock { $0 } == ["MacCommander op transfer"])

        labels.withLock { $0 = [] }
        _ = await center.trash([b])
        #expect(labels.withLock { $0 } == ["MacCommander op trash"])

        // A copy's undo trashes the copy.
        let c = try tmp.file("src/c.txt", contents: "C")
        labels.withLock { $0 = [] }
        _ = await center.transfer([c], into: dst, mode: .copy) { _ in
            ConflictDecision(choice: .skip, applyToAll: true)
        }
        _ = try await center.performUndo()
        #expect(labels.withLock { $0 } == ["MacCommander op undo"])

        let zip = try ArchiveFixtures.makeArchive(["x.txt": "X"], format: "zip", in: tmp, name: "x.zip")
        labels.withLock { $0 = [] }
        _ = try await center.extractAll(zip, into: dst) { _ in ConflictDecision(choice: .skip, applyToAll: true) }
        #expect(labels.withLock { $0 } == ["MacCommander op extract"])

        let sizeLabels = Mutex<Set<String>>([])
        _ = try await FolderSizeCalculator.size(of: tmp.url) { _ in
            sizeLabels.withLock { _ = $0.insert(currentQueueLabel()) }
        }
        #expect(sizeLabels.withLock { $0 } == ["MacCommander op folder size"])
    }
}

/// A synchronous wait, like a file-system call hung on a dead server (`wait` is unavailable in async code).
private func blockSynchronously(on semaphore: DispatchSemaphore) {
    semaphore.wait()
}

/// The label of the dispatch queue the caller runs on ("" if none).
private func currentQueueLabel() -> String {
    String(cString: __dispatch_queue_get_label(nil))
}
