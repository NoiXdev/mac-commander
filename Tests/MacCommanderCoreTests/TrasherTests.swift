import Foundation
import Testing
@testable import MacCommanderCore

/// A fake Trash: moves items into `folder` (keep-both names) and returns the new URL.
func fakeTrash(into folder: URL) -> @Sendable (URL) throws -> URL {
    { url in
        let target = folder.appendingPathComponent(
            NameGenerator.keepBothName(for: url.lastPathComponent, isDirectory: false, in: folder))
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
}

struct TrasherTests {
    @Test func trashMovesItemsAndReportsFailures() async throws {
        let tmp = try TemporaryDirectory()
        let trashFolder = try tmp.folder("Trash")
        let a = try tmp.file("a.txt", contents: "A")
        let missing = tmp.url.appendingPathComponent("missing.txt")

        let result = await Trasher.trash([a, missing], using: fakeTrash(into: trashFolder))

        #expect(result.trashed.count == 1)
        #expect(result.trashed.first?.original == a)
        let trashed = try #require(result.trashed.first?.trashed)
        #expect(FileManager.default.fileExists(atPath: trashed.path))
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.url == missing)
        #expect(result.failures.first?.message.isEmpty == false)
    }

    /// Cancelling stops before the next item; items not reached yet stay where they are.
    @Test func cancellationStopsBeforeTheNextItem() async throws {
        let tmp = try TemporaryDirectory()
        let trashFolder = try tmp.folder("Trash")
        let a = try tmp.file("a.txt", contents: "A")
        let b = try tmp.file("b.txt", contents: "B")
        let c = try tmp.file("c.txt", contents: "C")
        let trash = fakeTrash(into: trashFolder)

        let result = await Trasher.trash([a, b, c]) { url in
            let trashed = try trash(url)
            // The closure runs synchronously in the trashing task.
            withUnsafeCurrentTask { $0?.cancel() }
            return trashed
        }

        #expect(result.trashed.map(\.original) == [a])
        #expect(result.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: b.path))
        #expect(FileManager.default.fileExists(atPath: c.path))
    }
}
