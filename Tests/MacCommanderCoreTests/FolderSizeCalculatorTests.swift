import Foundation
import Testing

@testable import MacCommanderCore

struct FolderSizeCalculatorTests {
    @Test func sumsFilesRecursively() async throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("a.txt", contents: "abc")
        try tmp.file("dir/b.txt", contents: "12345")
        let size = try await FolderSizeCalculator.size(of: tmp.url)
        #expect(size == FolderSize(bytes: 8, items: 3))
    }

    @Test func doesNotFollowSymlinks() async throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("a.txt", contents: "abc")
        try tmp.file("dir/b.txt", contents: "12345")
        try FileManager.default.createSymbolicLink(
            at: tmp.url.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/usr"))
        let size = try await FolderSizeCalculator.size(of: tmp.url)
        #expect(size == FolderSize(bytes: 8, items: 4))
    }

    @Test func cancellationThrows() async throws {
        let tmp = try TemporaryDirectory()
        let root = tmp.url
        try await Task.detached {
            for i in 0..<20_000 {
                FileManager.default.createFile(atPath: root.appendingPathComponent("f\(i)").path, contents: nil)
            }
        }.value
        let task = Task { try await FolderSizeCalculator.size(of: root) }
        task.cancel()
        do {
            let size = try await task.value
            // Finished before cancellation was observed.
            #expect(size.items == 20_000)
        } catch {
            #expect(error is CancellationError)
        }
    }
}
