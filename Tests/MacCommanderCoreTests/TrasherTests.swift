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
}
